import test from 'node:test';
import assert from 'node:assert/strict';
import { parseMatchScore } from '../src/domain/score.ts';

test('explicit zero and ordinary nonnegative scores are accepted', () => {
  for (const [raw, expected] of [['0', 0], ['10', 10], [' 7 ', 7], ['003', 3]] as const) {
    assert.equal(parseMatchScore(raw), expected);
  }
});

test('blank or malformed scores never become zero', () => {
  for (const raw of ['', ' ', '  \t', '-1', '1.5', '1e2', 'NaN', 'Infinity', '+2']) {
    assert.equal(parseMatchScore(raw), null, raw);
  }
});

test('scores stay within PostgreSQL integer bounds', () => {
  assert.equal(parseMatchScore('2147483647'), 2147483647);
  assert.equal(parseMatchScore('2147483648'), null);
  assert.equal(parseMatchScore('99999999999999999999'), null);
});
