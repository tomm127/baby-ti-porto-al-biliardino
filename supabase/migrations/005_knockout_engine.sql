-- Baby ti porto al biliardino
-- Migration 005: automatic qualification + knockout bracket + winner propagation
-- Apply AFTER 004_push_notifications.sql

begin;

-- -----------------------------------------------------------------------------
-- Persist the qualification snapshot used to seed the knockout bracket.
-- This makes the bracket auditable and easy to display.
-- -----------------------------------------------------------------------------
create table if not exists public.tournament_qualifiers (
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  team_id uuid not null,
  group_id uuid not null,
  group_rank integer not null check (group_rank > 0),
  global_seed integer not null check (global_seed > 0),
  played integer not null,
  points integer not null,
  goal_difference integer not null,
  goals_for integer not null,
  points_per_game numeric not null,
  goal_difference_per_game numeric not null,
  goals_for_per_game numeric not null,
  lot_order double precision not null,
  created_at timestamptz not null default now(),
  primary key (tournament_id, team_id),
  unique (tournament_id, global_seed),
  foreign key (team_id, tournament_id)
    references public.teams(id, tournament_id) on delete cascade,
  foreign key (group_id, tournament_id)
    references public.groups(id, tournament_id) on delete cascade
);

alter table public.tournament_qualifiers enable row level security;
revoke all on table public.tournament_qualifiers from anon, authenticated;
grant select, insert, update, delete on table public.tournament_qualifiers to authenticated;

drop policy if exists tournament_qualifiers_select on public.tournament_qualifiers;
create policy tournament_qualifiers_select
on public.tournament_qualifiers for select to authenticated
using (public.can_view_tournament(tournament_id));

drop policy if exists tournament_qualifiers_admin_insert on public.tournament_qualifiers;
create policy tournament_qualifiers_admin_insert
on public.tournament_qualifiers for insert to authenticated
with check (public.is_admin());

drop policy if exists tournament_qualifiers_admin_update on public.tournament_qualifiers;
create policy tournament_qualifiers_admin_update
on public.tournament_qualifiers for update to authenticated
using (public.is_admin()) with check (public.is_admin());

drop policy if exists tournament_qualifiers_admin_delete on public.tournament_qualifiers;
create policy tournament_qualifiers_admin_delete
on public.tournament_qualifiers for delete to authenticated
using (public.is_admin());

drop trigger if exists trg_tournament_qualifiers_audit on public.tournament_qualifiers;
create trigger trg_tournament_qualifiers_audit
after insert or update or delete on public.tournament_qualifiers
for each row execute function public.audit_row_change();

-- Third-place match is fed by the LOSERS of the two semifinals.
alter table public.matches
  add column if not exists team1_source_loser_match_id uuid,
  add column if not exists team2_source_loser_match_id uuid;

do $$ begin
  alter table public.matches
    add constraint matches_team1_source_loser_fk
    foreign key (team1_source_loser_match_id, tournament_id)
    references public.matches(id, tournament_id) on delete restrict;
exception when duplicate_object then null; end $$;

do $$ begin
  alter table public.matches
    add constraint matches_team2_source_loser_fk
    foreign key (team2_source_loser_match_id, tournament_id)
    references public.matches(id, tournament_id) on delete restrict;
exception when duplicate_object then null; end $$;

-- -----------------------------------------------------------------------------
-- Exact group ranking used for qualification:
-- points -> goal difference -> goals for -> head-to-head mini table -> lot order.
-- -----------------------------------------------------------------------------
create or replace function public.engine_group_ranking(
  p_tournament_id uuid,
  p_group_id uuid
)
returns table (
  team_id uuid,
  team_name text,
  played integer,
  points integer,
  goal_difference integer,
  goals_for integer,
  lot_order double precision,
  group_rank integer
)
language sql
stable
security definer
set search_path = public
as $$
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
$$;

revoke all on function public.engine_group_ranking(uuid, uuid) from public;

-- Standard seeded bracket order.
-- 8 teams -> [1,8,4,5,2,7,3,6], therefore matches are
-- 1v8, 4v5, 2v7, 3v6 and top seeds stay separated correctly.
create or replace function public.engine_seed_order(p_bracket_size integer)
returns integer[]
language plpgsql
immutable
security definer
set search_path = public
as $$
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
$$;

revoke all on function public.engine_seed_order(integer) from public;

create or replace function public.engine_round_name(p_match_count integer)
returns text
language sql
immutable
as $$
  select case p_match_count
    when 1 then 'Finale'
    when 2 then 'Semifinali'
    when 4 then 'Quarti di finale'
    when 8 then 'Ottavi di finale'
    when 16 then 'Sedicesimi di finale'
    else 'Turno da ' || (p_match_count * 2)::text
  end;
$$;

revoke all on function public.engine_round_name(integer) from public;

-- -----------------------------------------------------------------------------
-- True only when every scheduled group match has a valid terminal result.
-- A cancelled group match deliberately blocks automatic qualification.
-- -----------------------------------------------------------------------------
create or replace function public.engine_groups_complete(p_tournament_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
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
$$;

revoke all on function public.engine_groups_complete(uuid) from public;

-- -----------------------------------------------------------------------------
-- Populate downstream winner/loser slots, queue only the EARLIEST unfinished
-- round, and complete the tournament when final (+ optional third place) close.
-- -----------------------------------------------------------------------------
create or replace function public.engine_advance_knockout(p_tournament_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.engine_advance_knockout(uuid) from public;

-- -----------------------------------------------------------------------------
-- Create qualification snapshot + every bracket round. First-round byes are
-- resolved immediately and then propagated by engine_advance_knockout().
-- -----------------------------------------------------------------------------
create or replace function public.engine_create_knockout(p_tournament_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.engine_create_knockout(uuid) from public;

-- Public admin helper for manual recovery/testing. Normal operation is automatic.
create or replace function public.admin_generate_knockout(p_tournament_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  perform public.require_admin();
  return public.engine_create_knockout(p_tournament_id);
end;
$$;
revoke all on function public.admin_generate_knockout(uuid) from public;
grant execute on function public.admin_generate_knockout(uuid) to authenticated;

-- Central hook called after a match gets a terminal winner/result.
create or replace function public.engine_after_match_closed(p_match_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;
revoke all on function public.engine_after_match_closed(uuid) from public;

-- -----------------------------------------------------------------------------
-- Replace result submission so automatic knockout progression is part of the
-- SAME transaction as the result itself.
-- -----------------------------------------------------------------------------
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
$$;
revoke all on function public.submit_match_result(uuid, integer, integer) from public;
grant execute on function public.submit_match_result(uuid, integer, integer) to authenticated;

-- Forfeit is also a terminal result and must advance the bracket.
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
$$;
revoke all on function public.admin_forfeit_match(uuid, uuid) from public;
grant execute on function public.admin_forfeit_match(uuid, uuid) to authenticated;

-- Result correction: safe propagation if downstream has NOT started. If a
-- group correction would alter an already-started bracket, stop instead of
-- silently corrupting later rounds.
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
$$;
revoke all on function public.admin_update_match_result(uuid, integer, integer) from public;
grant execute on function public.admin_update_match_result(uuid, integer, integer) to authenticated;

commit;
