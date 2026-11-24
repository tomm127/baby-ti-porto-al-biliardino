-- BTPB 022: validate notification eligibility at claim time.
-- Apply after 021. No changes to match data, API signature or job status schema.
-- Invalid jobs remain in the outbox and are not claimed while ineligible.
-- Does not recall notifications already claimed or delivered.
BEGIN;

CREATE OR REPLACE FUNCTION public.claim_push_jobs(p_limit integer DEFAULT 50)
 RETURNS TABLE(id bigint, tournament_id uuid, match_id uuid, user_id uuid, kind text, title text, body text, url text, payload jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'auth'
AS $function$
begin
  if coalesce(auth.jwt() ->> 'role', '') <> 'service_role' then
    raise exception 'Service role required';
  end if;

  return query
  with candidates as (
    select j.id
    from public.notification_jobs j
    join public.tournament_settings s on s.tournament_id=j.tournament_id
    join public.tournaments t on t.id=j.tournament_id
    join public.matches m on m.id=j.match_id and m.tournament_id=j.tournament_id
    where not s.emergency_paused
      and t.status = 'active'
      and m.team1_id is not null and m.team2_id is not null
      and (
        (j.kind = 'called' and m.status in ('called','ready') and m.field_id is not null)
        or (j.kind = 'prepare' and m.status = 'queued' and m.queue_position is not null)
      )
      and exists (
        select 1 from public.player_team_assignments a
        join public.teams tm on tm.id=a.team_id and tm.tournament_id=a.tournament_id
        where a.tournament_id=j.tournament_id and a.user_id=j.user_id
          and a.team_id in (m.team1_id,m.team2_id) and tm.status = 'active'
      )
      and (
        j.status='pending'
        or (j.status='processing' and j.processing_at < now() - interval '90 seconds')
      )
    order by j.created_at
    for update of j skip locked
    limit greatest(1, least(coalesce(p_limit,50),200))
  ), claimed as (
    update public.notification_jobs j
    set status='processing',
        processing_at=now(),
        attempt_count=j.attempt_count+1,
        last_error=null
    from candidates c
    where j.id=c.id
    returning j.*
  )
  select c.id,c.tournament_id,c.match_id,c.user_id,c.kind,
         c.title,c.body,c.url,c.payload
  from claimed c
  order by c.created_at;
end;
$function$;

REVOKE EXECUTE ON FUNCTION public.claim_push_jobs(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.claim_push_jobs(integer) TO service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
