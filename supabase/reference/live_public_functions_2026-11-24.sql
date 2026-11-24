-- BTPB: production function definitions exported 2026-11-24.
-- REFERENCE ONLY. Do not execute this file: it is not a migration.
-- Source: pg_get_functiondef output supplied by the project owner.
-- Definitions only: no ACLs, ownership, table DDL, data, policies or triggers.
-- Markdown line breaks and escaped pipes restored; statement terminators added.

CREATE OR REPLACE FUNCTION public.admin_add_field(p_tournament_id uuid, p_name text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare v_id uuid; v_sort integer;
begin
  perform public.require_admin(); perform public.lock_tournament(p_tournament_id);
  if p_name is null or length(trim(p_name))=0 then raise exception 'Nome campo obbligatorio'; end if;
  select coalesce(max(sort_order),0)+1 into v_sort from public.fields where tournament_id=p_tournament_id;
  insert into public.fields(tournament_id,name,sort_order,is_active) values(p_tournament_id,trim(p_name),v_sort,true) returning id into v_id;
  if exists(select 1 from public.tournaments where id=p_tournament_id and status='active') then perform public.engine_fill_free_fields(p_tournament_id); end if;
  return v_id;
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

CREATE OR REPLACE FUNCTION public.admin_assign_match_field(p_match_id uuid, p_field_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
begin
  perform public.require_admin();

  select *
    into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not found then
    raise exception 'Partita non trovata';
  end if;

  perform public.lock_tournament(v_match.tournament_id);

  if v_match.status not in ('queued', 'called', 'ready', 'playing', 'awaiting_result') then
    raise exception 'Questa partita non può essere assegnata a un campo';
  end if;

  if not exists (
    select 1
    from public.fields
    where id = p_field_id
      and tournament_id = v_match.tournament_id
      and is_active
  ) then
    raise exception 'Campo non valido o disattivato';
  end if;

  if exists (
    select 1
    from public.matches
    where field_id = p_field_id
      and id <> p_match_id
      and status in ('called', 'ready', 'playing', 'awaiting_result')
  ) then
    raise exception 'Il campo selezionato è occupato';
  end if;

  if exists (
    select 1
    from public.matches live
    where live.tournament_id = v_match.tournament_id
      and live.id <> p_match_id
      and live.status in ('called', 'ready', 'playing', 'awaiting_result')
      and (
        live.team1_id in (v_match.team1_id, v_match.team2_id)
        or live.team2_id in (v_match.team1_id, v_match.team2_id)
      )
  ) then
    raise exception 'Una delle due squadre è già impegnata su un altro campo';
  end if;

  update public.matches
  set
    field_id = p_field_id,
    status = case
      when status = 'queued' then 'called'::public.match_status
      else status
    end,
    queue_position = case
      when status = 'queued' then null
      else queue_position
    end,
    called_at = case
      when status = 'queued' then now()
      else called_at
    end
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (
    tournament_id,
    match_id,
    event_type,
    actor_user_id,
    payload
  )
  values (
    v_match.tournament_id,
    p_match_id,
    'field_changed',
    auth.uid(),
    jsonb_build_object('field_id', p_field_id)
  );

  perform public.engine_normalize_queue(v_match.tournament_id);
  perform public.engine_fill_free_fields(v_match.tournament_id);

  return v_match;
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

CREATE OR REPLACE FUNCTION public.admin_cancel_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
begin
  perform public.require_admin();

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status in ('finished', 'forfeit') then
    raise exception 'Finished match cannot be cancelled';
  end if;

  update public.matches
  set
    status = 'cancelled',
    queue_position = null,
    timer_started_at = null,
    paused_at = null,
    ended_at = now()
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
  values (v_match.tournament_id, p_match_id, 'cancelled', auth.uid());

  perform public.engine_fill_free_fields(v_match.tournament_id);
  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_delete_team_completely(p_team_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_team public.teams%rowtype;
begin
  perform public.require_admin();
  select * into v_team from public.teams where id=p_team_id for update;
  if not found then raise exception 'Squadra non trovata'; end if;
  perform public.lock_tournament(v_team.tournament_id);
  perform public.require_group_structure_editable(v_team.tournament_id);

  delete from public.matches
  where tournament_id=v_team.tournament_id and stage='group'
    and p_team_id in (team1_id,team2_id);
  delete from public.teams where id=p_team_id;

  perform public.engine_normalize_queue(v_team.tournament_id);
  perform public.engine_fill_free_fields(v_team.tournament_id);
  perform public.engine_maybe_advance_after_structure_edit(v_team.tournament_id);
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

CREATE OR REPLACE FUNCTION public.admin_forfeit_match(p_match_id uuid, p_loser_team_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_winner uuid;
  v_winning_score integer;
  v_s1 integer;
  v_s2 integer;
begin
  perform public.require_admin();
  select * into v_match from public.matches where id=p_match_id for update;
  if v_match.status in ('finished','cancelled','forfeit') then raise exception 'Match is already closed'; end if;
  if p_loser_team_id not in (v_match.team1_id,v_match.team2_id) then raise exception 'Loser must be one of the match teams'; end if;

  v_winner := case when p_loser_team_id=v_match.team1_id then v_match.team2_id else v_match.team1_id end;
  v_winning_score := coalesce(v_match.goal_target,1);
  if v_winner=v_match.team1_id then v_s1:=v_winning_score; v_s2:=0; else v_s1:=0; v_s2:=v_winning_score; end if;

  update public.matches
  set score_team1=v_s1, score_team2=v_s2, winner_team_id=v_winner,
      result_submitted_by=auth.uid(), result_confirmed_at=now(), status='forfeit',
      ended_at=now(), timer_started_at=null, paused_at=null, field_id=null
  where id=p_match_id returning * into v_match;

  insert into public.match_events (tournament_id,match_id,event_type,actor_user_id,payload)
  values (v_match.tournament_id,p_match_id,'forfeited',auth.uid(),
    jsonb_build_object('loser_team_id',p_loser_team_id,'score_team1',v_s1,'score_team2',v_s2));

  perform public.engine_after_match_closed(p_match_id);
  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_generate_knockout(p_tournament_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  perform public.require_admin();
  return public.engine_create_knockout(p_tournament_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_install_group_schedule(p_tournament_id uuid, p_matches jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_count integer;
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);

  if jsonb_typeof(p_matches) <> 'array' then
    raise exception 'p_matches must be a JSON array';
  end if;

  if exists (
    select 1 from public.matches
    where tournament_id = p_tournament_id
      and stage = 'group'
      and status not in ('scheduled', 'queued')
  ) then
    raise exception 'Cannot replace group schedule after matches have started';
  end if;

  delete from public.matches
  where tournament_id = p_tournament_id
    and stage = 'group';

  insert into public.matches (
    tournament_id,
    stage,
    status,
    group_id,
    team1_id,
    team2_id,
    sequence_number,
    duration_seconds,
    goal_target,
    pause_allowed,
    golden_goal_on_tie
  )
  select
    p_tournament_id,
    'group'::public.match_stage,
    'scheduled'::public.match_status,
    x.group_id,
    x.team1_id,
    x.team2_id,
    x.sequence_number,
    r.duration_seconds,
    r.goal_target,
    s.pause_enabled,
    false
  from jsonb_to_recordset(p_matches) as x(
    group_id uuid,
    team1_id uuid,
    team2_id uuid,
    sequence_number integer
  )
  join public.groups g
    on g.id = x.group_id and g.tournament_id = p_tournament_id
  join public.teams t1
    on t1.id = x.team1_id and t1.tournament_id = p_tournament_id and t1.status = 'active'
  join public.teams t2
    on t2.id = x.team2_id and t2.tournament_id = p_tournament_id and t2.status = 'active'
  join public.match_rule_sets r
    on r.tournament_id = p_tournament_id and r.scope = 'group'
  join public.tournament_settings s
    on s.tournament_id = p_tournament_id
  where x.sequence_number > 0
    and x.team1_id <> x.team2_id;

  get diagnostics v_count = row_count;

  if v_count <> jsonb_array_length(p_matches) then
    raise exception 'One or more schedule rows are invalid for this tournament';
  end if;

  if exists (
    select sequence_number
    from public.matches
    where tournament_id = p_tournament_id and stage = 'group'
    group by sequence_number
    having count(*) > 1
  ) then
    raise exception 'Duplicate sequence_number in group schedule';
  end if;

  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_postpone_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_next_position integer;
begin
  perform public.require_admin();

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status in ('finished', 'cancelled', 'forfeit') then
    raise exception 'Completed/cancelled match cannot be postponed';
  end if;

  perform public.lock_tournament(v_match.tournament_id);

  select coalesce(max(queue_position), 0) + 1 into v_next_position
  from public.matches
  where tournament_id = v_match.tournament_id
    and status = 'queued';

  update public.matches
  set
    status = 'queued',
    queue_position = v_next_position,
    field_id = null,
    called_at = null,
    ready_at = null,
    timer_started_at = null,
    paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
  values (v_match.tournament_id, p_match_id, 'postponed', auth.uid());

  perform public.engine_fill_free_fields(v_match.tournament_id);
  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_reorder_queue(p_tournament_id uuid, p_match_ids uuid[])
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_expected integer;
  v_received integer;
  v_id uuid;
  v_position integer := 1;
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);

  select count(*) into v_expected
  from public.matches
  where tournament_id = p_tournament_id and status = 'queued';

  v_received := coalesce(array_length(p_match_ids, 1), 0);
  if v_received <> v_expected then
    raise exception 'Queue list must contain every queued match exactly once';
  end if;

  if exists (
    select x
    from unnest(p_match_ids) x
    group by x
    having count(*) > 1
  ) then
    raise exception 'Queue contains duplicate match IDs';
  end if;

  if exists (
    select x
    from unnest(p_match_ids) x
    where not exists (
      select 1 from public.matches m
      where m.id = x
        and m.tournament_id = p_tournament_id
        and m.status = 'queued'
    )
  ) then
    raise exception 'Queue contains a match that is not currently queued';
  end if;

  -- Avoid transient unique-index collisions while positions are being swapped.
  update public.matches
  set queue_position = queue_position + 1000000
  where tournament_id = p_tournament_id and status = 'queued';

  foreach v_id in array p_match_ids loop
    update public.matches
    set queue_position = v_position
    where id = v_id;
    v_position := v_position + 1;
  end loop;

  return v_received;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_reset_tournament_matches(p_tournament_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);

  if not exists (
    select 1 from public.tournaments where id = p_tournament_id
  ) then
    raise exception 'Tournament not found';
  end if;

  -- Stop emergency pause state.
  update public.tournament_settings
  set emergency_paused = false,
      emergency_paused_at = null
  where tournament_id = p_tournament_id;

  -- No old notification may survive the reset.
  delete from public.notification_jobs
  where tournament_id = p_tournament_id;

  -- Remove qualification snapshot from a previous knockout phase.
  delete from public.tournament_qualifiers
  where tournament_id = p_tournament_id;

  -- Break self references first because knockout/third-place matches reference
  -- previous matches with RESTRICT foreign keys.
  update public.matches
  set team1_source_match_id = null,
      team2_source_match_id = null,
      team1_source_loser_match_id = null,
      team2_source_loser_match_id = null
  where tournament_id = p_tournament_id;

  -- match_events and notification jobs tied to matches cascade automatically.
  delete from public.matches
  where tournament_id = p_tournament_id;

  delete from public.knockout_rounds
  where tournament_id = p_tournament_id;

  -- Back to configuration mode. No field assignment can happen while draft.
  update public.tournaments
  set status = 'draft',
      phase = 'groups',
      started_at = null,
      completed_at = null
  where id = p_tournament_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_restore_team(p_team_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_team public.teams%rowtype;
  v_group_id uuid;
  v_tstatus public.tournament_status;
  v_rule public.match_rule_sets%rowtype;
  v_pause boolean;
  v_seq integer;
  v_queue integer;
  v_count integer := 0;
  v_opponent record;
  v_match_id uuid;
begin
  perform public.require_admin();
  select * into v_team from public.teams where id=p_team_id for update;
  if not found then raise exception 'Squadra non trovata'; end if;
  perform public.lock_tournament(v_team.tournament_id);
  perform public.require_group_structure_editable(v_team.tournament_id);

  select group_id into v_group_id from public.group_teams where tournament_id=v_team.tournament_id and team_id=p_team_id;
  if v_group_id is null then raise exception 'Squadra senza girone'; end if;

  update public.teams set status='active', withdrawn_at=null where id=p_team_id;
  select t.status,s.pause_enabled into v_tstatus,v_pause
  from public.tournaments t join public.tournament_settings s on s.tournament_id=t.id
  where t.id=v_team.tournament_id;

  if v_tstatus='draft' then return 0; end if;

  select * into v_rule from public.match_rule_sets where tournament_id=v_team.tournament_id and scope='group';
  select coalesce(max(sequence_number),0) into v_seq from public.matches where tournament_id=v_team.tournament_id;
  select coalesce(max(queue_position),0) into v_queue from public.matches where tournament_id=v_team.tournament_id and status='queued';

  for v_opponent in
    select tm.id
    from public.group_teams gt join public.teams tm on tm.id=gt.team_id and tm.status='active'
    where gt.tournament_id=v_team.tournament_id and gt.group_id=v_group_id and gt.team_id<>p_team_id
      and not exists (
        select 1 from public.matches m
        where m.tournament_id=v_team.tournament_id and m.stage='group' and m.group_id=v_group_id
          and ((m.team1_id=p_team_id and m.team2_id=tm.id) or (m.team1_id=tm.id and m.team2_id=p_team_id))
      )
    order by gt.created_at,tm.name
  loop
    v_seq:=v_seq+1; v_queue:=v_queue+1; v_count:=v_count+1;
    insert into public.matches(
      tournament_id,stage,status,group_id,team1_id,team2_id,sequence_number,queue_position,
      duration_seconds,goal_target,pause_allowed,golden_goal_on_tie
    ) values (
      v_team.tournament_id,'group','queued',v_group_id,p_team_id,v_opponent.id,v_seq,v_queue,
      v_rule.duration_seconds,v_rule.goal_target,v_pause,false
    ) returning id into v_match_id;
    insert into public.match_events(tournament_id,match_id,event_type,actor_user_id,payload)
    values(v_team.tournament_id,v_match_id,'queued',auth.uid(),jsonb_build_object('reason','team_restored'));
  end loop;

  perform public.engine_fill_free_fields(v_team.tournament_id);
  return v_count;
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

CREATE OR REPLACE FUNCTION public.admin_set_match_result(p_match_id uuid, p_score_team1 integer, p_score_team2 integer)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_winner uuid;
  v_phase public.tournament_phase;
begin
  perform public.require_admin();

  if p_score_team1 < 0 or p_score_team2 < 0 then
    raise exception 'Scores cannot be negative';
  end if;

  select *
    into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not found then
    raise exception 'Partita non trovata';
  end if;

  if v_match.team1_id is null or v_match.team2_id is null then
    raise exception 'Le due squadre devono essere definite prima di inserire il risultato';
  end if;

  if v_match.stage <> 'group' and p_score_team1 = p_score_team2 then
    raise exception 'Una partita a eliminazione diretta non può terminare in pareggio';
  end if;

  -- Existing closed results keep all the safety logic already implemented by
  -- admin_update_match_result (downstream bracket winner checks, bracket rebuild).
  if v_match.status in ('finished', 'forfeit') then
    select *
      into v_match
    from public.admin_update_match_result(
      p_match_id,
      p_score_team1,
      p_score_team2
    );
    return v_match;
  end if;

  select phase
    into v_phase
  from public.tournaments
  where id = v_match.tournament_id;

  -- A missing/cancelled group result after the knockout bracket has already
  -- been generated is intentionally blocked: inserting a brand-new group
  -- result at that point could change qualification. Existing completed group
  -- results are still correctable through admin_update_match_result above.
  if v_match.stage = 'group' and v_phase <> 'groups' then
    raise exception 'Non puoi inserire un nuovo risultato del girone dopo la generazione del tabellone. Correggi un risultato già concluso oppure resetta il tabellone.';
  end if;

  if p_score_team1 > p_score_team2 then
    v_winner := v_match.team1_id;
  elsif p_score_team2 > p_score_team1 then
    v_winner := v_match.team2_id;
  else
    v_winner := null;
  end if;

  -- Do not let an obsolete "called/prepare" push arrive after the admin has
  -- directly closed this match.
  delete from public.notification_jobs
  where match_id = p_match_id
    and status in ('pending', 'processing');

  update public.matches
  set
    score_team1 = p_score_team1,
    score_team2 = p_score_team2,
    winner_team_id = v_winner,
    result_submitted_by = auth.uid(),
    result_confirmed_at = now(),
    status = 'finished',
    ended_at = now(),
    timer_remaining_seconds = case
      when duration_seconds is null then timer_remaining_seconds
      else coalesce(timer_remaining_seconds, duration_seconds)
    end,
    timer_started_at = null,
    paused_at = null,
    field_id = null,
    queue_position = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (
    tournament_id,
    match_id,
    event_type,
    actor_user_id,
    payload
  )
  values (
    v_match.tournament_id,
    p_match_id,
    'admin_result_set',
    auth.uid(),
    jsonb_build_object(
      'score_team1', p_score_team1,
      'score_team2', p_score_team2,
      'direct_admin_entry', true
    )
  );

  -- If this was a future/queued/called match, compact the remaining queue,
  -- advance qualification/bracket if appropriate, and fill any newly free field.
  perform public.engine_normalize_queue(v_match.tournament_id);
  perform public.engine_after_match_closed(p_match_id);

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_team_avatar(p_team_id uuid, p_avatar_url text)
 RETURNS teams
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_team public.teams%rowtype;
begin
  perform public.require_admin();

  update public.teams
  set avatar_url = nullif(trim(coalesce(p_avatar_url, '')), '')
  where id = p_team_id
  returning * into v_team;

  if not found then
    raise exception 'Squadra non trovata';
  end if;

  return v_team;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_set_team_pin(p_team_id uuid, p_pin text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'auth'
AS $function$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  if p_pin is null or length(trim(p_pin)) = 0 then
    update public.teams
      set team_pin_hash = null
      where id = p_team_id;
  else
    update public.teams
      set team_pin_hash = extensions.crypt(p_pin, extensions.gen_salt('bf', 10))
      where id = p_team_id;
  end if;

  if not found then
    raise exception 'Team not found';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_start_tournament(p_tournament_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_status public.tournament_status;
  v_assigned integer;
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);

  select status into v_status
  from public.tournaments
  where id = p_tournament_id
  for update;

  if not found then
    raise exception 'Tournament not found';
  end if;

  if v_status <> 'draft' then
    raise exception 'Il torneo può essere iniziato solo quando è in bozza';
  end if;

  if not exists (
    select 1
    from public.fields
    where tournament_id = p_tournament_id
      and is_active
  ) then
    raise exception 'Serve almeno un campo attivo';
  end if;

  if not exists (
    select 1
    from public.matches
    where tournament_id = p_tournament_id
      and stage = 'group'
      and status = 'scheduled'
  ) then
    raise exception 'Non ci sono partite dei gironi pronte. Rigenera prima il calendario';
  end if;

  update public.tournament_settings
  set emergency_paused = false,
      emergency_paused_at = null
  where tournament_id = p_tournament_id;

  delete from public.notification_jobs
  where tournament_id = p_tournament_id
    and status in ('pending','processing');

  update public.tournaments
  set status = 'active',
      phase = 'groups',
      started_at = now(),
      completed_at = null
  where id = p_tournament_id;

  update public.matches
  set status = 'queued',
      queue_position = sequence_number,
      field_id = null,
      called_at = null,
      ready_at = null,
      started_at = null,
      ended_at = null,
      timer_remaining_seconds = duration_seconds,
      timer_started_at = null,
      paused_at = null,
      emergency_pause_was_running = false,
      emergency_pause_was_countdown = false
  where tournament_id = p_tournament_id
    and stage = 'group'
    and status = 'scheduled';

  v_assigned := public.engine_fill_free_fields(p_tournament_id);
  return v_assigned;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_field(p_field_id uuid, p_name text, p_is_active boolean)
 RETURNS fields
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare v_field public.fields%rowtype;
begin
  perform public.require_admin();
  select * into v_field from public.fields where id=p_field_id for update;
  if not found then raise exception 'Campo non trovato'; end if;
  perform public.lock_tournament(v_field.tournament_id);
  if p_name is null or length(trim(p_name))=0 then raise exception 'Nome campo obbligatorio'; end if;
  if not p_is_active and exists(
    select 1 from public.matches where field_id=p_field_id and status in('called','ready','playing','awaiting_result')
  ) then raise exception 'Prima termina o rimanda la partita attualmente assegnata a questo campo'; end if;
  update public.fields set name=trim(p_name),is_active=p_is_active where id=p_field_id returning * into v_field;
  if p_is_active then perform public.engine_fill_free_fields(v_field.tournament_id); end if;
  return v_field;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_match_result(p_match_id uuid, p_score_team1 integer, p_score_team2 integer)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_old_winner uuid;
  v_old_s1 integer;
  v_old_s2 integer;
  v_new_winner uuid;
  v_tournament_phase public.tournament_phase;
begin
  perform public.require_admin();
  if p_score_team1 < 0 or p_score_team2 < 0 then raise exception 'Scores cannot be negative'; end if;

  select * into v_match from public.matches where id=p_match_id for update;
  if v_match.status not in ('finished','forfeit') then raise exception 'Only a closed match result can be corrected'; end if;
  if v_match.stage <> 'group' and p_score_team1=p_score_team2 then raise exception 'Knockout matches cannot finish tied'; end if;

  select phase into v_tournament_phase from public.tournaments where id=v_match.tournament_id;

  if v_match.stage='group' and v_tournament_phase <> 'groups' then
    if exists (
      select 1 from public.matches
      where tournament_id=v_match.tournament_id and stage <> 'group'
        and (
          started_at is not null
          or score_team1 is not null
          or status in ('called','ready','playing','awaiting_result','forfeit')
        )
    ) then
      raise exception 'Cannot change a group result after knockout matches have started. Reset the bracket first.';
    end if;
  end if;

  v_old_winner:=v_match.winner_team_id; v_old_s1:=v_match.score_team1; v_old_s2:=v_match.score_team2;
  if p_score_team1>p_score_team2 then v_new_winner:=v_match.team1_id;
  elsif p_score_team2>p_score_team1 then v_new_winner:=v_match.team2_id;
  else v_new_winner:=null; end if;

  -- If winner changes, direct downstream match must still be unstarted.
  if v_match.stage <> 'group' and v_new_winner is distinct from v_old_winner then
    if exists (
      select 1 from public.matches d
      where d.tournament_id=v_match.tournament_id
        and p_match_id in (d.team1_source_match_id,d.team2_source_match_id,d.team1_source_loser_match_id,d.team2_source_loser_match_id)
        and d.status not in ('scheduled','queued')
    ) then
      raise exception 'Cannot change the winner because the downstream match has already started';
    end if;

    update public.matches d
    set status='scheduled', queue_position=null, field_id=null,
        team1_id=case when d.team1_source_match_id=p_match_id or d.team1_source_loser_match_id=p_match_id then null else d.team1_id end,
        team2_id=case when d.team2_source_match_id=p_match_id or d.team2_source_loser_match_id=p_match_id then null else d.team2_id end
    where d.tournament_id=v_match.tournament_id
      and p_match_id in (d.team1_source_match_id,d.team2_source_match_id,d.team1_source_loser_match_id,d.team2_source_loser_match_id);
  end if;

  update public.matches
  set score_team1=p_score_team1, score_team2=p_score_team2, winner_team_id=v_new_winner,
      result_submitted_by=auth.uid(), result_confirmed_at=now(), status='finished'
  where id=p_match_id returning * into v_match;

  insert into public.match_events (tournament_id,match_id,event_type,actor_user_id,payload)
  values (v_match.tournament_id,p_match_id,'result_changed',auth.uid(),
    jsonb_build_object('old_score_team1',v_old_s1,'old_score_team2',v_old_s2,
                       'score_team1',p_score_team1,'score_team2',p_score_team2));

  if v_match.stage='group' and v_tournament_phase <> 'groups' then
    -- Delete from the end of the bracket backwards to satisfy self-referencing FKs.
    loop
      delete from public.matches
      where id = (
        select id from public.matches
        where tournament_id=v_match.tournament_id and stage <> 'group'
        order by sequence_number desc nulls last, created_at desc
        limit 1
      );
      exit when not found;
    end loop;
    delete from public.knockout_rounds where tournament_id=v_match.tournament_id;
    delete from public.tournament_qualifiers where tournament_id=v_match.tournament_id;
    update public.tournaments set phase='groups', status='active', completed_at=null where id=v_match.tournament_id;
    perform public.engine_create_knockout(v_match.tournament_id);
    perform public.engine_fill_free_fields(v_match.tournament_id);
  elsif v_match.stage <> 'group' then
    perform public.engine_advance_knockout(v_match.tournament_id);
    perform public.engine_fill_free_fields(v_match.tournament_id);
  end if;

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_update_tournament_rules(p_tournament_id uuid, p_pause_enabled boolean, p_qualifiers_per_group integer, p_third_place_enabled boolean, p_team_pin_enabled boolean, p_group_duration integer, p_group_goal integer, p_knockout_duration integer, p_knockout_goal integer, p_final_duration integer, p_final_goal integer, p_third_duration integer, p_third_goal integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare v_phase public.tournament_phase;
begin
  perform public.require_admin(); perform public.lock_tournament(p_tournament_id);
  select phase into v_phase from public.tournaments where id=p_tournament_id;
  if not found then raise exception 'Torneo non trovato'; end if;
  if p_qualifiers_per_group < 1 then raise exception 'Le qualificate per girone devono essere almeno 1'; end if;
  if (p_group_duration is null and p_group_goal is null) or (p_knockout_duration is null and p_knockout_goal is null)
     or (p_final_duration is null and p_final_goal is null) or (p_third_duration is null and p_third_goal is null) then
    raise exception 'Ogni tipo di partita deve avere timer, target goal o entrambi';
  end if;
  if v_phase <> 'groups' and exists(select 1 from public.matches where tournament_id=p_tournament_id and stage<>'group') then
    if p_qualifiers_per_group <> (select qualifiers_per_group from public.tournament_settings where tournament_id=p_tournament_id)
       or p_third_place_enabled <> (select third_place_enabled from public.tournament_settings where tournament_id=p_tournament_id) then
      raise exception 'Qualificate e terzo posto non possono cambiare dopo la generazione del tabellone';
    end if;
  end if;
  if exists(
    select g.id
    from public.groups g
    left join public.group_teams gt on gt.group_id=g.id and gt.tournament_id=g.tournament_id
    left join public.teams tm on tm.id=gt.team_id and tm.status='active'
    where g.tournament_id=p_tournament_id
    group by g.id
    having count(tm.id) < p_qualifiers_per_group
  ) then
    raise exception 'Ogni girone deve avere almeno tante squadre attive quante sono le qualificate richieste';
  end if;
  if p_team_pin_enabled and exists(select 1 from public.teams where tournament_id=p_tournament_id and status='active' and team_pin_hash is null) then
    raise exception 'Prima di attivare i PIN assegna un PIN a tutte le squadre attive';
  end if;

  update public.tournament_settings set
    pause_enabled=p_pause_enabled,
    qualifiers_per_group=p_qualifiers_per_group,
    third_place_enabled=p_third_place_enabled,
    team_pin_enabled=p_team_pin_enabled
  where tournament_id=p_tournament_id;

  update public.match_rule_sets set duration_seconds=p_group_duration,goal_target=p_group_goal where tournament_id=p_tournament_id and scope='group';
  update public.match_rule_sets set duration_seconds=p_knockout_duration,goal_target=p_knockout_goal where tournament_id=p_tournament_id and scope='knockout';
  update public.match_rule_sets set duration_seconds=p_final_duration,goal_target=p_final_goal where tournament_id=p_tournament_id and scope='final';
  update public.match_rule_sets set duration_seconds=p_third_duration,goal_target=p_third_goal where tournament_id=p_tournament_id and scope='third_place';

  update public.matches m set
    duration_seconds=r.duration_seconds,
    goal_target=r.goal_target,
    pause_allowed=p_pause_enabled
  from public.match_rule_sets r
  where m.tournament_id=p_tournament_id
    and m.status in('scheduled','queued','called','ready')
    and r.tournament_id=p_tournament_id
    and r.scope=(case m.stage when 'group' then 'group'::public.rule_scope when 'knockout' then 'knockout'::public.rule_scope when 'final' then 'final'::public.rule_scope else 'third_place'::public.rule_scope end);
end;
$function$;

CREATE OR REPLACE FUNCTION public.admin_withdraw_team(p_team_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_team public.teams%rowtype;
  v_deleted integer;
begin
  perform public.require_admin();
  select * into v_team from public.teams where id=p_team_id for update;
  if not found then raise exception 'Squadra non trovata'; end if;
  perform public.lock_tournament(v_team.tournament_id);
  perform public.require_group_structure_editable(v_team.tournament_id);

  if v_team.status='withdrawn' then return 0; end if;

  delete from public.matches
  where tournament_id=v_team.tournament_id
    and stage='group'
    and p_team_id in (team1_id,team2_id)
    and status not in ('finished','forfeit');
  get diagnostics v_deleted = row_count;

  update public.teams set status='withdrawn', withdrawn_at=now() where id=p_team_id;
  perform public.engine_normalize_queue(v_team.tournament_id);
  perform public.engine_fill_free_fields(v_team.tournament_id);
  perform public.engine_maybe_advance_after_structure_edit(v_team.tournament_id);
  return v_deleted;
end;
$function$;

CREATE OR REPLACE FUNCTION public.audit_row_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_old jsonb;
  v_new jsonb;
  v_id text;
begin
  if tg_op = 'INSERT' then
    v_new := to_jsonb(new);
    v_id := coalesce(v_new ->> 'id', v_new ->> 'tournament_id');
  elsif tg_op = 'UPDATE' then
    v_old := to_jsonb(old);
    v_new := to_jsonb(new);
    v_id := coalesce(v_new ->> 'id', v_new ->> 'tournament_id');
  else
    v_old := to_jsonb(old);
    v_id := coalesce(v_old ->> 'id', v_old ->> 'tournament_id');
  end if;

  -- Never copy password/PIN hashes into the audit trail.
  if tg_table_name = 'teams' then
    v_old := v_old - 'team_pin_hash';
    v_new := v_new - 'team_pin_hash';
  end if;

  insert into public.audit_log
    (actor_user_id, table_name, row_id, action, old_data, new_data)
  values
    (auth.uid(), tg_table_name, v_id, tg_op, v_old, v_new);

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

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

CREATE OR REPLACE FUNCTION public.can_view_tournament(p_tournament_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select public.is_admin()
     or exists (
       select 1
       from public.tournaments t
       where t.id = p_tournament_id
         and t.status in ('active', 'completed', 'archived')
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

CREATE OR REPLACE FUNCTION public.complete_push_job(p_job_id bigint, p_success boolean, p_error text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'Service role required';
  end if;

  update public.notification_jobs
  set status = case when p_success then 'sent' else 'failed' end,
      sent_at = case when p_success then now() else sent_at end,
      processing_at = null,
      last_error = case when p_success then null else left(coalesce(p_error, 'Unknown push error'), 1000) end
  where id = p_job_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.end_match_early(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_remaining integer;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status <> 'playing' then
    raise exception 'Match is not playing';
  end if;
  if v_match.started_at is not null and now() < v_match.started_at then
    raise exception 'Countdown is still running';
  end if;

  v_remaining := v_match.timer_remaining_seconds;
  if v_match.timer_started_at is not null then
    v_remaining := greatest(
      0,
      coalesce(v_match.timer_remaining_seconds, 0)
        - floor(extract(epoch from (now() - v_match.timer_started_at)))::integer
    );
  end if;

  update public.matches
  set
    status = 'awaiting_result',
    timer_remaining_seconds = v_remaining,
    timer_started_at = null,
    paused_at = null
  where id = p_match_id
  returning * into v_match;

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_advance_knockout(p_tournament_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_changed integer;
  v_rows integer;
  v_active_round integer;
  v_final_round integer;
  v_queue_pos integer;
  v_match record;
  v_queued integer := 0;
  v_third_enabled boolean;
begin
  perform public.lock_tournament(p_tournament_id);

  -- Propagate winners and semifinal losers. Repeat because a chain may contain byes.
  loop
    v_changed := 0;

    update public.matches target
    set team1_id = source.winner_team_id
    from public.matches source
    where target.tournament_id = p_tournament_id
      and target.team1_id is null
      and target.team1_source_match_id = source.id
      and source.status in ('finished','forfeit')
      and source.winner_team_id is not null;
    get diagnostics v_rows = row_count; v_changed := v_changed + v_rows;

    update public.matches target
    set team2_id = source.winner_team_id
    from public.matches source
    where target.tournament_id = p_tournament_id
      and target.team2_id is null
      and target.team2_source_match_id = source.id
      and source.status in ('finished','forfeit')
      and source.winner_team_id is not null;
    get diagnostics v_rows = row_count; v_changed := v_changed + v_rows;

    update public.matches target
    set team1_id = case
      when source.winner_team_id = source.team1_id then source.team2_id
      else source.team1_id
    end
    from public.matches source
    where target.tournament_id = p_tournament_id
      and target.team1_id is null
      and target.team1_source_loser_match_id = source.id
      and source.status in ('finished','forfeit')
      and source.winner_team_id is not null
      and source.team1_id is not null and source.team2_id is not null;
    get diagnostics v_rows = row_count; v_changed := v_changed + v_rows;

    update public.matches target
    set team2_id = case
      when source.winner_team_id = source.team1_id then source.team2_id
      else source.team1_id
    end
    from public.matches source
    where target.tournament_id = p_tournament_id
      and target.team2_id is null
      and target.team2_source_loser_match_id = source.id
      and source.status in ('finished','forfeit')
      and source.winner_team_id is not null
      and source.team1_id is not null and source.team2_id is not null;
    get diagnostics v_rows = row_count; v_changed := v_changed + v_rows;

    exit when v_changed = 0;
  end loop;

  select max(round_number) into v_final_round
  from public.knockout_rounds
  where tournament_id = p_tournament_id;

  -- Earliest round with an unresolved main-bracket match. This prevents a
  -- semifinal from starting while another quarterfinal is still pending.
  select min(kr.round_number) into v_active_round
  from public.matches m
  join public.knockout_rounds kr on kr.id = m.knockout_round_id
  where m.tournament_id = p_tournament_id
    and m.stage in ('knockout','final')
    and m.status not in ('finished','forfeit');

  select coalesce(max(queue_position), 0) into v_queue_pos
  from public.matches
  where tournament_id = p_tournament_id and status = 'queued';

  if v_active_round is not null then
    -- With one field, play the optional 3rd/4th place before the final.
    if v_active_round = v_final_round then
      for v_match in
        select m.id
        from public.matches m
        where m.tournament_id = p_tournament_id
          and m.stage = 'third_place'
          and m.status = 'scheduled'
          and m.team1_id is not null
          and m.team2_id is not null
        order by m.sequence_number
        for update
      loop
        v_queue_pos := v_queue_pos + 1;
        update public.matches
        set status = 'queued', queue_position = v_queue_pos
        where id = v_match.id;
        insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
        values (p_tournament_id, v_match.id, 'queued', auth.uid());
        v_queued := v_queued + 1;
      end loop;
    end if;

    for v_match in
      select m.id
      from public.matches m
      join public.knockout_rounds kr on kr.id = m.knockout_round_id
      where m.tournament_id = p_tournament_id
        and kr.round_number = v_active_round
        and m.status = 'scheduled'
        and m.team1_id is not null
        and m.team2_id is not null
      order by m.sequence_number, m.bracket_slot
      for update of m
    loop
      v_queue_pos := v_queue_pos + 1;
      update public.matches
      set status = 'queued', queue_position = v_queue_pos
      where id = v_match.id;
      insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
      values (p_tournament_id, v_match.id, 'queued', auth.uid());
      v_queued := v_queued + 1;
    end loop;
  end if;

  select third_place_enabled into v_third_enabled
  from public.tournament_settings where tournament_id = p_tournament_id;

  if exists (
      select 1 from public.matches
      where tournament_id = p_tournament_id
        and stage = 'final'
        and status in ('finished','forfeit')
    )
    and (
      not coalesce(v_third_enabled, false)
      or not exists (select 1 from public.matches where tournament_id = p_tournament_id and stage = 'third_place')
      or exists (
        select 1 from public.matches
        where tournament_id = p_tournament_id
          and stage = 'third_place'
          and status in ('finished','forfeit','cancelled')
      )
    )
  then
    update public.tournaments
    set status = 'completed', phase = 'completed', completed_at = coalesce(completed_at, now())
    where id = p_tournament_id;
  end if;

  return v_queued;
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_after_match_closed(p_match_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_knockout boolean;
begin
  select * into v_match from public.matches where id=p_match_id;
  if not found then return; end if;

  if v_match.stage='group' and public.engine_groups_complete(v_match.tournament_id) then
    select knockout_enabled into v_knockout
    from public.tournament_settings where tournament_id=v_match.tournament_id;
    if coalesce(v_knockout,false) then
      perform public.engine_create_knockout(v_match.tournament_id);
    else
      update public.tournaments
      set status='completed', phase='completed', completed_at=coalesce(completed_at,now())
      where id=v_match.tournament_id;
    end if;
  elsif v_match.stage <> 'group' then
    perform public.engine_advance_knockout(v_match.tournament_id);
  end if;

  perform public.engine_fill_free_fields(v_match.tournament_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_create_knockout(p_tournament_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_settings public.tournament_settings%rowtype;
  v_n integer;
  v_bracket_size integer := 1;
  v_round_count integer := 0;
  v_tmp integer;
  v_round integer;
  v_match_count integer;
  v_round_id uuid;
  v_prev_round_id uuid;
  v_seed_order integer[];
  v_slot integer;
  v_seed1 integer;
  v_seed2 integer;
  v_team1 uuid;
  v_team2 uuid;
  v_source1 uuid;
  v_source2 uuid;
  v_sequence integer;
  v_stage public.match_stage;
  v_scope public.rule_scope;
  v_rule public.match_rule_sets%rowtype;
  v_match_id uuid;
  v_final_sequence integer;
  v_semifinal_round_id uuid;
  v_semifinal1 uuid;
  v_semifinal2 uuid;
begin
  perform public.lock_tournament(p_tournament_id);

  select * into v_settings from public.tournament_settings where tournament_id = p_tournament_id;
  if not found then raise exception 'Tournament settings not found'; end if;
  if not public.engine_groups_complete(p_tournament_id) then return 0; end if;

  if not v_settings.knockout_enabled then
    update public.tournaments
    set status='completed', phase='completed', completed_at=coalesce(completed_at,now())
    where id=p_tournament_id;
    return 0;
  end if;

  -- Idempotent: never duplicate an already generated bracket.
  if exists (select 1 from public.matches where tournament_id=p_tournament_id and stage <> 'group') then
    perform public.engine_advance_knockout(p_tournament_id);
    return 0;
  end if;

  delete from public.tournament_qualifiers where tournament_id = p_tournament_id;
  delete from public.knockout_rounds where tournament_id = p_tournament_id;

  with qualified as (
    select
      g.id as group_id,
      r.team_id,
      r.played,
      r.points,
      r.goal_difference,
      r.goals_for,
      r.lot_order,
      r.group_rank
    from public.groups g
    cross join lateral public.engine_group_ranking(p_tournament_id, g.id) r
    where g.tournament_id = p_tournament_id
      and r.group_rank <= v_settings.qualifiers_per_group
  ), seeded as (
    select
      q.*,
      row_number() over (
        order by
          (q.points::numeric / nullif(q.played,0)) desc nulls last,
          (q.goal_difference::numeric / nullif(q.played,0)) desc nulls last,
          (q.goals_for::numeric / nullif(q.played,0)) desc nulls last,
          q.lot_order asc
      )::integer as global_seed
    from qualified q
  )
  insert into public.tournament_qualifiers (
    tournament_id, team_id, group_id, group_rank, global_seed,
    played, points, goal_difference, goals_for,
    points_per_game, goal_difference_per_game, goals_for_per_game, lot_order
  )
  select
    p_tournament_id, s.team_id, s.group_id, s.group_rank, s.global_seed,
    s.played, s.points, s.goal_difference, s.goals_for,
    coalesce(s.points::numeric / nullif(s.played,0),0),
    coalesce(s.goal_difference::numeric / nullif(s.played,0),0),
    coalesce(s.goals_for::numeric / nullif(s.played,0),0),
    s.lot_order
  from seeded s;

  select count(*) into v_n from public.tournament_qualifiers where tournament_id=p_tournament_id;
  if v_n < 2 then
    raise exception 'At least two qualified teams are required for knockout';
  end if;

  while v_bracket_size < v_n loop v_bracket_size := v_bracket_size * 2; end loop;
  v_tmp := v_bracket_size;
  while v_tmp > 1 loop v_round_count := v_round_count + 1; v_tmp := v_tmp / 2; end loop;

  for v_round in 1..v_round_count loop
    v_match_count := v_bracket_size / power(2, v_round)::integer;
    insert into public.knockout_rounds (tournament_id, round_number, name, sort_order)
    values (p_tournament_id, v_round, public.engine_round_name(v_match_count), v_round)
    returning id into v_round_id;
  end loop;

  select coalesce(max(sequence_number),0) into v_sequence
  from public.matches where tournament_id=p_tournament_id and stage='group';

  -- First round: seeded teams or byes.
  select id into v_round_id from public.knockout_rounds
  where tournament_id=p_tournament_id and round_number=1;
  v_seed_order := public.engine_seed_order(v_bracket_size);

  for v_slot in 1..(v_bracket_size/2) loop
    v_seed1 := v_seed_order[(v_slot*2)-1];
    v_seed2 := v_seed_order[v_slot*2];
    select team_id into v_team1 from public.tournament_qualifiers
      where tournament_id=p_tournament_id and global_seed=v_seed1;
    select team_id into v_team2 from public.tournament_qualifiers
      where tournament_id=p_tournament_id and global_seed=v_seed2;

    v_stage := case when v_round_count=1 then 'final'::public.match_stage else 'knockout'::public.match_stage end;
    v_scope := case when v_stage='final' then 'final'::public.rule_scope else 'knockout'::public.rule_scope end;
    select * into v_rule from public.match_rule_sets where tournament_id=p_tournament_id and scope=v_scope;
    v_sequence := v_sequence + 1;

    insert into public.matches (
      tournament_id, stage, status, knockout_round_id, bracket_slot, sequence_number,
      team1_id, team2_id, winner_team_id,
      duration_seconds, goal_target, pause_allowed, golden_goal_on_tie,
      ended_at, result_confirmed_at
    ) values (
      p_tournament_id,
      v_stage,
      case when (v_team1 is null) <> (v_team2 is null) then 'finished'::public.match_status else 'scheduled'::public.match_status end,
      v_round_id,
      v_slot,
      v_sequence,
      v_team1,
      v_team2,
      case when v_team1 is null then v_team2 when v_team2 is null then v_team1 else null end,
      v_rule.duration_seconds,
      v_rule.goal_target,
      v_settings.pause_enabled,
      true,
      case when (v_team1 is null) <> (v_team2 is null) then now() else null end,
      case when (v_team1 is null) <> (v_team2 is null) then now() else null end
    );
  end loop;

  -- Later rounds source the winners of adjacent matches in the previous round.
  if v_round_count > 1 then
    for v_round in 2..v_round_count loop
      select id into v_round_id from public.knockout_rounds
      where tournament_id=p_tournament_id and round_number=v_round;
      select id into v_prev_round_id from public.knockout_rounds
      where tournament_id=p_tournament_id and round_number=v_round-1;
      v_match_count := v_bracket_size / power(2, v_round)::integer;

      for v_slot in 1..v_match_count loop
        select id into v_source1 from public.matches
        where tournament_id=p_tournament_id and knockout_round_id=v_prev_round_id and bracket_slot=(v_slot*2)-1;
        select id into v_source2 from public.matches
        where tournament_id=p_tournament_id and knockout_round_id=v_prev_round_id and bracket_slot=v_slot*2;

        v_stage := case when v_round=v_round_count then 'final'::public.match_stage else 'knockout'::public.match_stage end;
        v_scope := case when v_stage='final' then 'final'::public.rule_scope else 'knockout'::public.rule_scope end;
        select * into v_rule from public.match_rule_sets where tournament_id=p_tournament_id and scope=v_scope;
        v_sequence := v_sequence + 1;

        insert into public.matches (
          tournament_id, stage, status, knockout_round_id, bracket_slot, sequence_number,
          team1_source_match_id, team2_source_match_id,
          duration_seconds, goal_target, pause_allowed, golden_goal_on_tie
        ) values (
          p_tournament_id, v_stage, 'scheduled', v_round_id, v_slot, v_sequence,
          v_source1, v_source2,
          v_rule.duration_seconds, v_rule.goal_target, v_settings.pause_enabled, true
        ) returning id into v_match_id;

        if v_stage='final' then v_final_sequence := v_sequence; end if;
      end loop;
    end loop;
  else
    select sequence_number into v_final_sequence from public.matches
    where tournament_id=p_tournament_id and stage='final' limit 1;
  end if;

  -- Optional 3rd/4th place: losers of the two semifinals. It is ordered just
  -- before the final when only one field is available.
  if v_settings.third_place_enabled and v_round_count >= 2 then
    select id into v_semifinal_round_id from public.knockout_rounds
    where tournament_id=p_tournament_id and round_number=v_round_count-1;
    select id into v_semifinal1 from public.matches
    where tournament_id=p_tournament_id and knockout_round_id=v_semifinal_round_id and bracket_slot=1;
    select id into v_semifinal2 from public.matches
    where tournament_id=p_tournament_id and knockout_round_id=v_semifinal_round_id and bracket_slot=2;
    select * into v_rule from public.match_rule_sets where tournament_id=p_tournament_id and scope='third_place';

    update public.matches
    set sequence_number = sequence_number + 1
    where tournament_id=p_tournament_id and stage='final';

    insert into public.matches (
      tournament_id, stage, status, bracket_slot, sequence_number,
      team1_source_loser_match_id, team2_source_loser_match_id,
      duration_seconds, goal_target, pause_allowed, golden_goal_on_tie
    ) values (
      p_tournament_id, 'third_place', 'scheduled', 1, v_final_sequence,
      v_semifinal1, v_semifinal2,
      v_rule.duration_seconds, v_rule.goal_target, v_settings.pause_enabled, true
    );
  end if;

  update public.tournaments set phase='knockout' where id=p_tournament_id;
  perform public.engine_advance_knockout(p_tournament_id);
  return v_n;
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_enqueue_match_notification(p_match_id uuid, p_kind text)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_tournament public.tournaments%rowtype;
  v_team1_name text;
  v_team2_name text;
  v_field_name text;
  v_title text;
  v_body text;
  v_url text;
  v_count integer := 0;
begin
  if p_kind not in ('prepare', 'called') then
    raise exception 'Unsupported notification kind: %', p_kind;
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id;

  if not found or v_match.team1_id is null or v_match.team2_id is null then
    return 0;
  end if;

  select * into v_tournament
  from public.tournaments
  where id = v_match.tournament_id;

  select name into v_team1_name from public.teams where id = v_match.team1_id;
  select name into v_team2_name from public.teams where id = v_match.team2_id;
  select name into v_field_name from public.fields where id = v_match.field_id;

  if p_kind = 'called' then
    v_title := 'È IL VOSTRO TURNO!';
    v_body := format('%s vs %s · %s',
      coalesce(v_team1_name, 'Squadra 1'),
      coalesce(v_team2_name, 'Squadra 2'),
      coalesce(v_field_name, 'Campo assegnato'));
    v_url := format('/tournament/%s/match/%s', v_tournament.slug, v_match.id);
  else
    v_title := 'Preparatevi';
    v_body := format('Siete i prossimi: %s vs %s',
      coalesce(v_team1_name, 'Squadra 1'),
      coalesce(v_team2_name, 'Squadra 2'));
    v_url := format('/tournament/%s', v_tournament.slug);
  end if;

  insert into public.notification_jobs (
    tournament_id, match_id, user_id, kind, title, body, url, payload
  )
  select
    v_match.tournament_id,
    v_match.id,
    a.user_id,
    p_kind,
    v_title,
    v_body,
    v_url,
    jsonb_build_object(
      'kind', p_kind,
      'match_id', v_match.id,
      'tournament_id', v_match.tournament_id,
      'field_id', v_match.field_id,
      'team1_id', v_match.team1_id,
      'team2_id', v_match.team2_id
    )
  from public.player_team_assignments a
  where a.tournament_id = v_match.tournament_id
    and a.team_id in (v_match.team1_id, v_match.team2_id)
    and exists (
      select 1 from public.push_subscriptions ps
      where ps.user_id = a.user_id and ps.enabled
    )
  on conflict (user_id, match_id, kind) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_enqueue_prepare_for_next(p_tournament_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_match_id uuid;
begin
  if exists (
    select 1
    from public.tournament_settings
    where tournament_id = p_tournament_id
      and emergency_paused
  ) then
    return 0;
  end if;

  select m.id
    into v_match_id
  from public.matches m
  where m.tournament_id = p_tournament_id
    and m.status = 'queued'
    and m.queue_position is not null
    and m.team1_id is not null
    and m.team2_id is not null
    and not exists (
      select 1
      from public.matches live
      where live.tournament_id = p_tournament_id
        and live.id <> m.id
        and live.status in ('called', 'ready', 'playing', 'awaiting_result')
        and (
          live.team1_id in (m.team1_id, m.team2_id)
          or live.team2_id in (m.team1_id, m.team2_id)
        )
    )
  order by m.queue_position, m.sequence_number nulls last, m.created_at, m.id
  limit 1;

  if v_match_id is null then
    return 0;
  end if;

  return public.engine_enqueue_match_notification(v_match_id, 'prepare');
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_fill_free_fields(p_tournament_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_field record;
  v_match_id uuid;
  v_assigned integer := 0;
begin
  perform public.lock_tournament(p_tournament_id);

  if exists (
    select 1
    from public.tournament_settings
    where tournament_id = p_tournament_id
      and emergency_paused
  ) then
    return 0;
  end if;

  for v_field in
    select f.id
    from public.fields f
    where f.tournament_id = p_tournament_id
      and f.is_active
      and not exists (
        select 1
        from public.matches live
        where live.field_id = f.id
          and live.status in ('called', 'ready', 'playing', 'awaiting_result')
      )
    order by f.sort_order, f.created_at, f.id
  loop
    v_match_id := null;

    select m.id
      into v_match_id
    from public.matches m
    where m.tournament_id = p_tournament_id
      and m.status = 'queued'
      and m.queue_position is not null
      and m.team1_id is not null
      and m.team2_id is not null
      and not exists (
        select 1
        from public.matches live
        where live.tournament_id = p_tournament_id
          and live.id <> m.id
          and live.status in ('called', 'ready', 'playing', 'awaiting_result')
          and (
            live.team1_id in (m.team1_id, m.team2_id)
            or live.team2_id in (m.team1_id, m.team2_id)
          )
      )
    order by m.queue_position, m.sequence_number nulls last, m.created_at, m.id
    for update skip locked
    limit 1;

    -- No compatible queued match exists right now.
    -- Leave this field (and therefore the remaining free fields) empty.
    exit when v_match_id is null;

    update public.matches
    set
      status = 'called',
      field_id = v_field.id,
      queue_position = null,
      called_at = now(),
      ready_at = null
    where id = v_match_id;

    insert into public.match_events (
      tournament_id,
      match_id,
      event_type,
      actor_user_id,
      payload
    )
    values (
      p_tournament_id,
      v_match_id,
      'called',
      auth.uid(),
      jsonb_build_object(
        'field_id', v_field.id,
        'assignment_rule', 'first_eligible_no_team_overlap'
      )
    );

    perform public.engine_enqueue_match_notification(v_match_id, 'called');
    v_assigned := v_assigned + 1;
  end loop;

  perform public.engine_enqueue_prepare_for_next(p_tournament_id);
  return v_assigned;
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_group_ranking(p_tournament_id uuid, p_group_id uuid)
 RETURNS TABLE(team_id uuid, team_name text, played integer, points integer, goal_difference integer, goals_for integer, lot_order double precision, group_rank integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  with base as (
    select
      s.team_id,
      s.team_name,
      s.played,
      s.points,
      s.goal_difference,
      s.goals_for,
      s.lot_order
    from public.group_standings_base s
    join public.teams active_team on active_team.id=s.team_id and active_team.tournament_id=s.tournament_id and active_team.status='active'
    where s.tournament_id = p_tournament_id
      and s.group_id = p_group_id
  ),
  h2h as (
    select
      b.team_id,
      coalesce(sum(
        case
          when m.team1_id = b.team_id and m.score_team1 > m.score_team2 then 3
          when m.team2_id = b.team_id and m.score_team2 > m.score_team1 then 3
          when m.score_team1 = m.score_team2 then 1
          else 0
        end
      ), 0)::integer as h2h_points,
      coalesce(sum(
        case
          when m.team1_id = b.team_id then m.score_team1 - m.score_team2
          else m.score_team2 - m.score_team1
        end
      ), 0)::integer as h2h_gd,
      coalesce(sum(
        case
          when m.team1_id = b.team_id then m.score_team1
          else m.score_team2
        end
      ), 0)::integer as h2h_gf
    from base b
    join public.matches m
      on m.tournament_id = p_tournament_id
     and m.group_id = p_group_id
     and m.stage = 'group'
     and m.status in ('finished', 'forfeit')
     and b.team_id in (m.team1_id, m.team2_id)
    join base opponent
      on opponent.team_id = case when m.team1_id = b.team_id then m.team2_id else m.team1_id end
     and opponent.points = b.points
     and opponent.goal_difference = b.goal_difference
     and opponent.goals_for = b.goals_for
    group by b.team_id
  ), ranked as (
    select
      b.*,
      row_number() over (
        order by
          b.points desc,
          b.goal_difference desc,
          b.goals_for desc,
          coalesce(h.h2h_points, 0) desc,
          coalesce(h.h2h_gd, 0) desc,
          coalesce(h.h2h_gf, 0) desc,
          b.lot_order asc
      )::integer as group_rank
    from base b
    left join h2h h on h.team_id = b.team_id
  )
  select
    r.team_id,
    r.team_name,
    r.played,
    r.points,
    r.goal_difference,
    r.goals_for,
    r.lot_order,
    r.group_rank
  from ranked r
  order by r.group_rank;
$function$;

CREATE OR REPLACE FUNCTION public.engine_groups_complete(p_tournament_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select
    exists (
      select 1 from public.matches
      where tournament_id = p_tournament_id and stage = 'group'
    )
    and not exists (
      select 1 from public.matches
      where tournament_id = p_tournament_id
        and stage = 'group'
        and status not in ('finished', 'forfeit')
    );
$function$;

CREATE OR REPLACE FUNCTION public.engine_maybe_advance_after_structure_edit(p_tournament_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status public.tournament_status;
  v_knockout boolean;
begin
  select status into v_status from public.tournaments where id=p_tournament_id;
  if v_status <> 'active' then return; end if;
  if not public.engine_groups_complete(p_tournament_id) then return; end if;
  select knockout_enabled into v_knockout from public.tournament_settings where tournament_id=p_tournament_id;
  if coalesce(v_knockout,false) then
    perform public.engine_create_knockout(p_tournament_id);
  else
    update public.tournaments set status='completed',phase='completed',completed_at=coalesce(completed_at,now()) where id=p_tournament_id;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_normalize_queue(p_tournament_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_match record;
  v_pos integer := 0;
begin
  perform public.lock_tournament(p_tournament_id);

  update public.matches
  set queue_position = queue_position + 1000000
  where tournament_id = p_tournament_id
    and status = 'queued'
    and queue_position is not null;

  for v_match in
    select id
    from public.matches
    where tournament_id = p_tournament_id
      and status = 'queued'
    order by queue_position, sequence_number nulls last, created_at, id
  loop
    v_pos := v_pos + 1;
    update public.matches set queue_position = v_pos where id = v_match.id;
  end loop;

  return v_pos;
end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_round_name(p_match_count integer)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
AS $function$
  select case p_match_count
    when 1 then 'Finale'
    when 2 then 'Semifinali'
    when 4 then 'Quarti di finale'
    when 8 then 'Ottavi di finale'
    when 16 then 'Sedicesimi di finale'
    else 'Turno da ' || (p_match_count * 2)::text
  end;
$function$;

CREATE OR REPLACE FUNCTION public.engine_seed_order(p_bracket_size integer)
 RETURNS integer[]
 LANGUAGE plpgsql
 IMMUTABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_order integer[] := array[1,2];
  v_new integer[];
  v_size integer := 2;
  v_seed integer;
begin
  if p_bracket_size < 2 or (p_bracket_size & (p_bracket_size - 1)) <> 0 then
    raise exception 'Bracket size must be a power of two >= 2';
  end if;

  while v_size < p_bracket_size loop
    v_size := v_size * 2;
    v_new := array[]::integer[];
    foreach v_seed in array v_order loop
      v_new := array_append(v_new, v_seed);
      v_new := array_append(v_new, v_size + 1 - v_seed);
    end loop;
    v_order := v_new;
  end loop;
  return v_order;
end;
$function$;

CREATE OR REPLACE FUNCTION public.enqueue_current_notification_for_me(p_tournament_id uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_user_id uuid := auth.uid();
  v_team_id uuid;
  v_match_id uuid;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if exists (
    select 1
    from public.tournament_settings
    where tournament_id = p_tournament_id
      and emergency_paused
  ) then
    return 'none';
  end if;

  select a.team_id
    into v_team_id
  from public.player_team_assignments a
  where a.tournament_id = p_tournament_id
    and a.user_id = v_user_id;

  if v_team_id is null then
    return 'none';
  end if;

  -- Current field call has priority.
  select m.id
    into v_match_id
  from public.matches m
  where m.tournament_id = p_tournament_id
    and v_team_id in (m.team1_id, m.team2_id)
    and m.status in ('called', 'ready')
  order by m.called_at nulls last, m.created_at
  limit 1;

  if v_match_id is not null then
    perform public.engine_enqueue_match_notification(v_match_id, 'called');
    return 'called';
  end if;

  -- Find the actual next eligible match, not simply the absolute queue head.
  select m.id
    into v_match_id
  from public.matches m
  where m.tournament_id = p_tournament_id
    and m.status = 'queued'
    and m.queue_position is not null
    and m.team1_id is not null
    and m.team2_id is not null
    and not exists (
      select 1
      from public.matches live
      where live.tournament_id = p_tournament_id
        and live.id <> m.id
        and live.status in ('called', 'ready', 'playing', 'awaiting_result')
        and (
          live.team1_id in (m.team1_id, m.team2_id)
          or live.team2_id in (m.team1_id, m.team2_id)
        )
    )
  order by m.queue_position, m.sequence_number nulls last, m.created_at, m.id
  limit 1;

  if v_match_id is not null
     and exists (
       select 1
       from public.matches m
       where m.id = v_match_id
         and v_team_id in (m.team1_id, m.team2_id)
     )
  then
    perform public.engine_enqueue_match_notification(v_match_id, 'prepare');
    return 'prepare';
  end if;

  return 'none';
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_tournament_snapshot(p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_tournament_id uuid;
  v_result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select t.id into v_tournament_id
  from public.tournaments t
  where t.slug = p_slug
    and (t.status in ('active','completed','archived') or public.is_admin())
  limit 1;

  if v_tournament_id is null then
    raise exception 'Tournament not found or not visible';
  end if;

  select jsonb_build_object(
    'server_now', clock_timestamp(),
    'my_team_id', (
      select pta.team_id
      from public.player_team_assignments pta
      where pta.tournament_id = v_tournament_id
        and pta.user_id = auth.uid()
      limit 1
    ),
    'tournament', (
      select to_jsonb(x) from (
        select t.id, t.name, t.slug, t.status, t.phase, t.started_at
        from public.tournaments t
        where t.id = v_tournament_id
      ) x
    ),
    'settings', (
      select to_jsonb(x) from (
        select s.tournament_id, s.ordering_mode, s.qualifiers_per_group,
               s.knockout_enabled, s.third_place_enabled, s.pause_enabled,
               s.team_pin_enabled, s.emergency_paused, s.emergency_paused_at
        from public.tournament_settings s
        where s.tournament_id = v_tournament_id
      ) x
    ),
    'teams', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.name)
      from (
        select tm.id, tm.tournament_id, tm.name, tm.status, tm.avatar_url
        from public.teams tm
        where tm.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'groups', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.sort_order, x.name)
      from (
        select g.id, g.tournament_id, g.name, g.sort_order
        from public.groups g
        where g.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'groupTeams', coalesce((
      select jsonb_agg(to_jsonb(x))
      from (
        select gt.id, gt.tournament_id, gt.group_id, gt.team_id, gt.seed, gt.lot_order
        from public.group_teams gt
        where gt.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'fields', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.sort_order, x.name)
      from (
        select f.id, f.tournament_id, f.name, f.sort_order, f.is_active
        from public.fields f
        where f.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'rules', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.scope)
      from (
        select r.id, r.tournament_id, r.scope, r.duration_seconds,
               r.goal_target, r.golden_goal_on_tie
        from public.match_rule_sets r
        where r.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'knockoutRounds', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.round_number, x.sort_order)
      from (
        select kr.id, kr.tournament_id, kr.round_number, kr.name, kr.sort_order
        from public.knockout_rounds kr
        where kr.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'qualifiers', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.global_seed)
      from (
        select q.tournament_id, q.team_id, q.group_id, q.group_rank, q.global_seed,
               q.played, q.points, q.goal_difference, q.goals_for,
               q.points_per_game, q.goal_difference_per_game, q.goals_for_per_game,
               q.lot_order
        from public.tournament_qualifiers q
        where q.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'matches', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.sequence_number nulls last, x.bracket_slot nulls last)
      from (
        select m.id, m.tournament_id, m.stage, m.status, m.group_id,
               m.knockout_round_id, m.bracket_slot, m.sequence_number,
               m.queue_position, m.team1_id, m.team2_id,
               m.team1_source_match_id, m.team2_source_match_id,
               m.team1_source_loser_match_id, m.team2_source_loser_match_id,
               m.field_id, m.duration_seconds, m.goal_target, m.pause_allowed,
               m.golden_goal_on_tie, m.timer_remaining_seconds,
               m.timer_started_at, m.paused_at, m.score_team1, m.score_team2,
               m.winner_team_id, m.started_at, m.called_at, m.ended_at
        from public.matches m
        where m.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb),
    'standings', coalesce((
      select jsonb_agg(to_jsonb(x))
      from (
        select s.tournament_id, s.group_id, s.team_id, s.team_name,
               s.played, s.wins, s.draws, s.losses, s.goals_for,
               s.goals_against, s.goal_difference, s.points, s.lot_order
        from public.group_standings_base s
        where s.tournament_id = v_tournament_id
      ) x
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_tournament_snapshot_by_id(p_tournament_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_slug text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select t.slug into v_slug
  from public.tournaments t
  where t.id = p_tournament_id
    and (t.status in ('active','completed','archived') or public.is_admin())
  limit 1;

  if v_slug is null then
    raise exception 'Tournament not found or not visible';
  end if;

  return public.get_tournament_snapshot(v_slug);
end;
$function$;

CREATE OR REPLACE FUNCTION public.initialize_tournament_defaults()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  insert into public.tournament_settings (tournament_id)
  values (new.id)
  on conflict (tournament_id) do nothing;

  insert into public.match_rule_sets
    (tournament_id, scope, duration_seconds, goal_target, golden_goal_on_tie)
  values
    (new.id, 'group',       420, 10, false),
    (new.id, 'knockout',    420, 10, true),
    (new.id, 'final',       600, 10, true),
    (new.id, 'third_place', 420, 10, true)
  on conflict (tournament_id, scope) do nothing;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.is_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  select exists (
    select 1
    from public.admin_users a
    where a.user_id = auth.uid()
  );
$function$;

CREATE OR REPLACE FUNCTION public.leave_team(p_tournament_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
  delete from public.player_team_assignments
  where tournament_id = p_tournament_id
    and user_id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.lock_tournament(p_tournament_id uuid)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select pg_advisory_xact_lock(hashtext(p_tournament_id::text));
$function$;

CREATE OR REPLACE FUNCTION public.mark_timer_expired(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_elapsed integer;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status = 'awaiting_result' then
    return v_match;
  end if;
  if v_match.status <> 'playing' or v_match.duration_seconds is null then
    raise exception 'This match has no running timer';
  end if;

  if v_match.timer_started_at is not null then
    v_elapsed := floor(extract(epoch from (now() - v_match.timer_started_at)))::integer;
    if v_elapsed < coalesce(v_match.timer_remaining_seconds, 0) then
      raise exception 'Timer has not expired yet';
    end if;
  elsif coalesce(v_match.timer_remaining_seconds, 0) > 0 then
    raise exception 'Timer is paused and has not expired';
  end if;

  update public.matches
  set
    status = 'awaiting_result',
    timer_remaining_seconds = 0,
    timer_started_at = null,
    paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
  values (v_match.tournament_id, p_match_id, 'timer_expired', auth.uid());

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.pause_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_remaining integer;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not v_match.pause_allowed then
    raise exception 'Pause is disabled for this match';
  end if;
  if v_match.status <> 'playing' or v_match.timer_started_at is null then
    raise exception 'Timer is not currently running';
  end if;
  if now() < v_match.timer_started_at then
    raise exception 'Countdown is still running';
  end if;

  v_remaining := greatest(
    0,
    coalesce(v_match.timer_remaining_seconds, 0)
      - floor(extract(epoch from (now() - v_match.timer_started_at)))::integer
  );

  update public.matches
  set
    timer_remaining_seconds = v_remaining,
    timer_started_at = null,
    paused_at = now()
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id, payload)
  values (
    v_match.tournament_id,
    p_match_id,
    'paused',
    auth.uid(),
    jsonb_build_object('remaining_seconds', v_remaining)
  );

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.require_admin()
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.require_group_structure_editable(p_tournament_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_status public.tournament_status;
  v_phase public.tournament_phase;
begin
  select status, phase into v_status, v_phase
  from public.tournaments where id = p_tournament_id;

  if not found then raise exception 'Tournament not found'; end if;
  if v_status not in ('draft','active') or v_phase <> 'groups' then
    raise exception 'La struttura dei gironi non può essere modificata dopo l''inizio della fase eliminatoria';
  end if;
  if exists (select 1 from public.matches where tournament_id=p_tournament_id and stage <> 'group') then
    raise exception 'Il tabellone eliminatorio esiste già: modifica bloccata per evitare risultati incoerenti';
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION public.resume_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not v_match.pause_allowed then
    raise exception 'Pause is disabled for this match';
  end if;
  if v_match.status <> 'playing' or v_match.paused_at is null or v_match.timer_started_at is not null then
    raise exception 'Timer is not paused';
  end if;
  if coalesce(v_match.timer_remaining_seconds, 0) <= 0 then
    raise exception 'Timer has already expired';
  end if;

  update public.matches
  set timer_started_at = now(), paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
  values (v_match.tournament_id, p_match_id, 'resumed', auth.uid());

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_effective_start timestamptz := now() + interval '3 seconds';
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status not in ('called', 'ready') then
    raise exception 'Match cannot be started from status %', v_match.status;
  end if;

  update public.matches
  set
    status = 'playing',
    started_at = v_effective_start,
    timer_remaining_seconds = duration_seconds,
    timer_started_at = case when duration_seconds is null then null else v_effective_start end,
    paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id, payload)
  values (
    v_match.tournament_id,
    p_match_id,
    'started',
    auth.uid(),
    jsonb_build_object('countdown_seconds', 3, 'effective_start', v_effective_start)
  );

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.submit_match_result(p_match_id uuid, p_score_team1 integer, p_score_team2 integer)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_match public.matches%rowtype;
  v_winner uuid;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot submit this result';
  end if;
  if p_score_team1 < 0 or p_score_team2 < 0 then
    raise exception 'Scores cannot be negative';
  end if;

  select * into v_match from public.matches where id=p_match_id for update;
  if v_match.status not in ('playing','awaiting_result') then
    raise exception 'Result is already locked or match is not active';
  end if;
  if v_match.stage <> 'group' and p_score_team1 = p_score_team2 then
    raise exception 'Knockout matches cannot finish tied: continue with golden goal';
  end if;

  if p_score_team1 > p_score_team2 then v_winner := v_match.team1_id;
  elsif p_score_team2 > p_score_team1 then v_winner := v_match.team2_id;
  else v_winner := null;
  end if;

  update public.matches
  set score_team1=p_score_team1,
      score_team2=p_score_team2,
      winner_team_id=v_winner,
      result_submitted_by=auth.uid(),
      result_confirmed_at=now(),
      status='finished',
      ended_at=now(),
      timer_started_at=null,
      paused_at=null,
      field_id=null
  where id=p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id,match_id,event_type,actor_user_id,payload)
  values (v_match.tournament_id,p_match_id,'result_submitted',auth.uid(),
    jsonb_build_object('score_team1',p_score_team1,'score_team2',p_score_team2));

  perform public.engine_after_match_closed(p_match_id);
  return v_match;
end;
$function$;
