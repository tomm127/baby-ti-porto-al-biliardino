import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeLanguage, readLanguage, saveLanguage, translate } from '../src/lib/language.ts';

test('English is the default for first visits and unsupported preferences', () => {
  for (const value of [null, undefined, '', 'de', 'en']) assert.equal(normalizeLanguage(value), 'en');
  assert.equal(readLanguage(), 'en');
  assert.equal(normalizeLanguage('it'), 'it');
});

test('Language preference is saved per storage instance and restored', () => {
  const makeStorage = () => {
    const data = new Map<string, string>();
    return { getItem: (key: string) => data.get(key) ?? null, setItem: (key: string, value: string) => { data.set(key, value); } };
  };
  const firstDevice = makeStorage();
  const secondDevice = makeStorage();
  saveLanguage(firstDevice, 'it');
  assert.equal(readLanguage(firstDevice), 'it');
  assert.equal(readLanguage(secondDevice), 'en');
  saveLanguage(firstDevice, 'en');
  assert.equal(readLanguage(firstDevice), 'en');
});

test('Unavailable browser storage does not break language selection', () => {
  const unavailable = { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } };
  assert.equal(readLanguage(unavailable), 'en');
  assert.doesNotThrow(() => saveLanguage(unavailable, 'it'));
});

test('Both translations and dynamic values are preserved', () => {
  assert.equal(translate('en', 'Next match', 'Prossima partita'), 'Next match');
  assert.equal(translate('it', 'Next match', 'Prossima partita'), 'Prossima partita');
  const table = 'Table 3';
  assert.equal(translate('it', `Go to ${table}`, `Vai a ${table}`), 'Vai a Table 3');
});
