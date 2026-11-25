-- BTPB integration smoke test, after migration 022.
-- Run the ENTIRE file in Supabase SQL Editor, preferably on a test project,
-- otherwise when no real tournament is running. No permanent fixture data.
-- All fixture writes are inside a PL/pgSQL subtransaction which is explicitly
-- rolled back on success, and automatically rolled back on any failure.
-- Sequences may advance (PostgreSQL sequences are not transactional).
-- No push delivery is invoked; no player assignments are created.
BEGIN;
SET LOCAL statement_timeout = '60s';

DO $test$
DECLARE
  v_admin uuid;
  v_t uuid;
  v_g uuid;
  v_team uuid;
  v_m uuid;
  v_final uuid;
  v_third uuid;
  v_scenario integer;
  v_groups integer;
  v_size integer;
  v_q integer;
  v_seq integer;
  v_i integer;
  v_j integer;
  v_pair record;
  v_row public.matches%rowtype;
  v_expected integer;
  v_steps integer;
BEGIN
  BEGIN
    SELECT user_id INTO v_admin FROM public.admin_users ORDER BY user_id LIMIT 1;
    IF v_admin IS NULL THEN RAISE EXCEPTION 'Test needs one existing admin user'; END IF;
    -- Transaction-local SQL-editor test identity, not a browser login.
    PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);
    PERFORM set_config('request.jwt.claims', jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
    IF NOT public.is_admin() THEN RAISE EXCEPTION 'Cannot establish test admin context'; END IF;

    FOR v_scenario IN 1..2 LOOP
      v_groups := CASE WHEN v_scenario=1 THEN 2 ELSE 3 END;
      v_size := CASE WHEN v_scenario=1 THEN 3 ELSE 2 END;
      v_q := CASE WHEN v_scenario=1 THEN 2 ELSE 1 END;
      v_expected := v_groups*v_size*(v_size-1)/2;
      v_t := gen_random_uuid();
      INSERT INTO public.tournaments(id,name,slug,created_by)
      VALUES(v_t,'BTPB rollback test '||v_scenario,'smoke-'||v_t::text,v_admin);
      UPDATE public.tournament_settings
      SET qualifiers_per_group=v_q,knockout_enabled=true,third_place_enabled=(v_scenario=1),
          team_pin_enabled=false,pause_enabled=true
      WHERE tournament_id=v_t;
      IF NOT FOUND THEN RAISE EXCEPTION 'Missing tournament settings trigger'; END IF;
      INSERT INTO public.fields(tournament_id,name,sort_order)
      VALUES(v_t,'Test field 1',1),(v_t,'Test field 2',2);
      v_seq:=0;
      FOR v_i IN 1..v_groups LOOP
        INSERT INTO public.groups(tournament_id,name,sort_order)
        VALUES(v_t,'G'||v_i,v_i) RETURNING id INTO v_g;
        FOR v_j IN 1..v_size LOOP
          INSERT INTO public.teams(tournament_id,name)
          VALUES(v_t,'G'||v_i||' Team '||v_j) RETURNING id INTO v_team;
          INSERT INTO public.group_teams(tournament_id,group_id,team_id,lot_order)
          VALUES(v_t,v_g,v_team,(v_i*100+v_j)::double precision/1000);
        END LOOP;
        FOR v_pair IN SELECT a.team_id AS a,b.team_id AS b
          FROM public.group_teams a JOIN public.group_teams b
            ON a.group_id=b.group_id AND a.lot_order<b.lot_order
          WHERE a.group_id=v_g ORDER BY a.lot_order,b.lot_order
        LOOP
          v_seq:=v_seq+1;
          INSERT INTO public.matches(tournament_id,group_id,stage,status,team1_id,team2_id,sequence_number,duration_seconds,goal_target)
          VALUES(v_t,v_g,'group','scheduled',v_pair.a,v_pair.b,v_seq,60,10);
        END LOOP;
      END LOOP;
      IF v_seq<>v_expected THEN RAISE EXCEPTION 'Fixture schedule mismatch'; END IF;
      PERFORM public.admin_start_tournament(v_t);
      IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND status='called')<>2 THEN
        RAISE EXCEPTION 'Scenario %: expected 2 called matches at start',v_scenario;
      END IF;
      SELECT id INTO v_m FROM public.matches WHERE tournament_id=v_t AND status='called' ORDER BY sequence_number LIMIT 1;
      IF v_scenario=1 THEN
        -- Real RPCs: null score rejected, cancelled match repaired by admin.
        BEGIN
          PERFORM public.admin_set_match_result(v_m,NULL::integer,NULL::integer);
          RAISE EXCEPTION 'Null scores were accepted';
        EXCEPTION WHEN raise_exception THEN
          IF SQLERRM<>'Both scores are required' THEN RAISE; END IF;
        END;
        PERFORM public.admin_cancel_match(v_m);
        IF (SELECT status FROM public.matches WHERE id=v_m)<>'cancelled' THEN RAISE EXCEPTION 'Cancel failed'; END IF;
        IF public.engine_groups_complete(v_t) THEN RAISE EXCEPTION 'Cancelled group match counted as complete'; END IF;
        PERFORM public.admin_set_match_result(v_m,10,3);
        -- Exercise start/countdown/timer-expiry/result flow on another live match.
        SELECT id INTO v_m FROM public.matches WHERE tournament_id=v_t AND status='called' ORDER BY sequence_number LIMIT 1;
        SELECT * INTO v_row FROM public.start_match(v_m);
        IF v_row.status<>'playing' OR v_row.started_at IS NULL OR v_row.started_at<=clock_timestamp() THEN
          RAISE EXCEPTION 'Countdown not established';
        END IF;
        BEGIN
          PERFORM public.submit_match_result(v_m,10,2);
          RAISE EXCEPTION 'Countdown result was accepted';
        EXCEPTION WHEN raise_exception THEN
          IF SQLERRM<>'Countdown is still running' THEN RAISE; END IF;
        END;
        -- Advance only this fixture's clock rather than waiting a full minute.
        UPDATE public.matches SET started_at=clock_timestamp()-interval '61 seconds',
          timer_started_at=clock_timestamp()-interval '61 seconds' WHERE id=v_m AND tournament_id=v_t;
        SELECT * INTO v_row FROM public.mark_timer_expired(v_m);
        IF v_row.status<>'awaiting_result' OR v_row.timer_remaining_seconds IS DISTINCT FROM 0 THEN
          RAISE EXCEPTION 'Timer expiry failed';
        END IF;
        PERFORM public.submit_match_result(v_m,5,5);
      END IF;

      -- Close each remaining group match through the actual admin RPC, checking
      -- live team and field exclusivity after each step.
      FOR v_steps IN 1..v_expected LOOP
        IF EXISTS (SELECT 1 FROM public.matches a JOIN public.matches b ON a.tournament_id=b.tournament_id AND a.id<b.id
          WHERE a.tournament_id=v_t AND a.status IN ('called','ready','playing','awaiting_result')
          AND b.status IN ('called','ready','playing','awaiting_result')
          AND (a.field_id=b.field_id OR a.team1_id IN (b.team1_id,b.team2_id) OR a.team2_id IN (b.team1_id,b.team2_id))) THEN
          RAISE EXCEPTION 'Scenario %: live team or field overlap',v_scenario;
        END IF;
        SELECT id INTO v_m FROM public.matches WHERE tournament_id=v_t AND stage='group' AND status='called' ORDER BY sequence_number LIMIT 1;
        EXIT WHEN v_m IS NULL;
        PERFORM public.admin_set_match_result(v_m,10,2);
      END LOOP;
      IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND stage='group' AND status IN ('finished','forfeit'))<>v_expected THEN
        RAISE EXCEPTION 'Scenario %: group stage failed to finish',v_scenario;
      END IF;
      IF (SELECT count(*) FROM public.tournament_qualifiers WHERE tournament_id=v_t)<>v_groups*v_q THEN
        RAISE EXCEPTION 'Scenario %: wrong qualification count',v_scenario;
      END IF;
      IF (SELECT phase FROM public.tournaments WHERE id=v_t)<>'knockout' THEN RAISE EXCEPTION 'Knockout phase not created'; END IF;
      IF v_scenario=2 AND (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND stage='knockout' AND status='finished' AND winner_team_id IS NOT NULL AND (team1_id IS NULL OR team2_id IS NULL))<>1 THEN
        RAISE EXCEPTION 'Expected exactly one first-round bye for three qualifiers';
      END IF;
      -- Finish the main bracket, not the optional third place yet.
      FOR v_steps IN 1..8 LOOP
        SELECT id INTO v_m FROM public.matches WHERE tournament_id=v_t AND stage IN ('knockout','final') AND status='called' ORDER BY sequence_number LIMIT 1;
        EXIT WHEN v_m IS NULL;
        PERFORM public.admin_set_match_result(v_m,10,4);
      END LOOP;
      SELECT id INTO v_final FROM public.matches WHERE tournament_id=v_t AND stage='final' AND status='finished' AND winner_team_id IS NOT NULL;
      IF v_final IS NULL THEN RAISE EXCEPTION 'Scenario %: final did not finish',v_scenario; END IF;
      IF v_scenario=1 THEN
        IF (SELECT status FROM public.tournaments WHERE id=v_t)<>'active' THEN RAISE EXCEPTION 'Tournament closed before third place'; END IF;
        SELECT id INTO v_third FROM public.matches WHERE tournament_id=v_t AND stage='third_place' AND status='called';
        IF v_third IS NULL THEN RAISE EXCEPTION 'Third place was not called'; END IF;
        PERFORM public.admin_cancel_match(v_third);
      END IF;
      IF NOT EXISTS (SELECT 1 FROM public.tournaments WHERE id=v_t AND status='completed' AND phase='completed' AND completed_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Scenario %: tournament did not complete',v_scenario;
      END IF;
      RAISE NOTICE 'PASS scenario %: % group matches, % qualifiers, final completed',v_scenario,v_expected,v_groups*v_q;
    END LOOP;
    -- Force rollback of all fixture writes even if outer ROLLBACK is omitted.
    RAISE EXCEPTION USING ERRCODE='ZX001', MESSAGE='BTPB_TEST_ROLLBACK_OK';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    IF SQLERRM <> 'BTPB_TEST_ROLLBACK_OK' THEN RAISE; END IF;
    RAISE NOTICE 'PASS: both scenarios completed; all fixture rows rolled back';
  END;
  -- Subtransaction rollback already restores the previous JWT settings.
END;
$test$;
SELECT 'PASS: two tournament integration scenarios; fixture rows rolled back' AS result;
ROLLBACK;
