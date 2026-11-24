-- Migration 019: preserve deliberate group/main bracket cancellation rules;
-- complete optional third-place cancellation and remove obsolete pending pushes.
-- Apply after 018, outside an active tournament.
BEGIN;

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

  -- Drop queued notifications for a match that will no longer be played.
  delete from public.notification_jobs
  where match_id = p_match_id and status = 'pending';

  -- Group and main-bracket cancellations still require an explicit result.
  -- Third place is optional: a cancellation can complete the tournament
  -- when the main final has already been decided.
  if v_match.stage = 'third_place'
    and exists (select 1 from public.tournaments
      where id = v_match.tournament_id and status = 'active' and phase = 'knockout')
    and exists (select 1 from public.matches
      where tournament_id = v_match.tournament_id and stage = 'final'
        and status in ('finished', 'forfeit'))
  then
    perform public.engine_advance_knockout(v_match.tournament_id);
  end if;

  perform public.engine_fill_free_fields(v_match.tournament_id);
  return v_match;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.admin_cancel_match(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_cancel_match(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
COMMIT;
