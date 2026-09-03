-- Baby ti porto al biliardino
-- Migration 004: Web Push notification outbox + strict "one match before" notifications
-- Apply AFTER 003_app_connection.sql

begin;

-- -----------------------------------------------------------------------------
-- Notification outbox. Jobs are created only by server-side tournament logic.
-- The Edge Function claims and sends them with the service-role key.
-- -----------------------------------------------------------------------------
create table if not exists public.notification_jobs (
  id bigint generated always as identity primary key,
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  match_id uuid references public.matches(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null check (kind in ('prepare', 'called')),
  title text not null,
  body text not null,
  url text not null,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending' check (status in ('pending', 'processing', 'sent', 'failed')),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  processing_at timestamptz,
  sent_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  unique (user_id, match_id, kind)
);

create index if not exists notification_jobs_pending_idx
  on public.notification_jobs (status, created_at)
  where status in ('pending', 'processing');

alter table public.notification_jobs enable row level security;
revoke all on table public.notification_jobs from anon, authenticated;
-- service_role bypasses RLS; no browser access is required.

-- -----------------------------------------------------------------------------
-- Internal helper: create jobs for every device currently associated to either
-- team in a match. A user corresponds to one anonymous/authenticated browser
-- identity; each user may have one or more push subscriptions.
-- -----------------------------------------------------------------------------
create or replace function public.engine_enqueue_match_notification(
  p_match_id uuid,
  p_kind text
)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.engine_enqueue_match_notification(uuid, text) from public;

-- The one and only queued match at the head receives the "prepare" event.
-- This is evaluated AFTER all currently free fields have been filled.
create or replace function public.engine_enqueue_prepare_for_next(p_tournament_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_match_id uuid;
begin
  select m.id into v_match_id
  from public.matches m
  where m.tournament_id = p_tournament_id
    and m.status = 'queued'
    and m.queue_position is not null
    and m.team1_id is not null
    and m.team2_id is not null
  order by m.queue_position, m.sequence_number nulls last, m.created_at
  limit 1;

  if v_match_id is null then
    return 0;
  end if;

  return public.engine_enqueue_match_notification(v_match_id, 'prepare');
end;
$$;

revoke all on function public.engine_enqueue_prepare_for_next(uuid) from public;

-- If a device enables notifications (or changes team) after the tournament has
-- already started, enqueue only the notification that is relevant RIGHT NOW.
create or replace function public.enqueue_current_notification_for_me(p_tournament_id uuid)
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

  select a.team_id into v_team_id
  from public.player_team_assignments a
  where a.tournament_id = p_tournament_id
    and a.user_id = v_user_id;

  if v_team_id is null then
    return 'none';
  end if;

  -- Current field assignment has priority.
  select m.id into v_match_id
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

  -- Otherwise only the absolute queue head is "one match before".
  select m.id into v_match_id
  from public.matches m
  where m.tournament_id = p_tournament_id
    and m.status = 'queued'
    and m.queue_position is not null
  order by m.queue_position, m.sequence_number nulls last, m.created_at
  limit 1;

  if v_match_id is not null and exists (
    select 1 from public.matches m
    where m.id = v_match_id and v_team_id in (m.team1_id, m.team2_id)
  ) then
    perform public.engine_enqueue_match_notification(v_match_id, 'prepare');
    return 'prepare';
  end if;

  return 'none';
end;
$$;

revoke all on function public.enqueue_current_notification_for_me(uuid) from public;
grant execute on function public.enqueue_current_notification_for_me(uuid) to authenticated;

-- Replacing claim_team keeps the same PIN/security behavior from migration 001,
-- while also catching a newly selected team if this device already has push on.
create or replace function public.claim_team(p_team_id uuid, p_pin text default null)
returns uuid
language plpgsql
security definer
set search_path = public, extensions, auth
as $$
declare
  v_user_id uuid := auth.uid();
  v_tournament_id uuid;
  v_pin_enabled boolean;
  v_pin_hash text;
  v_assignment_id uuid;
begin
  if v_user_id is null then raise exception 'Authentication required'; end if;

  select tm.tournament_id, s.team_pin_enabled, tm.team_pin_hash
    into v_tournament_id, v_pin_enabled, v_pin_hash
  from public.teams tm
  join public.tournaments t on t.id = tm.tournament_id
  join public.tournament_settings s on s.tournament_id = tm.tournament_id
  where tm.id = p_team_id and tm.status = 'active' and t.status = 'active';

  if v_tournament_id is null then raise exception 'Active team not found'; end if;
  if v_pin_enabled then
    if v_pin_hash is null then raise exception 'This team has no PIN configured'; end if;
    if p_pin is null or extensions.crypt(p_pin, v_pin_hash) <> v_pin_hash then
      raise exception 'Invalid team PIN';
    end if;
  end if;

  insert into public.player_team_assignments (tournament_id, team_id, user_id, last_seen_at)
  values (v_tournament_id, p_team_id, v_user_id, now())
  on conflict (tournament_id, user_id)
  do update set team_id = excluded.team_id, updated_at = now(), last_seen_at = now()
  returning id into v_assignment_id;

  perform public.enqueue_current_notification_for_me(v_tournament_id);
  return v_assignment_id;
end;
$$;

revoke all on function public.claim_team(uuid, text) from public;
grant execute on function public.claim_team(uuid, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Replace the queue-filling function from migration 002. Ordering remains
-- STRICT. New behavior: enqueue "called" for assigned matches, then enqueue
-- exactly the current queue head as "prepare" after all free fields are filled.
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

    perform public.engine_enqueue_match_notification(v_match_id, 'called');
    v_assigned := v_assigned + 1;
  end loop;

  -- IMPORTANT: only now, after all free fields have been assigned, identify
  -- the single true "one match before" match.
  perform public.engine_enqueue_prepare_for_next(p_tournament_id);

  return v_assigned;
end;
$$;

revoke all on function public.engine_fill_free_fields(uuid) from public;

-- -----------------------------------------------------------------------------
-- Edge Function service-role RPCs.
-- A stale processing job is reclaimable after 90 seconds.
-- -----------------------------------------------------------------------------
create or replace function public.claim_push_jobs(p_limit integer default 50)
returns table (
  id bigint,
  tournament_id uuid,
  match_id uuid,
  user_id uuid,
  kind text,
  title text,
  body text,
  url text,
  payload jsonb
)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'Service role required';
  end if;

  return query
  with candidates as (
    select j.id
    from public.notification_jobs j
    where j.status = 'pending'
       or (j.status = 'processing' and j.processing_at < now() - interval '90 seconds')
    order by j.created_at
    for update skip locked
    limit greatest(1, least(coalesce(p_limit, 50), 200))
  ), claimed as (
    update public.notification_jobs j
    set status = 'processing',
        processing_at = now(),
        attempt_count = j.attempt_count + 1,
        last_error = null
    from candidates c
    where j.id = c.id
    returning j.*
  )
  select c.id, c.tournament_id, c.match_id, c.user_id, c.kind,
         c.title, c.body, c.url, c.payload
  from claimed c
  order by c.created_at;
end;
$$;

revoke all on function public.claim_push_jobs(integer) from public;
grant execute on function public.claim_push_jobs(integer) to service_role;

create or replace function public.complete_push_job(
  p_job_id bigint,
  p_success boolean,
  p_error text default null
)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.complete_push_job(bigint, boolean, text) from public;
grant execute on function public.complete_push_job(bigint, boolean, text) to service_role;

commit;
