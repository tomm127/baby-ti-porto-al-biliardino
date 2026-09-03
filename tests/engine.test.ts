import test from 'node:test';
import assert from 'node:assert/strict';
import {
  assignNextMatchesToFields,
  buildGroupQueue,
  calculateStandings,
  createFirstKnockoutRound,
  seedOrder,
  generateAllGroupMatches,
  generateRoundRobinForGroup,
  matchesAheadForTeam,
  qualifyFromGroups,
  type Group,
  type PlayedMatch,
  type QualifiedTeam,
} from '../src/domain/index.ts';

const team = (id: string, lotOrder = 0) => ({ id, name: id, lotOrder });

test('round robin with 4 teams creates 6 unique matches', () => {
  const group: Group = { id: 'A', name: 'A', sortOrder: 1, teams: ['A1','A2','A3','A4'].map(team) };
  const matches = generateRoundRobinForGroup(group);
  assert.equal(matches.length, 6);
  const pairs = new Set(matches.map((m) => [m.team1Id, m.team2Id].sort().join('-')));
  assert.equal(pairs.size, 6);
});

test('round robin with 5 teams creates 10 unique matches', () => {
  const group: Group = { id: 'A', name: 'A', sortOrder: 1, teams: ['A1','A2','A3','A4','A5'].map(team) };
  const matches = generateRoundRobinForGroup(group);
  assert.equal(matches.length, 10);
  const pairs = new Set(matches.map((m) => [m.team1Id, m.team2Id].sort().join('-')));
  assert.equal(pairs.size, 10);
});

test('group rotation is A1 B1 C1 A2 B2 C2...', () => {
  const groups: Group[] = [
    { id: 'A', name: 'A', sortOrder: 1, teams: ['A1','A2','A3','A4'].map(team) },
    { id: 'B', name: 'B', sortOrder: 2, teams: ['B1','B2','B3','B4'].map(team) },
    { id: 'C', name: 'C', sortOrder: 3, teams: ['C1','C2','C3','C4'].map(team) },
  ];
  const schedules = generateAllGroupMatches(groups);
  const queue = buildGroupQueue(groups, schedules, 'group_rotation');
  assert.deepEqual(queue.slice(0, 6).map((m) => m.groupId), ['A','B','C','A','B','C']);
});

test('sequential mode finishes A before B', () => {
  const groups: Group[] = [
    { id: 'A', name: 'A', sortOrder: 1, teams: ['A1','A2','A3'].map(team) },
    { id: 'B', name: 'B', sortOrder: 2, teams: ['B1','B2','B3'].map(team) },
  ];
  const schedules = generateAllGroupMatches(groups);
  const queue = buildGroupQueue(groups, schedules, 'group_sequential');
  assert.deepEqual(queue.map((m) => m.groupId), ['A','A','A','B','B','B']);
});

test('standings score 3/1/0 and use goal difference', () => {
  const teams = [team('A', .1), team('B', .2), team('C', .3)];
  const matches: PlayedMatch[] = [
    { id:'1', groupId:'G', team1Id:'A', team2Id:'B', scoreTeam1:5, scoreTeam2:2 },
    { id:'2', groupId:'G', team1Id:'A', team2Id:'C', scoreTeam1:3, scoreTeam2:3 },
    { id:'3', groupId:'G', team1Id:'B', team2Id:'C', scoreTeam1:2, scoreTeam2:1 },
  ];
  const standings = calculateStandings(teams, matches);
  assert.equal(standings[0].teamId, 'A');
  assert.equal(standings[0].points, 4);
  assert.equal(standings[0].goalDifference, 3);
});

test('global qualification normalizes unequal group sizes by games played', () => {
  const groupA = calculateStandings(
    [team('A1', .1), team('A2', .2)],
    [{ id:'a', groupId:'A', team1Id:'A1', team2Id:'A2', scoreTeam1:5, scoreTeam2:0 }],
  );
  const groupB = calculateStandings(
    [team('B1', .3), team('B2', .4), team('B3', .5)],
    [
      { id:'b1', groupId:'B', team1Id:'B1', team2Id:'B2', scoreTeam1:2, scoreTeam2:0 },
      { id:'b2', groupId:'B', team1Id:'B1', team2Id:'B3', scoreTeam1:2, scoreTeam2:0 },
      { id:'b3', groupId:'B', team1Id:'B2', team2Id:'B3', scoreTeam1:1, scoreTeam2:0 },
    ],
  );
  const ranked = qualifyFromGroups(new Map([['A', groupA], ['B', groupB]]), 1);
  assert.equal(ranked[0].teamId, 'A1'); // 3 PPG, much better GD/game than B1
  assert.equal(ranked[1].teamId, 'B1');
});

test('seed order separates the strongest teams', () => {
  assert.deepEqual(seedOrder(8), [1,8,4,5,2,7,3,6]);
});

test('12 qualifiers in a 16-slot bracket give top 4 seeds a bye', () => {
  const qualifiers: QualifiedTeam[] = Array.from({ length: 12 }, (_, i) => ({
    teamId: `T${i + 1}`, teamName:`T${i+1}`, groupId:'G', groupRank:1,
    played:1,wins:1,draws:0,losses:0,goalsFor:1,goalsAgainst:0,goalDifference:1,points:3,
    lotOrder:i, pointsPerGame:3, goalDifferencePerGame:1, goalsForPerGame:1,
  }));
  const slots = createFirstKnockoutRound(qualifiers);
  assert.equal(slots.length, 8);
  assert.deepEqual(slots.filter((s) => s.byeTeamId).map((s) => s.byeTeamId).sort(), ['T1','T2','T3','T4'].sort());
  const realPairings = slots.filter((s) => !s.byeTeamId).map((s) => [s.seed1,s.seed2]);
  assert.deepEqual(realPairings, [[8,9],[5,12],[7,10],[6,11]]);
});

test('field assignment never skips the queue', () => {
  const queue = [
    { id:'M1', team1Id:'A', team2Id:'B', queuePosition:1 },
    { id:'M2', team1Id:'C', team2Id:'D', queuePosition:2 },
    { id:'M3', team1Id:'E', team2Id:'F', queuePosition:3 },
  ];
  const fields = [
    { id:'F2', name:'Campo 2', sortOrder:2, occupied:false },
    { id:'F1', name:'Campo 1', sortOrder:1, occupied:true },
    { id:'F3', name:'Campo 3', sortOrder:3, occupied:false },
  ];
  assert.deepEqual(assignNextMatchesToFields(queue, fields), [
    { fieldId:'F2', matchId:'M1' },
    { fieldId:'F3', matchId:'M2' },
  ]);
  assert.equal(matchesAheadForTeam(queue, 'E'), 2);
});
