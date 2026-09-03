-- Baby ti porto al biliardino
-- Migration 001: core tournament schema + security foundation
-- Target: Supabase Postgres

begin;

-- -----------------------------------------------------------------------------
-- Extensions
-- -----------------------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;

-- -----------------------------------------------------------------------------
-- Enums
-- -----------------------------------------------------------------------------
do $$ begin
  create type public.tournament_status as enum ('draft', 'active', 'completed', 'archived');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.tournament_phase as enum ('groups', 'knockout', 'completed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.ordering_mode as enum ('group_sequential', 'group_rotation');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.team_status as enum ('active', 'withdrawn');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.match_stage as enum ('group', 'knockout', 'final', 'third_place');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.rule_scope as enum ('group', 'knockout', 'final', 'third_place');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.match_status as enum (
    'scheduled',
    'queued',
    'called',
    'ready',
    'playing',
    'awaiting_result',
    'finished',
    'postponed',
    'cancelled',
    'forfeit'
  );
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.match_event_type as enum (
    'created',
    'queued',
    'called',
    'started',
    'paused',
    'resumed',
    'timer_expired',
    'result_submitted',
    'result_changed',
    'postponed',
    'forfeited',
    'cancelled',
    'field_changed'
  );
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- Core tables
-- -----------------------------------------------------------------------------
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists public.tournaments (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) between 1 and 120),
  slug text not null unique check (slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  status public.tournament_status not null default 'draft',
  phase public.tournament_phase not null default 'groups',
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  completed_at timestamptz,
  archived_at timestamptz
);

create table if not exists public.tournament_settings (
  tournament_id uuid primary key references public.tournaments(id) on delete cascade,
  ordering_mode public.ordering_mode not null default 'group_rotation',
  qualifiers_per_group integer not null default 2 check (qualifiers_per_group > 0),
  knockout_enabled boolean not null default true,
  third_place_enabled boolean not null default false,
  pause_enabled boolean not null default true,
  team_pin_enabled boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.match_rule_sets (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  scope public.rule_scope not null,
  duration_seconds integer check (duration_seconds is null or duration_seconds > 0),
  goal_target integer check (goal_target is null or goal_target > 0),
  golden_goal_on_tie boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tournament_id, scope),
  check (duration_seconds is not null or goal_target is not null)
);

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  status public.team_status not null default 'active',
  team_pin_hash text,
  withdrawn_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, tournament_id)
);

create unique index if not exists teams_name_unique_per_tournament
  on public.teams (tournament_id, lower(name));

create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 60),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, tournament_id)
);

create unique index if not exists groups_name_unique_per_tournament
  on public.groups (tournament_id, lower(name));

create table if not exists public.group_teams (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  group_id uuid not null,
  team_id uuid not null,
  seed integer,
  -- Stable final tie-break value. It is generated once, not recalculated on reads.
  lot_order double precision not null default random(),
  created_at timestamptz not null default now(),
  unique (tournament_id, team_id),
  unique (group_id, team_id),
  foreign key (group_id, tournament_id)
    references public.groups(id, tournament_id) on delete cascade,
  foreign key (team_id, tournament_id)
    references public.teams(id, tournament_id) on delete cascade
);

create table if not exists public.fields (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, tournament_id)
);

create unique index if not exists fields_name_unique_per_tournament
  on public.fields (tournament_id, lower(name));

create table if not exists public.knockout_rounds (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  round_number integer not null check (round_number > 0),
  name text not null check (length(trim(name)) between 1 and 60),
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, tournament_id),
  unique (tournament_id, round_number, name)
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,

  stage public.match_stage not null,
  status public.match_status not null default 'scheduled',

  group_id uuid,
  knockout_round_id uuid,
  bracket_slot integer check (bracket_slot is null or bracket_slot > 0),

  -- Stable generated order and editable live queue order are intentionally separate.
  sequence_number integer,
  queue_position integer check (queue_position is null or queue_position > 0),

  team1_id uuid,
  team2_id uuid,

  -- For later knockout rounds. Winners from these matches populate team1/team2.
  team1_source_match_id uuid,
  team2_source_match_id uuid,

  field_id uuid,

  -- Snapshot of rules when the match enters the live queue.
  duration_seconds integer check (duration_seconds is null or duration_seconds > 0),
  goal_target integer check (goal_target is null or goal_target > 0),
  pause_allowed boolean not null default true,
  golden_goal_on_tie boolean not null default false,

  -- Timer state. While running:
  -- remaining = timer_remaining_seconds - (now() - timer_started_at)
  timer_remaining_seconds integer check (timer_remaining_seconds is null or timer_remaining_seconds >= 0),
  timer_started_at timestamptz,
  paused_at timestamptz,

  score_team1 integer check (score_team1 is null or score_team1 >= 0),
  score_team2 integer check (score_team2 is null or score_team2 >= 0),
  winner_team_id uuid,
  result_submitted_by uuid references auth.users(id) on delete set null,
  result_confirmed_at timestamptz,

  called_at timestamptz,
  ready_at timestamptz,
  started_at timestamptz,
  ended_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (id, tournament_id),

  foreign key (group_id, tournament_id)
    references public.groups(id, tournament_id) on delete restrict,
  foreign key (knockout_round_id, tournament_id)
    references public.knockout_rounds(id, tournament_id) on delete restrict,
  foreign key (team1_id, tournament_id)
    references public.teams(id, tournament_id) on delete restrict,
  foreign key (team2_id, tournament_id)
    references public.teams(id, tournament_id) on delete restrict,
  foreign key (winner_team_id, tournament_id)
    references public.teams(id, tournament_id) on delete restrict,
  foreign key (field_id, tournament_id)
    references public.fields(id, tournament_id) on delete restrict,
  foreign key (team1_source_match_id, tournament_id)
    references public.matches(id, tournament_id) on delete restrict,
  foreign key (team2_source_match_id, tournament_id)
    references public.matches(id, tournament_id) on delete restrict,

  check (team1_id is null or team2_id is null or team1_id <> team2_id),
  check (
    (stage = 'group' and group_id is not null and knockout_round_id is null)
    or
    (stage <> 'group' and group_id is null)
  ),
  check (
    (score_team1 is null and score_team2 is null)
    or
    (score_team1 is not null and score_team2 is not null)
  )
);

create index if not exists matches_tournament_status_idx
  on public.matches (tournament_id, status);

create index if not exists matches_group_idx
  on public.matches (group_id) where group_id is not null;

create index if not exists matches_queue_idx
  on public.matches (tournament_id, queue_position)
  where status = 'queued' and queue_position is not null;

create unique index if not exists matches_unique_queue_position
  on public.matches (tournament_id, queue_position)
  where status = 'queued' and queue_position is not null;

-- A field cannot have two live matches at once.
create unique index if not exists one_live_match_per_field
  on public.matches (field_id)
  where field_id is not null
    and status in ('called', 'ready', 'playing', 'awaiting_result');

create table if not exists public.player_team_assignments (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  team_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (tournament_id, user_id),
  foreign key (team_id, tournament_id)
    references public.teams(id, tournament_id) on delete cascade
);

create index if not exists player_team_assignments_team_idx
  on public.player_team_assignments (tournament_id, team_id);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth_key text not null,
  user_agent text,
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  unique (user_id, endpoint)
);

create table if not exists public.match_events (
  id bigint generated always as identity primary key,
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  match_id uuid not null,
  event_type public.match_event_type not null,
  actor_user_id uuid references auth.users(id) on delete set null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  foreign key (match_id, tournament_id)
    references public.matches(id, tournament_id) on delete cascade
);

create index if not exists match_events_match_idx
  on public.match_events (match_id, created_at);

create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users(id) on delete set null,
  table_name text not null,
  row_id text,
  action text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.user_id = auth.uid()
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

create or replace function public.can_view_tournament(p_tournament_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select public.is_admin()
     or exists (
       select 1
       from public.tournaments t
       where t.id = p_tournament_id
         and t.status in ('active', 'completed', 'archived')
     );
$$;

revoke all on function public.can_view_tournament(uuid) from public;
grant execute on function public.can_view_tournament(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Tournament defaults
-- Temporary defaults; editable from admin UI.
-- Groups/knockout: 7 min or first to 10.
-- Final: 10 min or first to 10.
-- -----------------------------------------------------------------------------
create or replace function public.initialize_tournament_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
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
$$;

-- -----------------------------------------------------------------------------
-- PIN functions
-- PINs are never stored in plaintext.
-- -----------------------------------------------------------------------------
create or replace function public.admin_set_team_pin(p_team_id uuid, p_pin text)
returns void
language plpgsql
security definer
set search_path = public, extensions, auth
as $$
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
$$;

revoke all on function public.admin_set_team_pin(uuid, text) from public;
grant execute on function public.admin_set_team_pin(uuid, text) to authenticated;

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
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  select tm.tournament_id, s.team_pin_enabled, tm.team_pin_hash
    into v_tournament_id, v_pin_enabled, v_pin_hash
  from public.teams tm
  join public.tournaments t on t.id = tm.tournament_id
  join public.tournament_settings s on s.tournament_id = tm.tournament_id
  where tm.id = p_team_id
    and tm.status = 'active'
    and t.status = 'active';

  if v_tournament_id is null then
    raise exception 'Active team not found';
  end if;

  if v_pin_enabled then
    if v_pin_hash is null then
      raise exception 'This team has no PIN configured';
    end if;

    if p_pin is null or extensions.crypt(p_pin, v_pin_hash) <> v_pin_hash then
      raise exception 'Invalid team PIN';
    end if;
  end if;

  insert into public.player_team_assignments
    (tournament_id, team_id, user_id, last_seen_at)
  values
    (v_tournament_id, p_team_id, v_user_id, now())
  on conflict (tournament_id, user_id)
  do update set
    team_id = excluded.team_id,
    updated_at = now(),
    last_seen_at = now()
  returning id into v_assignment_id;

  return v_assignment_id;
end;
$$;

revoke all on function public.claim_team(uuid, text) from public;
grant execute on function public.claim_team(uuid, text) to authenticated;

create or replace function public.leave_team(p_tournament_id uuid)
returns void
language sql
security definer
set search_path = public, auth
as $$
  delete from public.player_team_assignments
  where tournament_id = p_tournament_id
    and user_id = auth.uid();
$$;

revoke all on function public.leave_team(uuid) from public;
grant execute on function public.leave_team(uuid) to authenticated;

-- -----------------------------------------------------------------------------
-- Audit trigger
-- -----------------------------------------------------------------------------
create or replace function public.audit_row_change()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

-- -----------------------------------------------------------------------------
-- Updated-at triggers
-- -----------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'tournaments',
    'tournament_settings',
    'match_rule_sets',
    'teams',
    'groups',
    'fields',
    'knockout_rounds',
    'matches',
    'player_team_assignments',
    'push_subscriptions'
  ] loop
    execute format('drop trigger if exists trg_%I_updated_at on public.%I', t, t);
    execute format(
      'create trigger trg_%I_updated_at before update on public.%I for each row execute function public.set_updated_at()',
      t, t
    );
  end loop;
end $$;

-- Defaults trigger
drop trigger if exists trg_tournaments_defaults on public.tournaments;
create trigger trg_tournaments_defaults
after insert on public.tournaments
for each row execute function public.initialize_tournament_defaults();

-- Audit only domain data; not subscriptions, auth mapping or PIN assignment rows.
do $$
declare
  t text;
begin
  foreach t in array array[
    'tournaments',
    'tournament_settings',
    'match_rule_sets',
    'teams',
    'groups',
    'group_teams',
    'fields',
    'knockout_rounds',
    'matches'
  ] loop
    execute format('drop trigger if exists trg_%I_audit on public.%I', t, t);
    execute format(
      'create trigger trg_%I_audit after insert or update or delete on public.%I for each row execute function public.audit_row_change()',
      t, t
    );
  end loop;
end $$;

-- -----------------------------------------------------------------------------
-- Standings base view
-- Head-to-head and final draw ordering will be applied by the tournament engine.
-- This view gives the deterministic base statistics.
-- -----------------------------------------------------------------------------
create or replace view public.group_standings_base
with (security_invoker = true)
as
with team_match_rows as (
  select
    m.tournament_id,
    m.group_id,
    m.team1_id as team_id,
    m.score_team1 as goals_for,
    m.score_team2 as goals_against,
    case
      when m.score_team1 > m.score_team2 then 3
      when m.score_team1 = m.score_team2 then 1
      else 0
    end as points,
    case when m.score_team1 > m.score_team2 then 1 else 0 end as wins,
    case when m.score_team1 = m.score_team2 then 1 else 0 end as draws,
    case when m.score_team1 < m.score_team2 then 1 else 0 end as losses
  from public.matches m
  where m.stage = 'group'
    and m.status in ('finished', 'forfeit')
    and m.score_team1 is not null
    and m.score_team2 is not null
    and m.team1_id is not null

  union all

  select
    m.tournament_id,
    m.group_id,
    m.team2_id as team_id,
    m.score_team2 as goals_for,
    m.score_team1 as goals_against,
    case
      when m.score_team2 > m.score_team1 then 3
      when m.score_team2 = m.score_team1 then 1
      else 0
    end as points,
    case when m.score_team2 > m.score_team1 then 1 else 0 end as wins,
    case when m.score_team2 = m.score_team1 then 1 else 0 end as draws,
    case when m.score_team2 < m.score_team1 then 1 else 0 end as losses
  from public.matches m
  where m.stage = 'group'
    and m.status in ('finished', 'forfeit')
    and m.score_team1 is not null
    and m.score_team2 is not null
    and m.team2_id is not null
),
aggregated as (
  select
    tournament_id,
    group_id,
    team_id,
    count(*)::integer as played,
    sum(wins)::integer as wins,
    sum(draws)::integer as draws,
    sum(losses)::integer as losses,
    sum(goals_for)::integer as goals_for,
    sum(goals_against)::integer as goals_against,
    sum(goals_for - goals_against)::integer as goal_difference,
    sum(points)::integer as points
  from team_match_rows
  group by tournament_id, group_id, team_id
)
select
  gt.tournament_id,
  gt.group_id,
  gt.team_id,
  tm.name as team_name,
  coalesce(a.played, 0) as played,
  coalesce(a.wins, 0) as wins,
  coalesce(a.draws, 0) as draws,
  coalesce(a.losses, 0) as losses,
  coalesce(a.goals_for, 0) as goals_for,
  coalesce(a.goals_against, 0) as goals_against,
  coalesce(a.goal_difference, 0) as goal_difference,
  coalesce(a.points, 0) as points,
  gt.lot_order
from public.group_teams gt
join public.teams tm on tm.id = gt.team_id
left join aggregated a
  on a.tournament_id = gt.tournament_id
 and a.group_id = gt.group_id
 and a.team_id = gt.team_id;

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.admin_users enable row level security;
alter table public.tournaments enable row level security;
alter table public.tournament_settings enable row level security;
alter table public.match_rule_sets enable row level security;
alter table public.teams enable row level security;
alter table public.groups enable row level security;
alter table public.group_teams enable row level security;
alter table public.fields enable row level security;
alter table public.knockout_rounds enable row level security;
alter table public.matches enable row level security;
alter table public.player_team_assignments enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.match_events enable row level security;
alter table public.audit_log enable row level security;

-- Start from least privilege.
revoke all on table public.admin_users from anon, authenticated;
revoke all on table public.tournaments from anon, authenticated;
revoke all on table public.tournament_settings from anon, authenticated;
revoke all on table public.match_rule_sets from anon, authenticated;
revoke all on table public.teams from anon, authenticated;
revoke all on table public.groups from anon, authenticated;
revoke all on table public.group_teams from anon, authenticated;
revoke all on table public.fields from anon, authenticated;
revoke all on table public.knockout_rounds from anon, authenticated;
revoke all on table public.matches from anon, authenticated;
revoke all on table public.player_team_assignments from anon, authenticated;
revoke all on table public.push_subscriptions from anon, authenticated;
revoke all on table public.match_events from anon, authenticated;
revoke all on table public.audit_log from anon, authenticated;

-- Public tournament data is readable after an invisible anonymous sign-in.
grant select on table public.tournaments to authenticated;
grant select on table public.tournament_settings to authenticated;
grant select on table public.match_rule_sets to authenticated;
grant select on table public.teams to authenticated;
grant select on table public.groups to authenticated;
grant select on table public.group_teams to authenticated;
grant select on table public.fields to authenticated;
grant select on table public.knockout_rounds to authenticated;
grant select on table public.matches to authenticated;
grant select on table public.group_standings_base to authenticated;

-- Admin uses the same authenticated role but RLS grants full domain writes only to admin.
grant insert, update, delete on table public.tournaments to authenticated;
grant insert, update, delete on table public.tournament_settings to authenticated;
grant insert, update, delete on table public.match_rule_sets to authenticated;
grant insert, update, delete on table public.teams to authenticated;
grant insert, update, delete on table public.groups to authenticated;
grant insert, update, delete on table public.group_teams to authenticated;
grant insert, update, delete on table public.fields to authenticated;
grant insert, update, delete on table public.knockout_rounds to authenticated;
grant insert, update, delete on table public.matches to authenticated;

-- Player assignment is readable only by that device. Writes go through claim_team().
grant select on table public.player_team_assignments to authenticated;

-- Push subscriptions are owned by the current user/device.
grant select, insert, update, delete on table public.push_subscriptions to authenticated;

-- Match events and audit are admin-readable for now. Match engine functions will write events.
grant select, insert on table public.match_events to authenticated;
grant select on table public.audit_log to authenticated;

grant usage, select on sequence public.match_events_id_seq to authenticated;
grant usage, select on sequence public.audit_log_id_seq to authenticated;

-- Tournaments
create policy tournaments_select
on public.tournaments for select to authenticated
using (status in ('active', 'completed', 'archived') or public.is_admin());

create policy tournaments_admin_insert
on public.tournaments for insert to authenticated
with check (public.is_admin());

create policy tournaments_admin_update
on public.tournaments for update to authenticated
using (public.is_admin()) with check (public.is_admin());

create policy tournaments_admin_delete
on public.tournaments for delete to authenticated
using (public.is_admin());

-- Helper macro-like block for tournament-scoped tables.
do $$
declare
  t text;
begin
  foreach t in array array[
    'tournament_settings',
    'match_rule_sets',
    'teams',
    'groups',
    'group_teams',
    'fields',
    'knockout_rounds',
    'matches'
  ] loop
    execute format(
      'create policy %I on public.%I for select to authenticated using (public.can_view_tournament(tournament_id))',
      t || '_select', t
    );
    execute format(
      'create policy %I on public.%I for insert to authenticated with check (public.is_admin())',
      t || '_admin_insert', t
    );
    execute format(
      'create policy %I on public.%I for update to authenticated using (public.is_admin()) with check (public.is_admin())',
      t || '_admin_update', t
    );
    execute format(
      'create policy %I on public.%I for delete to authenticated using (public.is_admin())',
      t || '_admin_delete', t
    );
  end loop;
end $$;

-- Player/team assignment
create policy player_assignment_select_own_or_admin
on public.player_team_assignments for select to authenticated
using (user_id = auth.uid() or public.is_admin());

-- Push subscriptions
create policy push_subscriptions_select_own_or_admin
on public.push_subscriptions for select to authenticated
using (user_id = auth.uid() or public.is_admin());

create policy push_subscriptions_insert_own
on public.push_subscriptions for insert to authenticated
with check (user_id = auth.uid());

create policy push_subscriptions_update_own
on public.push_subscriptions for update to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

create policy push_subscriptions_delete_own
on public.push_subscriptions for delete to authenticated
using (user_id = auth.uid() or public.is_admin());

-- Match events: clients may read tournament-visible events; direct writes admin-only for now.
create policy match_events_select
on public.match_events for select to authenticated
using (public.can_view_tournament(tournament_id));

create policy match_events_admin_insert
on public.match_events for insert to authenticated
with check (public.is_admin());

-- Audit log is admin-only.
create policy audit_log_admin_select
on public.audit_log for select to authenticated
using (public.is_admin());

commit;
