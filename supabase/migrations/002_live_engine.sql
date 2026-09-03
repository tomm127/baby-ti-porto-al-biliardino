-- Baby ti porto al biliardino
-- Migration 002: transaction-safe live tournament engine
-- Apply AFTER 001_initial_schema.sql

begin;

-- -----------------------------------------------------------------------------
-- Internal helpers
-- -----------------------------------------------------------------------------
create or replace function public.require_admin()
returns void
language plpgsql
stable
security definer
set search_path = public, auth
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
end;
$$;

revoke all on function public.require_admin() from public;

create or replace function public.can_control_match(p_match_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.is_admin()
      or exists (
        select 1
        from public.matches m
        join public.player_team_assignments a
          on a.tournament_id = m.tournament_id
         and a.user_id = auth.uid()
         and a.team_id in (m.team1_id, m.team2_id)
        join public.tournaments t on t.id = m.tournament_id
        where m.id = p_match_id
          and t.status = 'active'
      );
$$;

revoke all on function public.can_control_match(uuid) from public;
grant execute on function public.can_control_match(uuid) to authenticated;

-- One transaction at a time may advance a tournament's live queue.
create or replace function public.lock_tournament(p_tournament_id uuid)
returns void
language sql
volatile
security definer
set search_path = public
as $$
  select pg_advisory_xact_lock(hashtext(p_tournament_id::text));
$$;

revoke all on function public.lock_tournament(uuid) from public;

-- -----------------------------------------------------------------------------
-- Install a complete group-stage schedule produced by the TypeScript engine.
-- Expected JSON array objects:
-- {"group_id":"...", "team1_id":"...", "team2_id":"...", "sequence_number":1}
-- -----------------------------------------------------------------------------
create or replace function public.admin_install_group_schedule(
  p_tournament_id uuid,
  p_matches jsonb
)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.admin_install_group_schedule(uuid, jsonb) from public;
grant execute on function public.admin_install_group_schedule(uuid, jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- Internal queue advancement. Strict queue order; no fairness/rest reordering.
-- -----------------------------------------------------------------------------
create or replace function public.engine_fill_free_fields(p_tournament_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_field record;
  v_match_id uuid;
  v_assigned integer := 0;
begin
  perform public.lock_tournament(p_tournament_id);

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
    order by m.queue_position, m.sequence_number nulls last, m.created_at
    for update skip locked
    limit 1;

    exit when v_match_id is null;

    update public.matches
    set
      status = 'called',
      field_id = v_field.id,
      queue_position = null,
      called_at = now(),
      ready_at = null
    where id = v_match_id;

    insert into public.match_events (tournament_id, match_id, event_type, actor_user_id, payload)
    values (
      p_tournament_id,
      v_match_id,
      'called',
      auth.uid(),
      jsonb_build_object('field_id', v_field.id)
    );

    v_assigned := v_assigned + 1;
  end loop;

  return v_assigned;
end;
$$;

revoke all on function public.engine_fill_free_fields(uuid) from public;

-- -----------------------------------------------------------------------------
-- Start group stage: queue in strict generated order and fill all free fields.
-- -----------------------------------------------------------------------------
create or replace function public.admin_start_tournament(p_tournament_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_queued integer;
  v_assigned integer;
begin
  perform public.require_admin();
  perform public.lock_tournament(p_tournament_id);

  if not exists (
    select 1 from public.fields
    where tournament_id = p_tournament_id and is_active
  ) then
    raise exception 'At least one active field is required';
  end if;

  if not exists (
    select 1 from public.matches
    where tournament_id = p_tournament_id and stage = 'group'
  ) then
    raise exception 'Generate the group schedule first';
  end if;

  update public.tournaments
  set status = 'active', phase = 'groups', started_at = coalesce(started_at, now())
  where id = p_tournament_id;

  if not found then
    raise exception 'Tournament not found';
  end if;

  update public.matches
  set
    status = 'queued',
    queue_position = sequence_number,
    field_id = null,
    called_at = null,
    ready_at = null,
    started_at = null,
    ended_at = null
  where tournament_id = p_tournament_id
    and stage = 'group'
    and status = 'scheduled';

  get diagnostics v_queued = row_count;
  v_assigned := public.engine_fill_free_fields(p_tournament_id);

  return v_assigned;
end;
$$;

revoke all on function public.admin_start_tournament(uuid) from public;
grant execute on function public.admin_start_tournament(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Player/admin live controls
-- -----------------------------------------------------------------------------
create or replace function public.start_match(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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

  if v_match.status not in ('called', 'ready') then
    raise exception 'Match cannot be started from status %', v_match.status;
  end if;

  update public.matches
  set
    status = 'playing',
    started_at = coalesce(started_at, now()),
    timer_remaining_seconds = duration_seconds,
    timer_started_at = case when duration_seconds is null then null else now() end,
    paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id)
  values (v_match.tournament_id, p_match_id, 'started', auth.uid());

  return v_match;
end;
$$;

revoke all on function public.start_match(uuid) from public;
grant execute on function public.start_match(uuid) to authenticated;

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

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id,
                                   payload)
  values (v_match.tournament_id, p_match_id, 'paused', auth.uid(),
          jsonb_build_object('remaining_seconds', v_remaining));

  return v_match;
end;
$$;

revoke all on function public.pause_match(uuid) from public;
grant execute on function public.pause_match(uuid) to authenticated;

create or replace function public.resume_match(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.resume_match(uuid) from public;
grant execute on function public.resume_match(uuid) to authenticated;

-- Called by a participating device/admin when its synchronized timer reaches zero.
create or replace function public.mark_timer_expired(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.mark_timer_expired(uuid) from public;
grant execute on function public.mark_timer_expired(uuid) to authenticated;

-- "TERMINA PARTITA" when a goal target is reached before time expires,
-- or for no-timer matches.
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

-- Result becomes locked immediately after one participating device confirms it.
create or replace function public.submit_match_result(
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
  v_winner uuid;
begin
  if not public.can_control_match(p_match_id) then
    raise exception 'You cannot submit this result';
  end if;
  if p_score_team1 < 0 or p_score_team2 < 0 then
    raise exception 'Scores cannot be negative';
  end if;

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status not in ('playing', 'awaiting_result') then
    raise exception 'Result is already locked or match is not active';
  end if;

  if v_match.stage <> 'group' and p_score_team1 = p_score_team2 then
    raise exception 'Knockout matches cannot finish tied: continue with golden goal';
  end if;

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
    status = 'finished',
    ended_at = now(),
    timer_started_at = null,
    paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id, payload)
  values (
    v_match.tournament_id,
    p_match_id,
    'result_submitted',
    auth.uid(),
    jsonb_build_object('score_team1', p_score_team1, 'score_team2', p_score_team2)
  );

  perform public.engine_fill_free_fields(v_match.tournament_id);
  return v_match;
end;
$$;

revoke all on function public.submit_match_result(uuid, integer, integer) from public;
grant execute on function public.submit_match_result(uuid, integer, integer) to authenticated;

-- -----------------------------------------------------------------------------
-- Admin interventions
-- -----------------------------------------------------------------------------
create or replace function public.admin_postpone_match(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.admin_postpone_match(uuid) from public;
grant execute on function public.admin_postpone_match(uuid) to authenticated;

create or replace function public.admin_forfeit_match(
  p_match_id uuid,
  p_loser_team_id uuid
)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_match public.matches%rowtype;
  v_winner uuid;
  v_winning_score integer;
  v_s1 integer;
  v_s2 integer;
begin
  perform public.require_admin();

  select * into v_match
  from public.matches
  where id = p_match_id
  for update;

  if v_match.status in ('finished', 'cancelled', 'forfeit') then
    raise exception 'Match is already closed';
  end if;
  if p_loser_team_id not in (v_match.team1_id, v_match.team2_id) then
    raise exception 'Loser must be one of the match teams';
  end if;

  v_winner := case when p_loser_team_id = v_match.team1_id then v_match.team2_id else v_match.team1_id end;
  v_winning_score := coalesce(v_match.goal_target, 1);

  if v_winner = v_match.team1_id then
    v_s1 := v_winning_score; v_s2 := 0;
  else
    v_s1 := 0; v_s2 := v_winning_score;
  end if;

  update public.matches
  set
    score_team1 = v_s1,
    score_team2 = v_s2,
    winner_team_id = v_winner,
    result_submitted_by = auth.uid(),
    result_confirmed_at = now(),
    status = 'forfeit',
    ended_at = now(),
    timer_started_at = null,
    paused_at = null
  where id = p_match_id
  returning * into v_match;

  insert into public.match_events (tournament_id, match_id, event_type, actor_user_id, payload)
  values (
    v_match.tournament_id,
    p_match_id,
    'forfeited',
    auth.uid(),
    jsonb_build_object('loser_team_id', p_loser_team_id, 'score_team1', v_s1, 'score_team2', v_s2)
  );

  perform public.engine_fill_free_fields(v_match.tournament_id);
  return v_match;
end;
$$;

revoke all on function public.admin_forfeit_match(uuid, uuid) from public;
grant execute on function public.admin_forfeit_match(uuid, uuid) to authenticated;

create or replace function public.admin_cancel_match(p_match_id uuid)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.admin_cancel_match(uuid) from public;
grant execute on function public.admin_cancel_match(uuid) to authenticated;

-- Admin can reorder queued matches by sending the complete queue as an ordered UUID array.
create or replace function public.admin_reorder_queue(
  p_tournament_id uuid,
  p_match_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.admin_reorder_queue(uuid, uuid[]) from public;
grant execute on function public.admin_reorder_queue(uuid, uuid[]) to authenticated;

commit;
