-- BTPB migration 018: consistent tournament-first locking.
-- Based on the live function definitions exported on 2026-11-24.
-- Apply after 017. Run this entire file, outside a live tournament.
-- No table/data changes, no new functions, no changes to RPC signatures.
-- Serialize the affected match and structure RPCs with the existing engine lock.
-- Re-check player authorization after the lock and sample the clock afterwards.
-- Direct administrative table writes and PIN/session changes are not covered.
BEGIN;

CREATE OR REPLACE FUNCTION public.admin_assign_match_field(p_match_id uuid, p_field_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
begin
  perform public.require_admin();

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;

  if not found then
    raise exception 'Partita non trovata';
  end if;


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

CREATE OR REPLACE FUNCTION public.admin_cancel_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
begin
  perform public.require_admin();

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;

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

CREATE OR REPLACE FUNCTION public.admin_forfeit_match(p_match_id uuid, p_loser_team_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
  v_winner uuid;
  v_winning_score integer;
  v_s1 integer;
  v_s2 integer;
begin
  perform public.require_admin();
  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
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

CREATE OR REPLACE FUNCTION public.admin_postpone_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
  v_next_position integer;
begin
  perform public.require_admin();

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;

  if v_match.status in ('finished', 'cancelled', 'forfeit') then
    raise exception 'Completed/cancelled match cannot be postponed';
  end if;


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

CREATE OR REPLACE FUNCTION public.admin_set_match_result(p_match_id uuid, p_score_team1 integer, p_score_team2 integer)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
  v_winner uuid;
  v_phase public.tournament_phase;
begin
  perform public.require_admin();

  if p_score_team1 < 0 or p_score_team2 < 0 then
    raise exception 'Scores cannot be negative';
  end if;

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
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

CREATE OR REPLACE FUNCTION public.admin_update_match_result(p_match_id uuid, p_score_team1 integer, p_score_team2 integer)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
  v_old_winner uuid;
  v_old_s1 integer;
  v_old_s2 integer;
  v_new_winner uuid;
  v_tournament_phase public.tournament_phase;
begin
  perform public.require_admin();
  if p_score_team1 < 0 or p_score_team2 < 0 then raise exception 'Scores cannot be negative'; end if;

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
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

CREATE OR REPLACE FUNCTION public.admin_delete_team_completely(p_team_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_team public.teams%rowtype;
begin
  perform public.require_admin();
  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.teams where id = p_team_id;
  if not found then raise exception 'Squadra non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_team
  from public.teams
  where id = p_team_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Squadra non trovata'; end if;
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
  v_lock_tournament_id uuid;
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

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.teams where id = p_team_id;
  if not found then raise exception 'Squadra non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_team
  from public.teams
  where id = p_team_id and tournament_id = v_lock_tournament_id
  for update;

  if not found then raise exception 'Squadra non trovata'; end if;

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

CREATE OR REPLACE FUNCTION public.admin_restore_team(p_team_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
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
  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.teams where id = p_team_id;
  if not found then raise exception 'Squadra non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_team
  from public.teams
  where id = p_team_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Squadra non trovata'; end if;
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

CREATE OR REPLACE FUNCTION public.admin_withdraw_team(p_team_id uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_team public.teams%rowtype;
  v_deleted integer;
begin
  perform public.require_admin();
  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.teams where id = p_team_id;
  if not found then raise exception 'Squadra non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_team
  from public.teams
  where id = p_team_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Squadra non trovata'; end if;
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

CREATE OR REPLACE FUNCTION public.admin_update_field(p_field_id uuid, p_name text, p_is_active boolean)
 RETURNS fields
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid; v_field public.fields%rowtype;
begin
  perform public.require_admin();
  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.fields where id = p_field_id;
  if not found then raise exception 'Campo non trovato'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_field
  from public.fields
  where id = p_field_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Campo non trovato'; end if;
  if p_name is null or length(trim(p_name))=0 then raise exception 'Nome campo obbligatorio'; end if;
  if not p_is_active and exists(
    select 1 from public.matches where field_id=p_field_id and status in('called','ready','playing','awaiting_result')
  ) then raise exception 'Prima termina o rimanda la partita attualmente assegnata a questo campo'; end if;
  update public.fields set name=trim(p_name),is_active=p_is_active where id=p_field_id returning * into v_field;
  if p_is_active then perform public.engine_fill_free_fields(v_field.tournament_id); end if;
  return v_field;
end;
$function$;

CREATE OR REPLACE FUNCTION public.end_match_early(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_action_now timestamptz;
  v_match public.matches%rowtype;
  v_remaining integer;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;
  v_action_now := clock_timestamp();

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  if v_match.status <> 'playing' then
    raise exception 'Match is not playing';
  end if;
  if v_match.started_at is not null and v_action_now < v_match.started_at then
    raise exception 'Countdown is still running';
  end if;

  v_remaining := v_match.timer_remaining_seconds;
  if v_match.timer_started_at is not null then
    v_remaining := greatest(
      0,
      coalesce(v_match.timer_remaining_seconds, 0)
        - floor(extract(epoch from (v_action_now - v_match.timer_started_at)))::integer
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

CREATE OR REPLACE FUNCTION public.mark_timer_expired(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_action_now timestamptz;
  v_match public.matches%rowtype;
  v_elapsed integer;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;
  v_action_now := clock_timestamp();

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  if v_match.status = 'awaiting_result' then
    return v_match;
  end if;
  if v_match.status <> 'playing' or v_match.duration_seconds is null then
    raise exception 'This match has no running timer';
  end if;

  if v_match.timer_started_at is not null then
    v_elapsed := floor(extract(epoch from (v_action_now - v_match.timer_started_at)))::integer;
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
  v_lock_tournament_id uuid;
  v_action_now timestamptz;
  v_match public.matches%rowtype;
  v_remaining integer;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;
  v_action_now := clock_timestamp();

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

  if not v_match.pause_allowed then
    raise exception 'Pause is disabled for this match';
  end if;
  if v_match.status <> 'playing' or v_match.timer_started_at is null then
    raise exception 'Timer is not currently running';
  end if;
  if v_action_now < v_match.timer_started_at then
    raise exception 'Countdown is still running';
  end if;

  v_remaining := greatest(
    0,
    coalesce(v_match.timer_remaining_seconds, 0)
      - floor(extract(epoch from (v_action_now - v_match.timer_started_at)))::integer
  );

  update public.matches
  set
    timer_remaining_seconds = v_remaining,
    timer_started_at = null,
    paused_at = v_action_now
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

CREATE OR REPLACE FUNCTION public.resume_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_action_now timestamptz;
  v_match public.matches%rowtype;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;
  v_action_now := clock_timestamp();

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

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
  set timer_started_at = v_action_now, paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
  values (v_match.tournament_id, p_match_id, 'resumed', auth.uid());

  return v_match;
end;
$function$;

CREATE OR REPLACE FUNCTION public.start_match(p_match_id uuid)
 RETURNS matches
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
  v_effective_start timestamptz;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;
  v_effective_start := clock_timestamp() + interval '3 seconds';

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot control this match';
  end if;

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
  v_lock_tournament_id uuid;
  v_match public.matches%rowtype;
  v_winner uuid;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot submit this result';
  end if;
  if p_score_team1 < 0 or p_score_team2 < 0 then
    raise exception 'Scores cannot be negative';
  end if;

  -- Acquire the shared tournament lock before any row lock.
  select tournament_id into v_lock_tournament_id
  from public.matches where id = p_match_id;
  if not found then raise exception 'Partita non trovata'; end if;
  perform public.lock_tournament(v_lock_tournament_id);

  select * into v_match
  from public.matches
  where id = p_match_id and tournament_id = v_lock_tournament_id
  for update;
  if not found then raise exception 'Partita non trovata'; end if;
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot submit this result';
  end if;
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

CREATE OR REPLACE FUNCTION public.admin_set_emergency_pause(p_tournament_id uuid, p_paused boolean)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
declare
  v_current boolean;
  v_now timestamptz;
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
  v_now := clock_timestamp();

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

-- Preserve the client RPC access rules established in 016.
REVOKE EXECUTE ON FUNCTION public.admin_assign_match_field(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_assign_match_field(uuid,uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_cancel_match(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cancel_match(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_forfeit_match(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_forfeit_match(uuid,uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_postpone_match(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_postpone_match(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_set_match_result(uuid,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_match_result(uuid,integer,integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_update_match_result(uuid,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_match_result(uuid,integer,integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_delete_team_completely(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_delete_team_completely(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_force_move_team_group(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_force_move_team_group(uuid,uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_restore_team(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_restore_team(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_withdraw_team(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_withdraw_team(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_update_field(uuid,text,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_field(uuid,text,boolean) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.end_match_early(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.end_match_early(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.mark_timer_expired(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mark_timer_expired(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.pause_match(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.pause_match(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.resume_match(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resume_match(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.start_match(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.start_match(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.submit_match_result(uuid,integer,integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_match_result(uuid,integer,integer) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_set_emergency_pause(uuid,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_emergency_pause(uuid,boolean) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
