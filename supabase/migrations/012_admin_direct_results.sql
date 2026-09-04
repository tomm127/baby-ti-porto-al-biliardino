-- BTPB
-- Migration 012: admin direct result entry from any match state
-- Apply AFTER 011_team_field_exclusivity.sql.

begin;

create or replace function public.admin_set_match_result(
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
  v_phase public.tournament_phase;
begin
  perform public.require_admin();

  if p_score_team1 < 0 or p_score_team2 < 0 then
    raise exception 'Scores cannot be negative';
  end if;

  select *
    into v_match
  from public.matches
  where id = p_match_id
  for update;

  if not found then
    raise exception 'Partita non trovata';
  end if;

  if v_match.team1_id is null or v_match.team2_id is null then
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
$$;

revoke all on function public.admin_set_match_result(uuid, integer, integer) from public;
grant execute on function public.admin_set_match_result(uuid, integer, integer) to authenticated;

commit;
