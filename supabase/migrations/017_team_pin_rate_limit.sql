-- BTPB 017: rate-limit incorrect team PINs.
-- Deploy the matching frontend change BEFORE applying this migration.
-- Existing successful claim_team calls still return the assignment UUID.
-- Incorrect or rate-limited PINs now return NULL (not an exception), so the
-- counters commit. No PINs or hashes are stored in the rate-limit tables.
-- Fixed windows: 5 failures per Auth user, 30 per team, each over 5 minutes.

BEGIN;

CREATE TABLE public.team_pin_attempts_by_user (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  window_started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts BETWEEN 0 AND 5)
);
CREATE TABLE public.team_pin_attempts_by_team (
  team_id uuid PRIMARY KEY REFERENCES public.teams(id) ON DELETE CASCADE,
  window_started_at timestamptz NOT NULL DEFAULT clock_timestamp(),
  failed_attempts integer NOT NULL DEFAULT 0 CHECK (failed_attempts BETWEEN 0 AND 30)
);
ALTER TABLE public.team_pin_attempts_by_user ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.team_pin_attempts_by_team ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.team_pin_attempts_by_user, public.team_pin_attempts_by_team
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.claim_team(p_team_id uuid, p_pin text DEFAULT NULL::text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'auth'
AS $function$
DECLARE
  v_user_id uuid := auth.uid();
  v_tournament_id uuid;
  v_pin_enabled boolean;
  v_pin_hash text;
  v_assignment_id uuid;
  v_user_count integer;
  v_team_count integer;
  v_user_window timestamptz;
  v_team_window timestamptz;
  v_now timestamptz;
BEGIN
  IF v_user_id IS NULL THEN RAISE EXCEPTION 'Authentication required'; END IF;

  -- Preserve the production rule: only active, grouped teams in active tournaments.
  SELECT tm.tournament_id, s.team_pin_enabled, tm.team_pin_hash
    INTO v_tournament_id, v_pin_enabled, v_pin_hash
  FROM public.teams tm
  JOIN public.tournaments t ON t.id = tm.tournament_id
  JOIN public.tournament_settings s ON s.tournament_id = tm.tournament_id
  JOIN public.group_teams gt ON gt.tournament_id = tm.tournament_id AND gt.team_id = tm.id
  WHERE tm.id = p_team_id AND tm.status = 'active' AND t.status = 'active';

  IF v_tournament_id IS NULL THEN
    RAISE EXCEPTION 'Squadra non attiva o non assegnata a un girone';
  END IF;

  IF v_pin_enabled THEN
    IF v_pin_hash IS NULL THEN RAISE EXCEPTION 'This team has no PIN configured'; END IF;

    -- Always acquire locks in the same order (user, then team). Concurrent
    -- requests cannot read the same counter and bypass its limit.
    INSERT INTO public.team_pin_attempts_by_user (user_id) VALUES (v_user_id)
      ON CONFLICT (user_id) DO NOTHING;
    SELECT failed_attempts, window_started_at INTO v_user_count, v_user_window
      FROM public.team_pin_attempts_by_user WHERE user_id = v_user_id FOR UPDATE;

    -- A blocked user should not take a team lock or contribute more failures.
    v_now := clock_timestamp();
    IF v_user_window + interval '5 minutes' <= v_now THEN v_user_count := 0; END IF;
    IF v_user_count >= 5 THEN RETURN NULL; END IF;

    INSERT INTO public.team_pin_attempts_by_team (team_id) VALUES (p_team_id)
      ON CONFLICT (team_id) DO NOTHING;
    SELECT failed_attempts, window_started_at INTO v_team_count, v_team_window
      FROM public.team_pin_attempts_by_team WHERE team_id = p_team_id FOR UPDATE;

    v_now := clock_timestamp();
    IF v_user_window + interval '5 minutes' <= v_now THEN v_user_count := 0; END IF;
    IF v_team_window + interval '5 minutes' <= v_now THEN v_team_count := 0; END IF;
    IF v_team_count >= 30 THEN RETURN NULL; END IF;

    IF p_pin IS NULL OR extensions.crypt(p_pin, v_pin_hash) IS DISTINCT FROM v_pin_hash THEN
      UPDATE public.team_pin_attempts_by_user
        SET failed_attempts = v_user_count + 1,
            window_started_at = CASE WHEN v_user_count = 0 THEN v_now ELSE v_user_window END
        WHERE user_id = v_user_id;
      UPDATE public.team_pin_attempts_by_team
        SET failed_attempts = v_team_count + 1,
            window_started_at = CASE WHEN v_team_count = 0 THEN v_now ELSE v_team_window END
        WHERE team_id = p_team_id;
      -- Returning, rather than raising, commits both failed-attempt counters.
      RETURN NULL;
    END IF;
    -- A successful login neither consumes a failure nor resets the budget.
  END IF;

  INSERT INTO public.player_team_assignments(tournament_id, team_id, user_id, last_seen_at)
  VALUES (v_tournament_id, p_team_id, v_user_id, now())
  ON CONFLICT (tournament_id, user_id)
  DO UPDATE SET team_id = excluded.team_id, updated_at = now(), last_seen_at = now()
  RETURNING id INTO v_assignment_id;

  PERFORM public.enqueue_current_notification_for_me(v_tournament_id);
  RETURN v_assignment_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.claim_team(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_team(uuid, text) TO authenticated, service_role;

-- Reject inherited client privileges or unexpected absence of RLS atomically.
DO $check$
DECLARE
  role_name text;
  table_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated'] LOOP
    FOREACH table_name IN ARRAY ARRAY['public.team_pin_attempts_by_user', 'public.team_pin_attempts_by_team'] LOOP
      IF has_table_privilege(role_name, table_name, 'SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER')
         OR has_any_column_privilege(role_name, table_name, 'SELECT, INSERT, UPDATE, REFERENCES') THEN
        RAISE EXCEPTION 'Unexpected client permission on % for %', table_name, role_name;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM pg_class WHERE oid = table_name::regclass AND relrowsecurity) THEN
        RAISE EXCEPTION 'RLS not enabled on %', table_name;
      END IF;
    END LOOP;
  END LOOP;
  IF has_function_privilege('anon', 'public.claim_team(uuid,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.claim_team(uuid,text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Unexpected claim_team RPC permissions';
  END IF;
END;
$check$;

NOTIFY pgrst, 'reload schema';
COMMIT;
