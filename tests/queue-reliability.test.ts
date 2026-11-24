import test from 'node:test';
import assert from 'node:assert/strict';
import { assignNextMatchesToFields, buildGroupQueue } from '../src/domain/queue.ts';
import { generateAllGroupMatches } from '../src/domain/roundRobin.ts';
import type { Field, Group, QueuedMatch } from '../src/domain/types.ts';

const m = (id: string, a: string, b: string, position: number): QueuedMatch =>
  ({ id, team1Id: a, team2Id: b, queuePosition: position });
const f = (id: string, order: number, occupied = false): Field =>
  ({ id, name: id, sortOrder: order, occupied });

test('busy team at queue head is skipped, not removed or reordered', () => {
  const queue = [m('M2','C','D',2), m('M1','A','B',1)];
  const original = structuredClone(queue);
  const busy = new Set(['A']);
  assert.deepEqual(assignNextMatchesToFields(queue,[f('F1',1)],busy), [{fieldId:'F1',matchId:'M2'}]);
  assert.deepEqual(queue, original);
  assert.deepEqual([...busy], ['A']);
  assert.deepEqual(assignNextMatchesToFields(queue,[f('F1',1)]), [{fieldId:'F1',matchId:'M1'}]);
});

test('multiple free fields cannot allocate the same team twice, in either team position', () => {
  const queue = [m('M1','A','B',1),m('M2','C','A',2),m('M3','B','D',3),m('M4','E','F',4)];
  assert.deepEqual(assignNextMatchesToFields(queue,[f('F2',2),f('F1',1),f('F3',3)]), [
    {fieldId:'F1',matchId:'M1'}, {fieldId:'F2',matchId:'M4'},
  ]);
});

test('occupied fields are ignored and busy teams on existing matches are excluded', () => {
  const queue = [m('M1','A','B',1),m('M2','C','D',2),m('M3','E','F',3)];
  const fields = [f('F3',3),f('F1',1,true),f('F2',2)];
  assert.deepEqual(assignNextMatchesToFields(queue,fields,['B','D']), [{fieldId:'F2',matchId:'M3'}]);
});

test('all queued matches blocked: fields stay free', () => {
  assert.deepEqual(assignNextMatchesToFields([m('M1','A','B',1),m('M2','C','A',2)],[f('F1',1)],['A']), []);
});

test('empty queue or no free fields produces no assignment', () => {
  assert.deepEqual(assignNextMatchesToFields([], [f('F1',1)]), []);
  assert.deepEqual(assignNextMatchesToFields([m('M1','A','B',1)],[]), []);
  assert.deepEqual(assignNextMatchesToFields([m('M1','A','B',1)],[f('F1',1,true)]), []);
});

for (const mode of ['group_rotation','group_sequential'] as const) {
  test(`100-team simulation (${mode}): all 450 group matches finish without overlaps`, () => {
    const groups: Group[] = Array.from({length:10}, (_,i) => ({
      id: `G${i}`, name: `G${i}`, sortOrder:i,
      teams: Array.from({length:10},(_,j) => ({id: `T${i}-${j}`, name: `T${i}-${j}`})),
    }));
    const initial = buildGroupQueue(groups, generateAllGroupMatches(groups), mode)
      .map((match,i) => m(match.id,match.team1Id,match.team2Id,i+1));
    assert.equal(initial.length,450);
    assert.equal(new Set(initial.map(x=>x.id)).size,450);
    assert.equal(new Set(initial.map(x=>[x.team1Id,x.team2Id].sort().join('|'))).size,450);
    let queue = [...initial];
    const fields = Array.from({length:8},(_,i)=>f(`F${i}`,i));
    const live = new Map<string,QueuedMatch>();
    const completed = new Set<string>();
    let iterations = 0;
    while(queue.length || live.size) {
      assert.ok(++iterations <= 451, 'simulation did not terminate');
      const busy = [...live.values()].flatMap(x=>[x.team1Id,x.team2Id]);
      const assignments = assignNextMatchesToFields(queue,fields.map(x=>({...x,occupied:live.has(x.id)})),busy);
      for (const a of assignments) {
        assert.ok(!live.has(a.fieldId));
        const next = queue.find(x=>!busy.includes(x.team1Id)&&!busy.includes(x.team2Id));
        assert.ok(next);
        assert.equal(a.matchId,next.id,'first eligible match must be selected');
        live.set(a.fieldId,next);
        busy.push(next.team1Id,next.team2Id);
        queue = queue.filter(x=>x.id!==next.id);
      }
      assert.equal(new Set(busy).size,busy.length);
      assert.ok(live.size<=fields.length);
      const first = live.entries().next().value;
      assert.ok(first, 'remaining matches cannot be scheduled');
      const [fieldId,finished] = first;
      assert.ok(!completed.has(finished.id));
      completed.add(finished.id);
      live.delete(fieldId);
    }
    assert.equal(completed.size,450);
    assert.deepEqual([...completed].sort(),initial.map(x=>x.id).sort());
  });
}
