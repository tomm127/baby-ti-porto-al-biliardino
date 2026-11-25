-- BTPB: sequential SQL integration benchmark, after migration 023.
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
    FOR v_i IN 1..6 LOOP
      INSERT INTO public.groups(tournament_id,name,sort_order)
        VALUES(v_t,'Group '||v_i,v_i) RETURNING id INTO v_g;
      FOR v_j IN 1..4 LOOP
        INSERT INTO public.teams(tournament_id,name)
          VALUES(v_t,'Team '||v_i||'-'||v_j) RETURNING id INTO v_team;
        INSERT INTO public.group_teams(tournament_id,group_id,team_id,lot_order)
          VALUES(v_t,v_g,v_team,(v_i*100+v_j)::double precision/10000);
      END LOOP;
    END LOOP;

    -- Reproduce the circle method for four teams per group, with group rotation.
    -- The first position stays fixed, the remaining three rotate clockwise.
    WITH roster AS (
      SELECT g.id AS group_id,g.sort_order,
        array_agg(gt.team_id ORDER BY gt.lot_order) AS ids
      FROM public.groups g JOIN public.group_teams gt ON gt.group_id=g.id
      WHERE g.tournament_id=v_t GROUP BY g.id,g.sort_order
    ), pairings AS (
      SELECT r.group_id,r.sort_order,rd.n AS round_no,p.n AS pair_no,
        r.ids[CASE WHEN p.n=1 THEN 1 ELSE 2+mod(p.n-2-(rd.n-1)+3,3) END] AS a,
        r.ids[2+mod((5-p.n)-2-(rd.n-1)+3,3)] AS b
      FROM roster r CROSS JOIN generate_series(1,3) AS rd(n)
      CROSS JOIN generate_series(1,2) AS p(n)
    ), schedule AS (
      SELECT group_id,
        CASE WHEN mod(round_no,2)=0 AND pair_no=1 THEN b ELSE a END AS team1_id,
        CASE WHEN mod(round_no,2)=0 AND pair_no=1 THEN a ELSE b END AS team2_id,
        row_number() OVER(ORDER BY round_no,pair_no,sort_order)::integer AS sequence_number
      FROM pairings
    )
    SELECT jsonb_agg(to_jsonb(s) ORDER BY s.sequence_number) INTO v_payload FROM schedule s;
    SELECT public.admin_install_group_schedule(v_t,v_payload) INTO v_rows;
    IF v_rows IS DISTINCT FROM 36 THEN RAISE EXCEPTION 'Expected 36 group matches, got %',v_rows; END IF;
    IF EXISTS (
      SELECT 1 FROM public.matches WHERE tournament_id=v_t AND stage='group'
      GROUP BY group_id,least(team1_id,team2_id),greatest(team1_id,team2_id) HAVING count(*)<>1
    ) THEN RAISE EXCEPTION 'Duplicate group pair'; END IF;
    IF EXISTS (
      SELECT 1 FROM public.teams t LEFT JOIN public.matches m ON m.tournament_id=v_t
        AND m.stage='group' AND t.id IN(m.team1_id,m.team2_id)
      WHERE t.tournament_id=v_t GROUP BY t.id HAVING count(m.id)<>3
    ) THEN RAISE EXCEPTION 'Every team must play three group matches'; END IF;
    v_setup_ms := extract(epoch FROM clock_timestamp()-v_started)*1000;

    v_started := clock_timestamp();
    SELECT public.admin_start_tournament(v_t) INTO v_assigned;
    v_start_ms := extract(epoch FROM clock_timestamp()-v_started)*1000;
    IF v_assigned IS DISTINCT FROM 8 OR (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND status='called')<>8 THEN
      RAISE EXCEPTION 'Expected eight called matches at start'; END IF;

    FOR v_j IN 1..2 LOOP
      v_started:=clock_timestamp();
      SELECT public.get_tournament_snapshot(v_slug) INTO v_snapshot;
      v_snap_start_ms:=array_append(v_snap_start_ms,extract(epoch FROM clock_timestamp()-v_started)*1000);
      IF jsonb_array_length(v_snapshot->'teams') IS DISTINCT FROM 24
         OR jsonb_array_length(v_snapshot->'matches') IS DISTINCT FROM 36
         OR v_snapshot->'tournament'->>'status' IS DISTINCT FROM 'active' THEN
        RAISE EXCEPTION 'Invalid initial snapshot'; END IF;
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_snapshot->'teams') AS x(team) WHERE x.team ? 'team_pin_hash') THEN
        RAISE EXCEPTION 'Snapshot includes a PIN hash field'; END IF;
    END LOOP;
    v_bytes_start:=octet_length(v_snapshot::text);

    -- The app's real admin result RPC drives assignment, qualification and progression.
    -- No sleeps or direct result writes. This is intentionally sequential.
    LOOP
      -- Verify exclusivity before each action and at the final iteration.
      IF EXISTS (
        SELECT 1 FROM public.matches a JOIN public.matches b ON a.tournament_id=b.tournament_id AND a.id<b.id
        WHERE a.tournament_id=v_t AND a.status IN('called','ready','playing','awaiting_result')
          AND b.status IN('called','ready','playing','awaiting_result')
          AND (a.field_id=b.field_id OR a.team1_id IN(b.team1_id,b.team2_id) OR a.team2_id IN(b.team1_id,b.team2_id))
      ) THEN RAISE EXCEPTION 'Live team/field overlap after % results',v_step; END IF;
      IF EXISTS (
        SELECT 1 FROM public.matches WHERE tournament_id=v_t AND status IN('called','ready','playing','awaiting_result')
          AND (field_id IS NULL OR team1_id IS NULL OR team2_id IS NULL)
      ) THEN RAISE EXCEPTION 'Incomplete live match after % results',v_step; END IF;
      IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND status IN('called','ready','playing','awaiting_result'))>8 THEN
        RAISE EXCEPTION 'Too many live matches'; END IF;
      SELECT * INTO v_m FROM public.matches WHERE tournament_id=v_t AND status='called'
        ORDER BY sequence_number,id LIMIT 1;
      IF NOT FOUND THEN EXIT; END IF;
      v_step:=v_step+1;
      IF v_step>48 THEN RAISE EXCEPTION 'Unexpected extra matches or nonterminating tournament'; END IF;
      IF v_m.stage<>'group' AND v_group_done<>36 THEN RAISE EXCEPTION 'Knockout started before all group results'; END IF;
      v_started:=clock_timestamp();
      IF v_m.stage='group' AND mod(v_m.sequence_number,7)=0 THEN
        PERFORM public.admin_set_match_result(v_m.id,5,5);
      ELSIF mod(v_m.sequence_number,3)=0 THEN
        PERFORM public.admin_set_match_result(v_m.id,4,10);
      ELSE
        PERFORM public.admin_set_match_result(v_m.id,10,3);
      END IF;
      v_elapsed:=extract(epoch FROM clock_timestamp()-v_started)*1000;
      IF v_m.stage='group' THEN
        v_group_done:=v_group_done+1;
        IF v_group_done=36 THEN
          v_transition_ms:=v_elapsed;
          IF (SELECT phase FROM public.tournaments WHERE id=v_t)<>'knockout' THEN RAISE EXCEPTION 'Missing knockout phase'; END IF;
          IF (SELECT count(*) FROM public.tournament_qualifiers WHERE tournament_id=v_t)<>12 THEN RAISE EXCEPTION 'Expected 12 qualifiers'; END IF;
          IF (SELECT count(DISTINCT global_seed) FROM public.tournament_qualifiers WHERE tournament_id=v_t)<>12 THEN RAISE EXCEPTION 'Duplicate seed'; END IF;
          IF EXISTS (SELECT 1 FROM public.tournament_qualifiers WHERE tournament_id=v_t GROUP BY group_id HAVING count(*)<>2) THEN RAISE EXCEPTION 'Incorrect number of qualifiers per group'; END IF;
          IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND stage='knockout' AND status='finished' AND winner_team_id IS NOT NULL AND (team1_id IS NULL OR team2_id IS NULL))<>4 THEN RAISE EXCEPTION 'Expected four byes'; END IF;
        ELSE
          v_group_ms:=array_append(v_group_ms,v_elapsed);
        END IF;
      ELSE
        v_ko_done:=v_ko_done+1;
        v_ko_ms:=array_append(v_ko_ms,v_elapsed);
        IF v_ko_done=12 THEN v_completion_ms:=v_elapsed; END IF;
      END IF;
      IF v_group_done=18 AND v_ko_done=0 THEN
        FOR v_j IN 1..2 LOOP
          v_started:=clock_timestamp();
          SELECT public.get_tournament_snapshot(v_slug) INTO v_snapshot;
          v_snap_mid_ms:=array_append(v_snap_mid_ms,extract(epoch FROM clock_timestamp()-v_started)*1000);
          IF jsonb_array_length(v_snapshot->'matches') IS DISTINCT FROM 36 THEN RAISE EXCEPTION 'Invalid midpoint snapshot'; END IF;
        END LOOP;
        v_bytes_mid:=octet_length(v_snapshot::text);
      END IF;
    END LOOP;

    IF v_group_done<>36 OR v_ko_done<>12 OR v_step<>48 THEN RAISE EXCEPTION 'Incomplete tournament: group %, knockout %, total %',v_group_done,v_ko_done,v_step; END IF;
    IF NOT EXISTS(SELECT 1 FROM public.tournaments WHERE id=v_t AND status='completed' AND phase='completed' AND completed_at IS NOT NULL) THEN RAISE EXCEPTION 'Tournament not completed'; END IF;
    IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND stage='final' AND status='finished' AND winner_team_id IS NOT NULL)<>1 THEN RAISE EXCEPTION 'Missing valid final'; END IF;
    IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t AND stage='third_place' AND status='finished' AND winner_team_id IS NOT NULL)<>1 THEN RAISE EXCEPTION 'Missing valid third-place match'; END IF;
    IF (SELECT count(*) FROM public.matches WHERE tournament_id=v_t)<>52 THEN RAISE EXCEPTION 'Expected 36 group + 16 bracket rows'; END IF;
    IF EXISTS (SELECT 1 FROM public.matches WHERE tournament_id=v_t AND status NOT IN('finished','forfeit')) THEN RAISE EXCEPTION 'Unresolved matches remain'; END IF;
    IF EXISTS (SELECT 1 FROM public.group_standings_base WHERE tournament_id=v_t AND played<>3) THEN RAISE EXCEPTION 'Incorrect group standings games played'; END IF;
    FOR v_j IN 1..2 LOOP
      v_started:=clock_timestamp();
      SELECT public.get_tournament_snapshot(v_slug) INTO v_snapshot;
      v_snap_end_ms:=array_append(v_snap_end_ms,extract(epoch FROM clock_timestamp()-v_started)*1000);
      IF jsonb_array_length(v_snapshot->'matches') IS DISTINCT FROM 52
         OR jsonb_array_length(v_snapshot->'qualifiers') IS DISTINCT FROM 12
         OR v_snapshot->'tournament'->>'status' IS DISTINCT FROM 'completed' THEN
        RAISE EXCEPTION 'Invalid final snapshot'; END IF;
    END LOOP;
    v_bytes_end:=octet_length(v_snapshot::text);
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
      (4,'Last group result + bracket creation',ARRAY[v_transition_ms]::numeric[],NULL::integer),
      (5,'Knockout result RPC (incl. third place)',v_ko_ms,NULL::integer),
      (6,'Last knockout result (included in row 5)',ARRAY[v_completion_ms]::numeric[],NULL::integer),
      (7,'Snapshot at start',v_snap_start_ms,v_bytes_start),
      (8,'Snapshot after 18 results',v_snap_mid_ms,v_bytes_mid),
      (9,'Snapshot at completion',v_snap_end_ms,v_bytes_end),
      (10,'Total benchmark (includes checks + snapshots)',ARRAY[v_total_ms]::numeric[],NULL::integer)
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
  RAISE NOTICE 'PASS: 24 teams, 48 played matches, 4 byes, no live overlap; fixture rolled back';
END;
$benchmark$;

SELECT 'PASS: 24 teams; 48 played matches; 4 byes; rollback confirmed' AS result,
       metric,calls,mean_ms,p95_ms,max_ms,snapshot_json_bytes
FROM jsonb_to_recordset(current_setting('btpb.stress_report')::jsonb) AS r(
  ord integer,metric text,calls integer,mean_ms numeric,p95_ms numeric,max_ms numeric,snapshot_json_bytes integer
) ORDER BY ord;
ROLLBACK;
