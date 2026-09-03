-- Baby ti porto al biliardino
-- Migration 007: compact tournament snapshots + server clock synchronization
-- Apply AFTER 006_admin_control_room.sql

begin;

-- One compact read replaces many separate table requests. This matters when
-- many player devices refresh at the same time.
create or replace function public.get_tournament_snapshot(p_slug text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
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
    and (t.status in ('active', 'completed', 'archived') or public.is_admin())
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
               s.team_pin_enabled
        from public.tournament_settings s
        where s.tournament_id = v_tournament_id
      ) x
    ),
    'teams', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.name)
      from (
        select tm.id, tm.tournament_id, tm.name, tm.status
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
$$;

revoke all on function public.get_tournament_snapshot(text) from public;
grant execute on function public.get_tournament_snapshot(text) to authenticated;

-- Admin/internal variant by tournament id. Same compact payload, but only admin
-- can use it for draft tournaments.
create or replace function public.get_tournament_snapshot_by_id(p_tournament_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_slug text;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select t.slug into v_slug
  from public.tournaments t
  where t.id = p_tournament_id
    and (t.status in ('active', 'completed', 'archived') or public.is_admin())
  limit 1;

  if v_slug is null then
    raise exception 'Tournament not found or not visible';
  end if;

  return public.get_tournament_snapshot(v_slug);
end;
$$;

revoke all on function public.get_tournament_snapshot_by_id(uuid) from public;
grant execute on function public.get_tournament_snapshot_by_id(uuid) to authenticated;

commit;
