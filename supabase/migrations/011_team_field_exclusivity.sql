-- BTPB
-- Migration 011: one active field per team + eligible queue skipping
-- Apply AFTER the currently installed live-engine / emergency-pause migrations.

begin;

-- ---------------------------------------------------------------------------
-- Prepare notification:
-- use the first QUEUED match whose two teams are not already committed to
-- another live field. Busy matches remain in their queue position and are
-- simply skipped until their teams become free.
-- ---------------------------------------------------------------------------
create or replace function public.engine_enqueue_prepare_for_next(
  p_tournament_id uuid
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke all on function public.engine_enqueue_prepare_for_next(uuid) from public;


-- ---------------------------------------------------------------------------
-- Automatic field assignment:
-- for every free field choose the FIRST ELIGIBLE queued match.
--
-- Example:
--   queue #1 = A vs B, but A is already playing -> skip for now
--   queue #2 = C vs D, both free               -> call C vs D
--
-- #1 stays in its original queue position and becomes eligible again as soon
-- as A is no longer called/ready/playing/awaiting_result.
-- If no eligible match exists, the field intentionally stays empty.
-- ---------------------------------------------------------------------------
create or replace function public.engine_fill_free_fields(
  p_tournament_id uuid
)
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
$$;

revoke all on function public.engine_fill_free_fields(uuid) from public;


-- ---------------------------------------------------------------------------
-- If a player enables notifications while the tournament is running,
-- do not send a "prepare" notification for a queued match involving a team
-- that is currently busy on another field.
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_current_notification_for_me(
  p_tournament_id uuid
)
returns text
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.enqueue_current_notification_for_me(uuid) from public;
grant execute on function public.enqueue_current_notification_for_me(uuid) to authenticated;


-- ---------------------------------------------------------------------------
-- Manual admin field assignment receives the same protection.
-- Moving the SAME live match from one free field to another is still allowed;
-- only another live match containing either team causes a block.
-- ---------------------------------------------------------------------------
create or replace function public.admin_assign_match_field(
  p_match_id uuid,
  p_field_id uuid
)
returns public.matches
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.admin_assign_match_field(uuid, uuid) from public;
grant execute on function public.admin_assign_match_field(uuid, uuid) to authenticated;

commit;
