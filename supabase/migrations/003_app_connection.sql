-- Baby ti porto al biliardino
-- Migration 003: synchronized countdown + admin result correction
-- Apply AFTER 002_live_engine.sql

begin;

-- -----------------------------------------------------------------------------
-- 3-2-1 synchronized countdown.
-- A match enters PLAYING immediately, but its effective start is 3 seconds later.
-- All clients use started_at / timer_started_at as the common clock anchor.
-- -----------------------------------------------------------------------------
create or replace function public.start_match(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.start_match(uuid) from public;
grant execute on function public.start_match(uuid) to authenticated;

-- Do not allow pause while the synchronized 3-2-1 is still running.
create or replace function public.pause_match(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.pause_match(uuid) from public;
grant execute on function public.pause_match(uuid) to authenticated;

create or replace function public.end_match_early(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.end_match_early(uuid) from public;
grant execute on function public.end_match_early(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Only the admin can alter a result after it has been confirmed/locked.
-- Standings are calculated from matches, so they update automatically.
-- -----------------------------------------------------------------------------
create or replace function public.admin_update_match_result(
  p_match_id uuid,
  p_score_team1 integer,
  p_score_team2 integer
)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_match public.matches%rowtype;
  v_old_score_team1 integer;
  v_old_score_team2 integer;
  v_winner uuid;
begin
  perform public.require_admin();

  if p_score_team1 < 0 or p_score_team2 < 0 then
    raise exception 'Scores cannot be negative';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status not in ('finished', 'forfeit') then
    raise exception 'Only a closed match result can be corrected';
  end if;
  if v_match.stage <> 'group' and p_score_team1 = p_score_team2 then
    raise exception 'Knockout matches cannot finish tied';
  end if;

  v_old_score_team1 := v_match.score_team1;
  v_old_score_team2 := v_match.score_team2;

  if p_score_team1 > p_score_team2 then
    v_winner := v_match.team1_id;
  elsif p_score_team2 > p_score_team1 then
    v_winner := v_match.team2_id;
  else
    v_winner := null;
  end if;

  update public.matches
  set
    score_team1 = p_score_team1,
    score_team2 = p_score_team2,
    winner_team_id = v_winner,
    result_submitted_by = auth.uid(),
    result_confirmed_at = now(),
    status = 'finished'
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id, payload)
  values (
    v_match.tournament_id,
    p_match_id,
    'result_changed',
    auth.uid(),
    jsonb_build_object(
      'old_score_team1', v_old_score_team1,
      'old_score_team2', v_old_score_team2,
      'score_team1', p_score_team1,
      'score_team2', p_score_team2
    )
  );

  return v_match;
end;
$$;

revoke all on function public.admin_update_match_result(uuid, integer, integer) from public;
grant execute on function public.admin_update_match_result(uuid, integer, integer) to authenticated;

commit;
