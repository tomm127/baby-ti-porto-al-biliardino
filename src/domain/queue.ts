import type { Field, FieldAssignment, Group, GroupMatch, OrderingMode, QueuedMatch } from './types.ts';

export function buildGroupQueue(
  groups: Group[],
  schedules: Map<string, GroupMatch[]>,
  mode: OrderingMode,
): GroupMatch[] {
  const orderedGroups = [...groups].sort((a, b) => a.sortOrder - b.sortOrder);

  if (mode === 'group_sequential') {
    return orderedGroups.flatMap((group) => schedules.get(group.id) ?? []);
  }

  // Strict A1, B1, C1, ..., A2, B2, C2 ... rotation.
  const queues = orderedGroups.map((group) => schedules.get(group.id) ?? []);
  const positions = new Array(queues.length).fill(0);
  const result: GroupMatch[] = [];

  while (true) {
    let added = false;
    for (let i = 0; i < queues.length; i++) {
      const match = queues[i][positions[i]];
      if (!match) continue;
      result.push(match);
      positions[i]++;
      added = true;
    }
    if (!added) break;
  }

  return result;
}

/** Assign strictly from queue head to free fields; never reorders for rest/fairness. */
export function assignNextMatchesToFields(
  queue: QueuedMatch[],
  fields: Field[],
): FieldAssignment[] {
  const orderedQueue = [...queue].sort((a, b) => a.queuePosition - b.queuePosition);
  const freeFields = fields
    .filter((field) => !field.occupied)
    .sort((a, b) => a.sortOrder - b.sortOrder);

  return freeFields.slice(0, orderedQueue.length).map((field, index) => ({
    fieldId: field.id,
    matchId: orderedQueue[index].id,
  }));
}

/** Number of queued matches before the team's next match. Returns null if no future group match exists. */
export function matchesAheadForTeam(queue: QueuedMatch[], teamId: string): number | null {
  const orderedQueue = [...queue].sort((a, b) => a.queuePosition - b.queuePosition);
  const index = orderedQueue.findIndex(
    (match) => match.team1Id === teamId || match.team2Id === teamId,
  );
  return index === -1 ? null : index;
}
