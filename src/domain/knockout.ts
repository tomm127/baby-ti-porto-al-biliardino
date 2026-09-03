import type { KnockoutSlot, QualifiedTeam } from './types.ts';

export function nextPowerOfTwo(n: number): number {
  if (n <= 1) return 1;
  return 2 ** Math.ceil(Math.log2(n));
}

/**
 * Standard seed placement keeps the strongest seeds separated.
 * 8 teams -> [1,8,4,5,2,7,3,6]
 * therefore first-round pairings are 1v8, 4v5, 2v7, 3v6.
 */
export function seedOrder(bracketSize: number): number[] {
  if (bracketSize < 2 || (bracketSize & (bracketSize - 1)) !== 0) {
    throw new Error('bracketSize must be a power of two >= 2');
  }
  let order = [1, 2];
  let size = 2;
  while (size < bracketSize) {
    size *= 2;
    order = order.flatMap((seed) => [seed, size + 1 - seed]);
  }
  return order;
}

/**
 * First knockout round follows the requested global seeding rule while keeping
 * top seeds separated in later rounds. Missing seeds become byes.
 * Example: 12 qualifiers -> 16-slot bracket -> seeds 1-4 receive byes.
 */
export function createFirstKnockoutRound(rankedQualifiers: QualifiedTeam[]): KnockoutSlot[] {
  const n = rankedQualifiers.length;
  if (n < 2) return [];

  const bracketSize = nextPowerOfTwo(n);
  const seeds = new Map<number, string>();
  rankedQualifiers.forEach((team, index) => seeds.set(index + 1, team.teamId));
  const order = seedOrder(bracketSize);

  const slots: KnockoutSlot[] = [];
  for (let index = 0; index < order.length; index += 2) {
    const seed1 = order[index];
    const seed2 = order[index + 1];
    const team1Id = seeds.get(seed1) ?? null;
    const team2Id = seeds.get(seed2) ?? null;
    const byeTeamId = team1Id && !team2Id ? team1Id : team2Id && !team1Id ? team2Id : null;

    slots.push({
      slot: (index / 2) + 1,
      seed1,
      seed2,
      team1Id,
      team2Id,
      byeTeamId,
    });
  }

  return slots;
}
