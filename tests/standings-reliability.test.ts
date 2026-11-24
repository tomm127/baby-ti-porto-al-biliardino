import test from 'node:test';
import assert from 'node:assert/strict';
import { rankSnapshotGroup, type GroupRankingSnapshot } from '../src/domain/snapshotStandings.ts';
import { qualifyFromGroups } from '../src/domain/standings.ts';
import type { StandingRow } from '../src/domain/types.ts';

const row = (id: string, points: number, lot: number, group = 'G') => ({
  group_id: group, team_id: id, team_name: id, played: 3,
  wins: 1, draws: 0, losses: 2, goals_for: 4, goals_against: 4,
  goal_difference: 0, points, lot_order: lot,
});
const match = (a: string, b: string, s1: number, s2: number, status = 'finished', stage = 'group', group = 'G') => ({
  id: [a,b,status,stage,group].join(':'), group_id: group, stage, status,
  team1_id: a, team2_id: b, score_team1: s1, score_team2: s2,
});
const snapshot = (standings: GroupRankingSnapshot['standings'], matches: GroupRankingSnapshot['matches'] = [], withdrawn: string[] = []): GroupRankingSnapshot => ({
  standings, matches, teams: standings.map(r => ({ id: r.team_id, status: withdrawn.includes(r.team_id) ? 'withdrawn' : 'active' })),
});
const ids = (b: GroupRankingSnapshot) => rankSnapshotGroup(b, 'G').map(r => r.teamId);

test('withdrawn leader is excluded; historical base statistics are preserved', () => {
  const b = snapshot([row('A', 3, 2), row('B', 6, 1), row('W', 9, 0)], [match('A','W',4,0)], ['W']);
  const result = rankSnapshotGroup(b,'G');
  assert.deepEqual(result.map(r => r.teamId), ['B','A']);
  assert.equal(result[1].points, 3);
  assert.equal(result[1].played, 3);
  assert.equal(result[1].goalsFor, 4);
});
test('two-way tie uses head-to-head before lot order', () => {
  assert.deepEqual(ids(snapshot([row('A',3,2),row('B',3,1)], [match('A','B',1,0)])), ['A','B']);
});
test('three-way tie uses mini-table goal difference', () => {
  const b = snapshot([row('A',3,3),row('B',3,1),row('C',3,2)], [match('A','B',4,0),match('B','C',2,0),match('C','A',1,0)]);
  assert.deepEqual(ids(b), ['A','C','B']);
});
test('withdrawn teams do not enter the head-to-head mini-table', () => {
  const b = snapshot([row('A',3,2),row('B',3,1),row('W',3,0)], [match('A','W',10,0),match('B','W',0,1),match('A','B',0,0)], ['W']);
  assert.deepEqual(ids(b), ['B','A']);
});
test('cancelled, other-stage and other-group matches cannot affect the ranking', () => {
  const b = snapshot([row('A',3,2),row('B',3,1),row('X',9,0,'H')], [match('A','B',9,0,'cancelled'),match('A','B',9,0,'finished','final'),match('A','B',9,0,'finished','group','H')]);
  assert.deepEqual(ids(b), ['B','A']);
});
test('forfeit counts in head-to-head and input snapshot is not mutated', () => {
  const b = snapshot([row('A',3,2),row('B',3,1)], [match('A','B',2,0,'forfeit')]);
  const before = structuredClone(b);
  assert.deepEqual(ids(b), ['A','B']);
  assert.deepEqual(b,before);
});
test('global seeding puts zero games after played games even with negative goal difference', () => {
  const b = snapshot([{...row('A',0,2),played:1,goals_for:0,goals_against:2,goal_difference:-2}, {...row('B',0,1,'H'),played:0,goals_for:0,goals_against:0}]);
  const groups = new Map<string,StandingRow[]>([['G',rankSnapshotGroup(b,'G')],['H',rankSnapshotGroup(b,'H')]]);
  assert.deepEqual(qualifyFromGroups(groups,1).map(r=>r.teamId),['A','B']);
});
