import { rankStandings } from './standings.ts';
import type { PlayedMatch, StandingRow } from './types.ts';

// Structural subset of TournamentBundle, independent of Supabase and React.
export interface GroupRankingSnapshot {
  teams: readonly { id: string; status: string }[];
  standings: readonly {
    group_id: string; team_id: string; team_name: string; played: number;
    wins: number; draws: number; losses: number; goals_for: number;
    goals_against: number; goal_difference: number; points: number; lot_order: number;
  }[];
  matches: readonly {
    id: string; group_id: string | null; stage: string; status: string;
    team1_id: string | null; team2_id: string | null;
    score_team1: number | null; score_team2: number | null;
  }[];
}

/** Mirror engine_group_ranking: keep database base totals, rank active teams only. */
export function rankSnapshotGroup(bundle: GroupRankingSnapshot, groupId: string): StandingRow[] {
  const active = new Set(bundle.teams.filter(t => t.status === 'active').map(t => t.id));
  const rows: StandingRow[] = bundle.standings
    .filter(r => r.group_id === groupId && active.has(r.team_id))
    .map(r => ({
      teamId: r.team_id, teamName: r.team_name, played: r.played,
      wins: r.wins, draws: r.draws, losses: r.losses, goalsFor: r.goals_for,
      goalsAgainst: r.goals_against, goalDifference: r.goal_difference,
      points: r.points, lotOrder: r.lot_order,
    }));
  const played: PlayedMatch[] = [];
  for (const m of bundle.matches) {
    if (m.group_id !== groupId || m.stage !== 'group' ||
        (m.status !== 'finished' && m.status !== 'forfeit') ||
        m.team1_id === null || m.team2_id === null ||
        m.score_team1 === null || m.score_team2 === null) continue;
    played.push({ id: m.id, groupId, team1Id: m.team1_id, team2Id: m.team2_id,
      scoreTeam1: m.score_team1, scoreTeam2: m.score_team2 });
  }
  return rankStandings(rows, played);
}
