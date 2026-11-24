-- BTPB — reconstructed missing function changes, 2026-11-24.
-- Not the original migration 009: reconstructed from production definitions.
-- Requires migrations 001–007 and the recovered emergency-pause schema (008).
-- Later migrations 010–016 still need to run on a fresh database.
-- For version control / clean database reconstruction only. Do not run on production.
-- Function bodies restored from pg_get_functiondef; no data changes.

begin;

CREATE OR REPLACE FUNCTION public.can_control_match(p_match_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select public.is_admin()
      or exists (
        select 1
        from public.matches m
        join public.player_team_assignments a
          on a.tournament_id = m.tournament_id
         and a.user_id = auth.uid()
         and a.team_id in (m.team1_id, m.team2_id)
        join public.tournaments t on t.id = m.tournament_id
        join public.tournament_settings s on s.tournament_id = m.tournament_id
        where m.id = p_match_id
          and t.status = 'active'
          and not s.emergency_paused
      );
$function$;

CREATE OR REPLACE FUNCTION public.claim_push_jobs(p_limit integer DEFAULT 50)
 RETURNS TABLE(id bigint, tournament_id uuid, match_id uuid, user_id uuid, kind text, title text, body text, url text, payload jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'Service role required';
  end if;

  return query
  with candidates as (
    select j.id
    from public.notification_jobs j
    join public.tournament_settings s on s.tournament_id=j.tournament_id
    where not s.emergency_paused
      and (
        j.status='pending'
        or (j.status='processing' and j.processing_at < now() - interval '90 seconds')
      )
    order by j.created_at
    for update of j skip locked
    limit greatest(1, least(coalesce(p_limit,50),200))
  ), claimed as (
    update public.notification_jobs j
    set status='processing',
        processing_at=now(),
        attempt_count=j.attempt_count+1,
        last_error=null
    from candidates c
    where j.id=c.id
    returning j.*
  )
  select c.id,c.tournament_id,c.match_id,c.user_id,c.kind,
         c.title,c.body,c.url,c.payload
  from claimed c
  order by c.created_at;
end;
$function$;

CREATE OR REPLACE FUNCTION public.claim_team(p_team_id uuid, p_pin text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'auth'
AS $function$
declare
  v_user_id uuid:=auth.uid();
  v_tournament_id uuid;
  v_pin_enabled boolean;
  v_pin_hash text;
  v_assignment_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select tm.tournament_id,s.team_pin_enabled,tm.team_pin_hash
  into v_tournament_id,v_pin_enabled,v_pin_hash
  from public.teams tm
  join public.tournaments t on t.id=tm.tournament_id
  join public.tournament_settings s on s.tournament_id=tm.tournament_id
  join public.group_teams gt
    on gt.tournament_id=tm.tournament_id and gt.team_id=tm.id
  where tm.id=p_team_id
    and tm.status='active'
    and t.status='active';

  if v_tournament_id is null then
    raise exception 'Squadra non attiva o non assegnata a un girone';
  end if;

  if v_pin_enabled then
    if v_pin_hash is null then raise exception 'This team has no PIN configured'; end if;
    if p_pin is null or extensions.crypt(p_pin,v_pin_hash)<>v_pin_hash then
      raise exception 'Invalid team PIN';
    end if;
  end if;

  insert into public.player_team_assignments(tournament_id,team_id,user_id,last_seen_at)
  values(v_tournament_id,p_team_id,v_user_id,now())
  on conflict(tournament_id,user_id)
  do update set team_id=excluded.team_id,updated_at=now(),last_seen_at=now()
  returning id into v_assignment_id;

  perform public.enqueue_current_notification_for_me(v_tournament_id);
  return v_assignment_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_force_move_team_group(p_team_id uuid, p_group_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_team public.teams%rowtype;
  v_old_group uuid;
  v_status public.tournament_status;
  v_rule public.match_rule_sets%rowtype;
  v_pause boolean;
  v_seq integer;
  v_queue integer;
  v_count integer:=0;
  v_opponent record;
  v_match_id uuid;
begin
  perform public.require_admin();

  select * into v_team
  from public.teams
  where id=p_team_id
  for update;

  if not found then raise exception 'Squadra non trovata'; end if;

  perform public.lock_tournament(v_team.tournament_id);
  perform public.require_group_structure_editable(v_team.tournament_id);

  if p_group_id is not null and not exists(
    select 1 from public.groups
    where id=p_group_id and tournament_id=v_team.tournament_id
  ) then raise exception 'Girone non valido'; end if;

  select group_id into v_old_group
  from public.group_teams
  where tournament_id=v_team.tournament_id and team_id=p_team_id;

  if v_old_group is not distinct from p_group_id then return 0; end if;

  select t.status,s.pause_enabled
  into v_status,v_pause
  from public.tournaments t
  join public.tournament_settings s on s.tournament_id=t.id
  where t.id=v_team.tournament_id;

  if v_status='active' then
    delete from public.matches
    where tournament_id=v_team.tournament_id
      and stage='group'
      and p_team_id in(team1_id,team2_id);
  end if;

  delete from public.group_teams
  where tournament_id=v_team.tournament_id and team_id=p_team_id;

  if p_group_id is not null then
    insert into public.group_teams(tournament_id,group_id,team_id)
    values(v_team.tournament_id,p_group_id,p_team_id);
  else
    -- A parked team must not remain selected on player devices.
    delete from public.player_team_assignments
    where tournament_id=v_team.tournament_id and team_id=p_team_id;
  end if;

  if v_status='draft' or v_team.status='withdrawn' or p_group_id is null then
    if v_status='active' then
      perform public.engine_normalize_queue(v_team.tournament_id);
      perform public.engine_fill_free_fields(v_team.tournament_id);
      perform public.engine_maybe_advance_after_structure_edit(v_team.tournament_id);
    end if;
    return 0;
  end if;

  select * into v_rule
  from public.match_rule_sets
  where tournament_id=v_team.tournament_id and scope='group';

  select coalesce(max(sequence_number),0) into v_seq
  from public.matches where tournament_id=v_team.tournament_id;

  select coalesce(max(queue_position),0) into v_queue
  from public.matches
  where tournament_id=v_team.tournament_id and status='queued';

  for v_opponent in
    select tm.id
    from public.group_teams gt
    join public.teams tm on tm.id=gt.team_id and tm.status='active'
    where gt.tournament_id=v_team.tournament_id
      and gt.group_id=p_group_id
      and gt.team_id<>p_team_id
    order by gt.created_at,tm.name
  loop
    v_seq:=v_seq+1;
    v_queue:=v_queue+1;
    v_count:=v_count+1;

    insert into public.matches(
      tournament_id,stage,status,group_id,team1_id,team2_id,
      sequence_number,queue_position,duration_seconds,goal_target,
      pause_allowed,golden_goal_on_tie
    ) values(
      v_team.tournament_id,'group','queued',p_group_id,
      p_team_id,v_opponent.id,v_seq,v_queue,
      v_rule.duration_seconds,v_rule.goal_target,v_pause,false
    )
    returning id into v_match_id;

    insert into public.match_events(tournament_id,match_id,event_type,actor_user_id,payload)
    values(v_team.tournament_id,v_match_id,'queued',auth.uid(),jsonb_build_object('reason','team_group_changed'));
  end loop;

  perform public.engine_normalize_queue(v_team.tournament_id);
  perform public.engine_fill_free_fields(v_team.tournament_id);
  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_bulk_add_teams(p_tournament_id uuid, p_group_id uuid, p_teams jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'auth'
AS $function$
declare
  v_status public.tournament_status;
  v_pin_enabled boolean;
  v_pause boolean;
  v_rule public.match_rule_sets%rowtype;
  v_seq integer;
  v_queue integer;
  v_item record;
  v_pair record;
  v_team_id uuid;
  v_new_ids uuid[] := '{}'::uuid[];
  v_count integer := 0;
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);
  perform public.require_group_structure_editable(p_tournament_id);

  if jsonb_typeof(p_teams) <> 'array' or jsonb_array_length(p_teams)=0 then
    raise exception 'Inserisci almeno una squadra';
  end if;

  if p_group_id is not null and not exists(
    select 1 from public.groups
    where id=p_group_id and tournament_id=p_tournament_id
  ) then
    raise exception 'Girone non valido';
  end if;

  select t.status,s.team_pin_enabled,s.pause_enabled
  into v_status,v_pin_enabled,v_pause
  from public.tournaments t
  join public.tournament_settings s on s.tournament_id=t.id
  where t.id=p_tournament_id;

  if not found then raise exception 'Torneo non trovato'; end if;

  if exists(
    select 1
    from jsonb_to_recordset(p_teams) as x(name text,pin text)
    where x.name is null or length(trim(x.name))=0
  ) then raise exception 'Nome squadra obbligatorio'; end if;

  if exists(
    select lower(trim(x.name))
    from jsonb_to_recordset(p_teams) as x(name text,pin text)
    group by lower(trim(x.name))
    having count(*)>1
  ) then raise exception 'Il messaggio contiene squadre duplicate'; end if;

  if exists(
    select 1
    from jsonb_to_recordset(p_teams) as x(name text,pin text)
    join public.teams tm
      on tm.tournament_id=p_tournament_id
     and lower(tm.name)=lower(trim(x.name))
  ) then raise exception 'Una o più squadre esistono già'; end if;

  if v_pin_enabled and exists(
    select 1
    from jsonb_to_recordset(p_teams) as x(name text,pin text)
    where x.pin is null or length(trim(x.pin))=0
  ) then raise exception 'I PIN sono attivi: ogni nuova squadra deve avere un PIN'; end if;

  for v_item in
    select trim(x.name) as name, nullif(trim(x.pin),'') as pin
    from jsonb_to_recordset(p_teams) as x(name text,pin text)
  loop
    insert into public.teams(tournament_id,name,team_pin_hash)
    values(
      p_tournament_id,
      v_item.name,
      case when v_item.pin is null then null
           else extensions.crypt(v_item.pin,extensions.gen_salt('bf',10)) end
    )
    returning id into v_team_id;

    v_new_ids := array_append(v_new_ids,v_team_id);
    v_count := v_count+1;

    if p_group_id is not null then
      insert into public.group_teams(tournament_id,group_id,team_id)
      values(p_tournament_id,p_group_id,v_team_id);
    end if;
  end loop;

  -- Draft schedule is regenerated by the TypeScript application.
  if v_status='draft' or p_group_id is null then
    return v_count;
  end if;

  select * into v_rule
  from public.match_rule_sets
  where tournament_id=p_tournament_id and scope='group';

  select coalesce(max(sequence_number),0) into v_seq
  from public.matches where tournament_id=p_tournament_id;

  select coalesce(max(queue_position),0) into v_queue
  from public.matches where tournament_id=p_tournament_id and status='queued';

  -- Create each missing pairing only once, including pairings between two
  -- teams that were added in the same bulk action.
  for v_pair in
    select gt1.group_id,gt1.team_id as team1_id,gt2.team_id as team2_id
    from public.group_teams gt1
    join public.group_teams gt2
      on gt2.tournament_id=gt1.tournament_id
     and gt2.group_id=gt1.group_id
     and gt1.team_id::text < gt2.team_id::text
    join public.teams t1 on t1.id=gt1.team_id and t1.status='active'
    join public.teams t2 on t2.id=gt2.team_id and t2.status='active'
    where gt1.tournament_id=p_tournament_id
      and (gt1.team_id=any(v_new_ids) or gt2.team_id=any(v_new_ids))
      and not exists(
        select 1 from public.matches m
        where m.tournament_id=p_tournament_id
          and m.stage='group'
          and m.group_id=gt1.group_id
          and (
            (m.team1_id=gt1.team_id and m.team2_id=gt2.team_id)
            or
            (m.team1_id=gt2.team_id and m.team2_id=gt1.team_id)
          )
      )
    order by gt1.created_at,gt2.created_at
  loop
    v_seq:=v_seq+1;
    v_queue:=v_queue+1;

    insert into public.matches(
      tournament_id,stage,status,group_id,team1_id,team2_id,
      sequence_number,queue_position,duration_seconds,goal_target,
      pause_allowed,golden_goal_on_tie
    ) values(
      p_tournament_id,'group','queued',v_pair.group_id,
      v_pair.team1_id,v_pair.team2_id,
      v_seq,v_queue,v_rule.duration_seconds,v_rule.goal_target,
      v_pause,false
    );

    insert into public.match_events(tournament_id,match_id,event_type,actor_user_id,payload)
    select p_tournament_id,m.id,'queued',auth.uid(),jsonb_build_object('reason','teams_bulk_added')
    from public.matches m
    where m.tournament_id=p_tournament_id
      and m.sequence_number=v_seq
    limit 1;
  end loop;

  perform public.engine_normalize_queue(p_tournament_id);
  perform public.engine_fill_free_fields(p_tournament_id);
  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_add_team(p_tournament_id uuid, p_group_id uuid, p_name text, p_pin text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'auth'
AS $function$
declare
  v_team_id uuid;
begin
  perform public.admin_bulk_add_teams(
    p_tournament_id,
    p_group_id,
    jsonb_build_array(jsonb_build_object('name',trim(p_name),'pin',p_pin))
  );

  select id into v_team_id
  from public.teams
  where tournament_id=p_tournament_id
    and lower(name)=lower(trim(p_name))
  limit 1;

  return v_team_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_apply_group_layout(p_tournament_id uuid, p_assignments jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_expected integer;
  v_received integer;
  v_item record;
  v_current_group uuid;
  v_changed integer:=0;
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);
  perform public.require_group_structure_editable(p_tournament_id);

  if jsonb_typeof(p_assignments)<>'array' then
    raise exception 'Layout non valido';
  end if;

  select count(*) into v_expected
  from public.teams
  where tournament_id=p_tournament_id;

  v_received:=jsonb_array_length(p_assignments);

  if v_received<>v_expected then
    raise exception 'Il layout deve contenere ogni squadra esattamente una volta';
  end if;

  if exists(
    select x.team_id
    from jsonb_to_recordset(p_assignments) as x(team_id uuid,group_id uuid)
    group by x.team_id
    having count(*)<>1
  ) then raise exception 'Squadra duplicata nel layout'; end if;

  if exists(
    select 1
    from jsonb_to_recordset(p_assignments) as x(team_id uuid,group_id uuid)
    where not exists(
      select 1 from public.teams tm
      where tm.id=x.team_id and tm.tournament_id=p_tournament_id
    )
  ) then raise exception 'Il layout contiene una squadra non valida'; end if;

  if exists(
    select 1
    from jsonb_to_recordset(p_assignments) as x(team_id uuid,group_id uuid)
    where x.group_id is not null
      and not exists(
        select 1 from public.groups g
        where g.id=x.group_id and g.tournament_id=p_tournament_id
      )
  ) then raise exception 'Il layout contiene un girone non valido'; end if;

  -- Every call below is part of this same SQL transaction. If one fails,
  -- PostgreSQL rolls back the complete editor save.
  for v_item in
    select x.team_id,x.group_id
    from jsonb_to_recordset(p_assignments) as x(team_id uuid,group_id uuid)
  loop
    select gt.group_id into v_current_group
    from public.group_teams gt
    where gt.tournament_id=p_tournament_id and gt.team_id=v_item.team_id;

    if v_current_group is distinct from v_item.group_id then
      perform public.admin_force_move_team_group(v_item.team_id,v_item.group_id);
      v_changed:=v_changed+1;
    end if;
  end loop;

  return v_changed;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_emergency_pause(p_tournament_id uuid, p_paused boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_current boolean;
  v_now timestamptz := clock_timestamp();
  v_match record;
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);

  if not exists(
    select 1 from public.tournaments
    where id=p_tournament_id and status='active'
  ) then
    raise exception 'La pausa emergenza è disponibile solo durante un torneo attivo';
  end if;

  select emergency_paused into v_current
  from public.tournament_settings
  where tournament_id=p_tournament_id
  for update;

  if v_current is null then raise exception 'Impostazioni torneo non trovate'; end if;
  if v_current=p_paused then return v_current; end if;

  if p_paused then
    -- First freeze every currently playing match.
    update public.matches
    set
      emergency_pause_was_countdown = (
        started_at is not null and started_at > v_now
      ),
      emergency_pause_was_running = (
        timer_started_at is not null and timer_started_at <= v_now
      ),
      timer_remaining_seconds = case
        when timer_started_at is not null
         and timer_started_at <= v_now
         and timer_remaining_seconds is not null
        then greatest(
          0,
          timer_remaining_seconds
          - floor(extract(epoch from (v_now - timer_started_at)))::integer
        )
        else timer_remaining_seconds
      end,
      timer_started_at = null
    where tournament_id=p_tournament_id
      and status='playing';

    update public.tournament_settings
    set emergency_paused=true,
        emergency_paused_at=v_now
    where tournament_id=p_tournament_id;

    -- Jobs that have not left the database yet are discarded.
    -- When the tournament resumes, current relevant notifications are rebuilt.
    delete from public.notification_jobs
    where tournament_id=p_tournament_id
      and status='pending';

  else
    update public.tournament_settings
    set emergency_paused=false,
        emergency_paused_at=null
    where tournament_id=p_tournament_id;

    -- Resume only timers that were actually running before the emergency.
    -- If the global pause interrupted the synchronized countdown, restart 3-2-1.
    update public.matches
    set
      started_at = case
        when emergency_pause_was_countdown then v_now + interval '3 seconds'
        else started_at
      end,
      timer_started_at = case
        when emergency_pause_was_countdown and duration_seconds is not null
          then v_now + interval '3 seconds'
        when emergency_pause_was_running and duration_seconds is not null
          then v_now
        else timer_started_at
      end,
      emergency_pause_was_running=false,
      emergency_pause_was_countdown=false
    where tournament_id=p_tournament_id
      and status='playing'
      and (emergency_pause_was_running or emergency_pause_was_countdown);

    -- Fill fields that may have become free because the admin edited things
    -- during the pause. This also creates the current "called/prepare" jobs.
    perform public.engine_fill_free_fields(p_tournament_id);

    -- If a called/ready assignment already existed before the pause and its
    -- pending push was removed, recreate it (sent jobs remain protected by UNIQUE).
    for v_match in
      select id from public.matches
      where tournament_id=p_tournament_id and status in('called','ready')
    loop
      perform public.engine_enqueue_match_notification(v_match.id,'called');
    end loop;
    perform public.engine_enqueue_prepare_for_next(p_tournament_id);
  end if;

  insert into public.audit_log(
    actor_user_id,table_name,row_id,action,old_data,new_data
  ) values(
    auth.uid(),
    'tournament_settings',
    p_tournament_id::text,
    'UPDATE',
    jsonb_build_object('emergency_paused',v_current),
    jsonb_build_object('emergency_paused',p_paused)
  );

  return p_paused;
end;
$function$;

-- Restrict direct access to these RPCs. Admin functions check require_admin internally.
REVOKE EXECUTE ON FUNCTION public.can_control_match(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.can_control_match(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.claim_push_jobs(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_push_jobs(integer) TO service_role;
REVOKE EXECUTE ON FUNCTION public.claim_team(uuid, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_team(uuid, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_force_move_team_group(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_force_move_team_group(uuid, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_bulk_add_teams(uuid, uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_bulk_add_teams(uuid, uuid, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_add_team(uuid, uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_add_team(uuid, uuid, text, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_apply_group_layout(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_group_layout(uuid, jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_set_emergency_pause(uuid, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_emergency_pause(uuid, boolean) TO authenticated;

commit;
