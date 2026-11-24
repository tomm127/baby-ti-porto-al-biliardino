-- BTPB migration 015: restrict direct read access to team PIN hashes.
-- Based on the live column list and repository commit 2933220.
-- Existing RLS policies, write privileges, PIN hashes and RPCs are unchanged.

BEGIN;

-- A table-level SELECT grant includes every column, so revoking only the
-- sensitive column would not be sufficient.
REVOKE SELECT ON TABLE public.teams FROM PUBLIC, anon, authenticated;
REVOKE SELECT (team_pin_hash) ON TABLE public.teams
  FROM PUBLIC, anon, authenticated;

-- The authenticated role includes anonymous Supabase Auth sessions.
-- RLS continues to determine which rows each user can see.
GRANT SELECT (
  id,
  tournament_id,
  name,
  status,
  withdrawn_at,
  created_at,
  updated_at,
  avatar_url
) ON TABLE public.teams TO authenticated;

-- Fail atomically if an inherited grant still exposes the hash or a required
-- column is no longer readable. Do not retrieve any actual PIN/hash values.
DO $$
DECLARE
  col text;
BEGIN
  IF has_column_privilege('authenticated', 'public.teams', 'team_pin_hash', 'SELECT')
     OR has_column_privilege('anon', 'public.teams', 'team_pin_hash', 'SELECT') THEN
    RAISE EXCEPTION 'PIN hash is still readable; check inherited grants';
  END IF;

  FOREACH col IN ARRAY ARRAY[
    'id', 'tournament_id', 'name', 'status', 'withdrawn_at',
    'created_at', 'updated_at', 'avatar_url'
  ] LOOP
    IF NOT has_column_privilege('authenticated', 'public.teams', col, 'SELECT') THEN
      RAISE EXCEPTION 'Missing required teams SELECT privilege: %', col;
    END IF;
  END LOOP;

  IF NOT EXISTS (
    SELECT 1 FROM pg_class
    WHERE oid = 'public.teams'::regclass AND relrowsecurity
  ) THEN
    RAISE EXCEPTION 'RLS is not enabled on public.teams';
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
COMMIT;
