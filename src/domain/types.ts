export type OrderingMode = 'group_sequential' | 'group_rotation';

export interface Team {
  id: string;
  name: string;
  lotOrder?: number;
}

export interface Group {
  id: string;
  name: string;
  sortOrder: number;
  teams: Team[];
}

export interface GroupMatch {
  id: string;
  groupId: string;
  groupSortOrder: number;
  roundNumber: number;
  matchInRound: number;
  sequenceInGroup: number;
  team1Id: string;
  team2Id: string;
}

export interface PlayedMatch {
  id: string;
  groupId: string;
  team1Id: string;
  team2Id: string;
  scoreTeam1: number;
  scoreTeam2: number;
}

export interface StandingRow {
  teamId: string;
  teamName: string;
  played: number;
  wins: number;
  draws: number;
  losses: number;
  goalsFor: number;
  goalsAgainst: number;
  goalDifference: number;
  points: number;
  lotOrder: number;
}

export interface QualifiedTeam extends StandingRow {
  groupId: string;
  groupRank: number;
  pointsPerGame: number;
  goalDifferencePerGame: number;
  goalsForPerGame: number;
}

export interface KnockoutSlot {
  slot: number;
  seed1: number;
  seed2: number;
  team1Id: string | null;
  team2Id: string | null;
  byeTeamId: string | null;
}

export interface QueuedMatch {
  id: string;
  team1Id: string;
  team2Id: string;
  queuePosition: number;
}

export interface Field {
  id: string;
  name: string;
  sortOrder: number;
  occupied: boolean;
}

export interface FieldAssignment {
  fieldId: string;
  matchId: string;
}
