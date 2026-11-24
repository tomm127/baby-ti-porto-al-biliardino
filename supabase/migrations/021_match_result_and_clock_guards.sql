-- BTPB 021: validate match results and sample the clock after locking.
-- Apply after 020, outside an active tournament. No data changes.
-- Based on the 018 definitions; 019 and 020 are not modified.
BEGIN;


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
  v_action_now := clock_timestamp();

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
  v_action_now := clock_timestamp();

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
  v_action_now := clock_timestamp();

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
  v_action_now := clock_timestamp();

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
  v_effective_start := clock_timestamp() + interval '3 seconds';

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

  if p_score_team1 is null or p_score_team2 is null then
    raise exception 'Both scores are required';
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

  if not found then
    raise exception 'Partita non trovata';
  end if;

  if v_match.team1_id is null or v_match.team2_id is null or v_match.team1_id = v_match.team2_id then
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
  if p_score_team1 is null or p_score_team2 is null then
    raise exception 'Both scores are required';
  end if;
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
  if v_match.team1_id is null or v_match.team2_id is null or v_match.team1_id = v_match.team2_id then
    raise exception 'Both match teams must be defined and distinct';
  end if;
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
  if p_score_team1 is null or p_score_team2 is null then
    raise exception 'Both scores are required';
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
  if v_match.team1_id is null or v_match.team2_id is null or v_match.team1_id = v_match.team2_id then
    raise exception 'Both match teams must be defined and distinct';
  end if;
  if v_match.status not in ('playing','awaiting_result') then
    raise exception 'Result is already locked or match is not active';
  end if;
  if v_match.status = 'playing' and v_match.started_at is not null and clock_timestamp() < v_match.started_at then
    raise exception 'Countdown is still running';
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
  if v_match.team1_id is null or v_match.team2_id is null or v_match.team1_id = v_match.team2_id then
    raise exception 'Both match teams must be defined and distinct';
  end if;
  if p_loser_team_id is null or p_loser_team_id not in (v_match.team1_id,v_match.team2_id) then raise exception 'Loser must be one of the match teams'; end if;

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

REVOKE EXECUTE ON FUNCTION public.admin_set_match_result(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_match_result(uuid, integer, integer) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_update_match_result(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_match_result(uuid, integer, integer) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.submit_match_result(uuid, integer, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.submit_match_result(uuid, integer, integer) TO authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_forfeit_match(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_forfeit_match(uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
COMMIT;
