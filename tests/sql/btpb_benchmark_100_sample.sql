-- BTPB: 100-team sampled benchmark, after migration 023.
-- Run entire file in Supabase SQL Editor, preferably on a test database.
-- No persistent test fixtures: an inner subtransaction is rolled back even on success.
-- Outer ROLLBACK also clears transaction-local settings; sequences may advance.
-- No real player assignments, push subscriptions, or Edge Function calls.
-- Measures database-side calls only, not HTTP/network/concurrent users.
BEGIN;
SET LOCAL statement_timeout = '40s';
SET LOCAL lock_timeout = '5s';

DO $benchmark$
DECLARE
  v_admin uuid;
  v_t uuid := gen_random_uuid();
  v_slug text := 'stress-' || v_t::text;
  v_g uuid;
  v_team uuid;
  v_m public.matches%rowtype;
  v_i integer;
  v_j integer;
  v_step integer := 0;
  v_group_done integer := 0;
  v_ko_done integer := 0;
  v_assigned integer;
  v_payload jsonb;
  v_snapshot jsonb;
  v_rows integer;
  v_snapshot_stage text;
  v_started timestamptz;
  v_total_started timestamptz;
  v_total_ms numeric;
  v_setup_ms numeric;
  v_start_ms numeric;
  v_transition_ms numeric;
  v_completion_ms numeric;
  v_group_ms numeric[] := ARRAY[]::numeric[];
  v_ko_ms numeric[] := ARRAY[]::numeric[];
  v_snap_start_ms numeric[] := ARRAY[]::numeric[];
  v_snap_mid_ms numeric[] := ARRAY[]::numeric[];
  v_snap_end_ms numeric[] := ARRAY[]::numeric[];
  v_bytes_start integer;
  v_bytes_mid integer;
  v_bytes_end integer;
  v_elapsed numeric;
  v_results jsonb;
BEGIN
  BEGIN
    SELECT user_id INTO v_admin FROM public.admin_users ORDER BY user_id LIMIT 1;
    IF v_admin IS NULL THEN RAISE EXCEPTION 'Benchmark needs one existing admin user'; END IF;
    PERFORM set_config('request.jwt.claim.sub',v_admin::text,true);
    PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',v_admin,'role','authenticated')::text,true);
    IF NOT public.is_admin() THEN RAISE EXCEPTION 'Cannot establish test admin context'; END IF;

    v_total_started := clock_timestamp();
    v_started := clock_timestamp();
    INSERT INTO public.tournaments(id,name,slug,created_by)
    VALUES(v_t,'BTPB stress test (rollback)',v_slug,v_admin);
    UPDATE public.tournament_settings
      SET qualifiers_per_group=2, knockout_enabled=true, third_place_enabled=true,
          ordering_mode='group_rotation', team_pin_enabled=false, pause_enabled=true
      WHERE tournament_id=v_t;
    IF NOT FOUND THEN RAISE EXCEPTION 'Missing tournament settings trigger'; END IF;
    INSERT INTO public.fields(tournament_id,name,sort_order)
      SELECT v_t,'Test field '||i,i FROM generate_series(1,8) AS f(i);
    FOR v_i IN 1..10 LOOP
      INSERT INTO public.groups(tournament_id,name,sort_order)
        VALUES(v_t,'Group '||v_i,v_i) RETURNING id INTO v_g;
      FOR v_j IN 1..10 LOOP
        INSERT INTO public.teams(tournament_id,name)
          VALUES(v_t,'Team '||v_i||'-'||v_j) RETURNING id INTO v_team;
        INSERT INTO public.group_teams(tournament_id,group_id,team_id,lot_order)
          VALUES(v_t,v_g,v_team,(v_i*100+v_j)::double precision/10000);
      END LOOP;
    END LOOP;

    -- Reproduce the circle method for ten teams per group, with group rotation.
    -- The first position stays fixed, the remaining nine rotate clockwise.
    WITH roster AS (
      SELECT g.id AS group_id,g.sort_order,
        array_agg(gt.team_id ORDER BY gt.lot_order) AS ids
      FROM public.groups g JOIN public.group_teams gt ON gt.group_id=g.id
      WHERE g.tournament_id=v_t GROUP BY g.id,g.sort_order
    ), pairings AS (
      SELECT r.group_id,r.sort_order,rd.n AS round_no,p.n AS pair_no,
        r.ids[CASE WHEN p.n=1 THEN 1 ELSE 2+mod(p.n-2-(rd.n-1)+9,9) END] AS a,
        r.ids[2+mod((11-p.n)-2-(rd.n-1)+9,9)] AS b
      FROM roster r CROSS JOIN generate_series(1,9) AS rd(n)
      CROSS JOIN generate_series(1,5) AS p(n)
    ), schedule AS (
      SELECT group_id,
        CASE WHEN mod(round_no,2)=0 AND pair_no=1 THEN b ELSE a END AS team1_id,
        CASE WHEN mod(round_no,2)=0 AND pair_no=1 THEN a ELSE b END AS team2_id,
        row_number() OVER(ORDER BY round_no,pair_no,sort_order)::integer AS sequence_number
      FROM pairings
    )
    SELECT jsonb_agg(to_jsonb(s) ORDER BY s.sequence_number) INTO v_payload FROM schedule s;
    SELECT public.admin_install_group_schedule(v_t,v_payload) INTO v_rows;
    IF v_rows IS DISTINCT FROM 450 THEN RAISE EXCEPTION 'Expected 450 group matches, got %',v_rows; END IF;
    IF EXISTS (
      SELECT 1 FROM public.matches WHERE tournament_id=v_t AND stage='group'
      GROUP BY group_id,least(team1_id,team2_id),greatest(team1_id,team2_id) HAVING count(*)<>1
    ) THEN RAISE EXCEPTION 'Duplicate group pair'; END IF;
    IF EXISTS (
      SELECT 1 FROM public.teams t LEFT JOIN public.matches m ON m.tournament_id=v_t
        AND m.stage='group' AND t.id IN(m.team1_id,m.team2_id)
      WHERE t.tournament_id=v_t GROUP BY t.id HAVING count(m.id)<>9
    ) THEN RAISE EXCEPTION 'Every team must play nine group matches'; END IF;
    v_setup_ms := extract(epoch FROM clock_timestamp()-v_started)*1000;

    v_started := clock_timestamp();
    SELECT public.admin_start_tournament(v_t) INTO v_assigned;
    v_start_ms := extract(epoch FROM clock_timestamp()-v_started)*1000;
    IF v_assigned IS DISTINCT FROM 8 OR (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND status='called')<>8 THEN
      RAISE EXCEPTION 'Expected eight called matches at start'; END IF;

    FOR v_j IN 1..3 LOOP
      v_started:=clock_timestamp();
      SELECT public.get_tournament_snapshot(v_slug) INTO v_snapshot;
      v_snap_start_ms:=array_append(v_snap_start_ms,extract(epoch FROM clock_timestamp()-v_started)*1000);
      IF jsonb_array_length(v_snapshot->'teams') IS DISTINCT FROM 100
         OR jsonb_array_length(v_snapshot->'matches') IS DISTINCT FROM 450
         OR v_snapshot->'tournament'->>'status' IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'Invalid initial snapshot'; END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_snapshot->'teams') AS x(team) WHERE x.team ? 'team_pin_hash') THEN
        RAISE EXCEPTION 'Snapshot includes a PIN hash field'; END IF;
    END LOOP;
    v_bytes_start:=octet_length(v_snapshot::text);

    -- Sample 12 actual admin result RPCs, with the full 450-match queue.
    FOR v_i IN 1..12 LOOP
      SELECT * INTO v_m FROM public.matches WHERE tournament_id=v_t AND status='called'
        ORDER BY sequence_number,id LIMIT 1;
      IF NOT FOUND THEN RAISE EXCEPTION 'No called match at step %',v_i; END IF;
      v_started:=clock_timestamp();
      PERFORM public.admin_set_match_result(v_m.id,10,3);
      v_group_ms:=array_append(v_group_ms,extract(epoch FROM clock_timestamp()-v_started)*1000);
      IF EXISTS (
        SELECT 1 FROM public.matches a JOIN public.matches b ON a.tournament_id=b.tournament_id AND a.id<b.id
        WHERE a.tournament_id=v_t AND a.status IN('called','ready','playing','awaiting_result')
          AND b.status IN('called','ready','playing','awaiting_result')
          AND (a.field_id=b.field_id OR a.team1_id IN(b.team1_id,b.team2_id) OR a.team2_id IN(b.team1_id,b.team2_id))
      ) THEN RAISE EXCEPTION 'Live team/field overlap after % results',v_i; END IF;
      IF EXISTS (SELECT 1 FROM public.matches WHERE tournament_id=v_t AND status IN('called','ready','playing','awaiting_result') AND (field_id IS NULL OR team1_id IS NULL OR team2_id IS NULL)) THEN RAISE EXCEPTION 'Incomplete live match'; END IF;
      IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND status='called')<>8 THEN RAISE EXCEPTION 'Expected 8 called matches at step %',v_i; END IF;
    END LOOP;
    IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND status='finished')<>12 THEN RAISE EXCEPTION 'Expected 12 finished matches'; END IF;
    FOR v_j IN 1..3 LOOP
      v_started:=clock_timestamp();
      SELECT public.get_tournament_snapshot(v_slug) INTO v_snapshot;
      v_snap_mid_ms:=array_append(v_snap_mid_ms,extract(epoch FROM clock_timestamp()-v_started)*1000);
      IF jsonb_array_length(v_snapshot->'matches') IS DISTINCT FROM 450 OR jsonb_array_length(v_snapshot->'teams') IS DISTINCT FROM 100 THEN RAISE EXCEPTION 'Invalid snapshot after results'; END IF;
    END LOOP;
    v_bytes_mid:=octet_length(v_snapshot::text);
    v_total_ms:=extract(epoch FROM clock_timestamp()-v_total_started)*1000;
    -- Variables retain their values when the inner block is rolled back.
    RAISE EXCEPTION USING ERRCODE='ZX001',MESSAGE='BTPB_STRESS_ROLLBACK_OK';
  EXCEPTION WHEN SQLSTATE 'ZX001' THEN
    IF SQLERRM<>'BTPB_STRESS_ROLLBACK_OK' THEN RAISE; END IF;
  END;
  IF EXISTS(SELECT 1 FROM public.tournaments WHERE id=v_t) THEN RAISE EXCEPTION 'Fixture rollback failed'; END IF;

  -- Build a tabular report outside the rolled-back subtransaction.
  WITH samples AS (
    SELECT * FROM (VALUES
      (1,'Fixture and schedule setup',ARRAY[v_setup_ms]::numeric[],NULL::integer),
      (2,'Start tournament (8 fields)',ARRAY[v_start_ms]::numeric[],NULL::integer),
      (3,'Group result RPC (ordinary)',v_group_ms,NULL::integer),
      (4,'Snapshot at start',v_snap_start_ms,v_bytes_start),
      (5,'Snapshot after 12 results',v_snap_mid_ms,v_bytes_mid),
      (6,'Total sampled benchmark',ARRAY[v_total_ms]::numeric[],NULL::integer)
    ) AS s(ord,metric,timings,bytes)
  ), report AS (
    SELECT s.ord,s.metric,count(x.ms)::integer AS calls,
      round(avg(x.ms),3) AS mean_ms,
      round((percentile_cont(0.95) WITHIN GROUP(ORDER BY x.ms::double precision))::numeric,3) AS p95_ms,
      round(max(x.ms),3) AS max_ms,
      s.bytes AS snapshot_json_bytes
    FROM samples s CROSS JOIN LATERAL unnest(s.timings) AS x(ms)
    GROUP BY s.ord,s.metric,s.bytes
  )
  SELECT jsonb_agg(to_jsonb(r) ORDER BY r.ord) INTO v_results FROM report r;
  PERFORM set_config('btpb.stress_report',v_results::text,true);
  RAISE NOTICE 'PASS: 100 teams, 450 scheduled, 12 sampled results; fixture rolled back';
END;
$benchmark$;

SELECT 'PASS: 100 teams; 450 scheduled; 12 sampled results; rollback confirmed' AS result,
       metric,calls,mean_ms,p95_ms,max_ms,snapshot_json_bytes
FROM jsonb_to_recordset(current_setting('btpb.stress_report')::jsonb) AS r(
  ord integer,metric text,calls integer,mean_ms numeric,p95_ms numeric,max_ms numeric,snapshot_json_bytes integer
) ORDER BY ord;
ROLLBACK;
