-- Baby ti porto al biliardino
-- Migration 010: explicit tournament start + full match reset
-- Apply AFTER 009_unassigned_teams_group_editor.sql

begin;

-- Starting is now an explicit transition from DRAFT only.
-- This is the only action that converts scheduled group matches into the live
-- queue and lets engine_fill_free_fields assign matches to active fields.
create or replace function public.admin_start_tournament(p_tournament_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.admin_start_tournament(uuid) from public;
grant execute on function public.admin_start_tournament(uuid) to authenticated;


-- Complete match reset.
-- Tournament structure is preserved, while every match/result/bracket is removed.
-- The frontend immediately regenerates a fresh SCHEDULED group calendar afterwards.
create or replace function public.admin_reset_tournament_matches(p_tournament_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
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
$$;

revoke all on function public.admin_reset_tournament_matches(uuid) from public;
grant execute on function public.admin_reset_tournament_matches(uuid) to authenticated;

commit;
