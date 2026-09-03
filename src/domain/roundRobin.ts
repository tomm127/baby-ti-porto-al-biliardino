import type { Group, GroupMatch, Team } from './types.ts';

/**
 * Circle-method single round robin.
 * Each pair meets exactly once. For odd team counts, one team has a bye each round.
 */
export function generateRoundRobinForGroup(group: Group): GroupMatch[] {
  if (group.teams.length < 2) return [];

  const participants: Array<Team | null> = [...group.teams];
  if (participants.length % 2 === 1) participants.push(null);

  const n = participants.length;
  const rounds = n - 1;
  const half = n / 2;
  let rotation = [...participants];
  const matches: GroupMatch[] = [];
  let sequenceInGroup = 1;

  for (let round = 1; round <= rounds; round++) {
    let matchInRound = 1;

    for (let i = 0; i < half; i++) {
      const left = rotation[i];
      const right = rotation[n - 1 - i];
      if (!left || !right) continue;

      // Alternate orientation to avoid making one team team1 every round.
      const swap = round % 2 === 0 && i === 0;
      const team1 = swap ? right : left;
      const team2 = swap ? left : right;

      matches.push({
        id: `${group.id}:r${round}:m${matchInRound}`,
        groupId: group.id,
        groupSortOrder: group.sortOrder,
        roundNumber: round,
        matchInRound,
        sequenceInGroup,
        team1Id: team1.id,
        team2Id: team2.id,
      });

      sequenceInGroup++;
      matchInRound++;
    }

    // Keep first participant fixed; rotate all others clockwise.
    rotation = [rotation[0], rotation[n - 1], ...rotation.slice(1, n - 1)];
  }

  return matches;
}

export function generateAllGroupMatches(groups: Group[]): Map<string, GroupMatch[]> {
  const result = new Map<string, GroupMatch[]>();
  for (const group of [...groups].sort((a, b) => a.sortOrder - b.sortOrder)) {
    result.set(group.id, generateRoundRobinForGroup(group));
  }
  return result;
}
