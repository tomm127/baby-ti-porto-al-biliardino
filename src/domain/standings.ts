import type { PlayedMatch, QualifiedTeam, StandingRow, Team } from './types.ts';

function emptyRow(team: Team): StandingRow {
  return {
    teamId: team.id,
    teamName: team.name,
    played: 0,
    wins: 0,
    draws: 0,
    losses: 0,
    goalsFor: 0,
    goalsAgainst: 0,
    goalDifference: 0,
    points: 0,
    lotOrder: team.lotOrder ?? 0,
  };
}

export function calculateStandings(teams: Team[], matches: PlayedMatch[]): StandingRow[] {
  const rows = new Map(teams.map((team) => [team.id, emptyRow(team)]));

  for (const match of matches) {
    const t1 = rows.get(match.team1Id);
    const t2 = rows.get(match.team2Id);
    if (!t1 || !t2) continue;

    t1.played++;
    t2.played++;
    t1.goalsFor += match.scoreTeam1;
    t1.goalsAgainst += match.scoreTeam2;
    t2.goalsFor += match.scoreTeam2;
    t2.goalsAgainst += match.scoreTeam1;

    if (match.scoreTeam1 > match.scoreTeam2) {
      t1.wins++;
      t2.losses++;
      t1.points += 3;
    } else if (match.scoreTeam1 < match.scoreTeam2) {
      t2.wins++;
      t1.losses++;
      t2.points += 3;
    } else {
      t1.draws++;
      t2.draws++;
      t1.points++;
      t2.points++;
    }
  }

  for (const row of rows.values()) {
    row.goalDifference = row.goalsFor - row.goalsAgainst;
  }

  return rankStandings([...rows.values()], matches);
}

function baseCompare(a: StandingRow, b: StandingRow): number {
  return (
    b.points - a.points ||
    b.goalDifference - a.goalDifference ||
    b.goalsFor - a.goalsFor
  );
}

function headToHeadMiniTable(
  tiedRows: StandingRow[],
  matches: PlayedMatch[],
): Map<string, { points: number; gd: number; gf: number }> {
  const tied = new Set(tiedRows.map((row) => row.teamId));
  const mini = new Map<string, { points: number; gd: number; gf: number }>();
  for (const row of tiedRows) mini.set(row.teamId, { points: 0, gd: 0, gf: 0 });

  for (const match of matches) {
    if (!tied.has(match.team1Id) || !tied.has(match.team2Id)) continue;
    const a = mini.get(match.team1Id)!;
    const b = mini.get(match.team2Id)!;
    a.gf += match.scoreTeam1;
    b.gf += match.scoreTeam2;
    a.gd += match.scoreTeam1 - match.scoreTeam2;
    b.gd += match.scoreTeam2 - match.scoreTeam1;
    if (match.scoreTeam1 > match.scoreTeam2) a.points += 3;
    else if (match.scoreTeam1 < match.scoreTeam2) b.points += 3;
    else {
      a.points++;
      b.points++;
    }
  }
  return mini;
}

/**
 * Official order: points -> GD -> GF -> head-to-head -> pre-generated lot order.
 * For a 3+ team tie, "head-to-head" is interpreted as a mini-table among the tied teams.
 */
export function rankStandings(rows: StandingRow[], matches: PlayedMatch[]): StandingRow[] {
  const baseSorted = [...rows].sort(baseCompare);
  const result: StandingRow[] = [];

  for (let i = 0; i < baseSorted.length; ) {
    let j = i + 1;
    while (
      j < baseSorted.length &&
      baseSorted[j].points === baseSorted[i].points &&
      baseSorted[j].goalDifference === baseSorted[i].goalDifference &&
      baseSorted[j].goalsFor === baseSorted[i].goalsFor
    ) {
      j++;
    }

    const tied = baseSorted.slice(i, j);
    if (tied.length === 1) {
      result.push(tied[0]);
    } else {
      const mini = headToHeadMiniTable(tied, matches);
      tied.sort((a, b) => {
        const ma = mini.get(a.teamId)!;
        const mb = mini.get(b.teamId)!;
        return (
          mb.points - ma.points ||
          mb.gd - ma.gd ||
          mb.gf - ma.gf ||
          a.lotOrder - b.lotOrder
        );
      });
      result.push(...tied);
    }

    i = j;
  }

  return result;
}

export function qualifyFromGroups(
  standingsByGroup: Map<string, StandingRow[]>,
  qualifiersPerGroup: number,
): QualifiedTeam[] {
  const qualifiers: QualifiedTeam[] = [];

  for (const [groupId, standings] of standingsByGroup.entries()) {
    standings.slice(0, qualifiersPerGroup).forEach((row, index) => {
      qualifiers.push({
        ...row,
        groupId,
        groupRank: index + 1,
        pointsPerGame: row.played === 0 ? 0 : row.points / row.played,
        goalDifferencePerGame: row.played === 0 ? 0 : row.goalDifference / row.played,
        goalsForPerGame: row.played === 0 ? 0 : row.goalsFor / row.played,
      });
    });
  }

  return qualifiers.sort((a, b) =>
    b.pointsPerGame - a.pointsPerGame ||
    b.goalDifferencePerGame - a.goalDifferencePerGame ||
    b.goalsForPerGame - a.goalsForPerGame ||
    a.lotOrder - b.lotOrder,
  );
}
