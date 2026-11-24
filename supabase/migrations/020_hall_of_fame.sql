-- BTPB 020: read-only hall of fame from completed knockout tournaments.
-- No additional table access or write privileges; existing RLS remains in force.
BEGIN;
CREATE OR REPLACE FUNCTION public.get_hall_of_fame()
RETURNS TABLE (
  tournament_id uuid, tournament_name text, completed_at timestamptz,
  champion_name text, champion_avatar text,
  runner_up_name text, runner_up_avatar text,
  third_place_name text, third_place_avatar text,
  champion_score integer, runner_up_score integer
)
LANGUAGE sql STABLE SECURITY INVOKER
SET search_path = ''
AS $function$
  SELECT t.id, t.name, t.completed_at,
         w.name, w.avatar_url, r.name, r.avatar_url,
         third.name, third.avatar_url,
         CASE WHEN f.winner_team_id = f.team1_id THEN f.score_team1 ELSE f.score_team2 END,
         CASE WHEN f.winner_team_id = f.team1_id THEN f.score_team2 ELSE f.score_team1 END
  FROM public.tournaments t
  JOIN public.matches f ON f.tournament_id = t.id AND f.stage = 'final'
    AND f.status IN ('finished', 'forfeit')
    AND f.team1_id IS NOT NULL AND f.team2_id IS NOT NULL
    AND f.team1_id <> f.team2_id
    AND f.winner_team_id IN (f.team1_id, f.team2_id)
  JOIN public.teams w ON w.id = f.winner_team_id AND w.tournament_id = t.id
  JOIN public.teams r ON r.id = CASE WHEN f.winner_team_id = f.team1_id THEN f.team2_id ELSE f.team1_id END
    AND r.tournament_id = t.id
  LEFT JOIN LATERAL (
    SELECT p.name, p.avatar_url
    FROM public.matches m
    JOIN public.teams p ON p.id = m.winner_team_id AND p.tournament_id = t.id
    WHERE m.tournament_id = t.id AND m.stage = 'third_place'
      AND m.status IN ('finished', 'forfeit')
      AND m.team1_id IS NOT NULL AND m.team2_id IS NOT NULL
      AND m.team1_id <> m.team2_id AND m.winner_team_id IN (m.team1_id, m.team2_id)
      AND p.id NOT IN (w.id, r.id)
      AND (SELECT count(*) FROM public.matches x WHERE x.tournament_id = t.id AND x.stage = 'third_place') = 1
  ) third ON true
  WHERE t.status IN ('completed', 'archived') AND t.phase = 'completed'
    AND t.completed_at IS NOT NULL
    AND (SELECT count(*) FROM public.matches x WHERE x.tournament_id = t.id AND x.stage = 'final') = 1
  ORDER BY t.completed_at DESC, t.id;
$function$;
REVOKE ALL ON FUNCTION public.get_hall_of_fame() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.get_hall_of_fame() TO authenticated, service_role;
NOTIFY pgrst, 'reload schema';
COMMIT;
