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

/**
 * Mirror migration 011: choose the first eligible match for each free field.
 * Supply teams from all called/ready/playing/awaiting_result matches as busyTeamIds.
 * Fields must be active; skipped matches keep their original queue positions.
 */
export function assignNextMatchesToFields(
  queue: QueuedMatch[],
  fields: Field[],
  busyTeamIds: Iterable<string> = [],
): FieldAssignment[] {
  const orderedQueue = [...queue].sort((a, b) => a.queuePosition - b.queuePosition);
  const freeFields = fields
    .filter((field) => !field.occupied)
    .sort((a, b) => a.sortOrder - b.sortOrder);
  const busy = new Set(busyTeamIds);
  const assigned = new Set<string>();
  const result: FieldAssignment[] = [];

  for (const field of freeFields) {
    const match = orderedQueue.find((m) =>
      !assigned.has(m.id) && !busy.has(m.team1Id) && !busy.has(m.team2Id)
    );
    if (!match) break;
    result.push({ fieldId: field.id, matchId: match.id });
    assigned.add(match.id);
    busy.add(match.team1Id);
    busy.add(match.team2Id);
  }
  return result;
}

/** Number of queued matches before the team's next match. Returns null if no future group match exists. */
export function matchesAheadForTeam(queue: QueuedMatch[], teamId: string): number | null {
  const orderedQueue = [...queue].sort((a, b) => a.queuePosition - b.queuePosition);
  const index = orderedQueue.findIndex(
    (match) => match.team1Id === teamId || match.team2Id === teamId,
  );
  return index === -1 ? null : index;
}
