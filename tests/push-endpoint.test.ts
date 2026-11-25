import test from 'node:test';
import assert from 'node:assert/strict';
import { validatedPushEndpoint } from '../supabase/functions/send-push/endpoint.ts';

test('accepts each observed browser push provider', () => {
  for (const host of ['web.push.apple.com','fcm.googleapis.com','updates.push.services.mozilla.com']) {
    const url = 'https://' + host + '/test-token';
    assert.equal(validatedPushEndpoint(url), url);
  }
});
test('accepts normal HTTPS port and preserves endpoint query', () => {
  assert.equal(validatedPushEndpoint('https://FCM.GOOGLEAPIS.COM:443/test?x=1'), 'https://fcm.googleapis.com/test?x=1');
});
test('rejects unknown providers and deceptive host names', () => {
  for (const url of ['https://example.invalid/path','https://fcm.googleapis.com.example.invalid/path','https://127.0.0.1/path']) assert.equal(validatedPushEndpoint(url), null);
});
test('rejects non-HTTPS, credentials, nonstandard ports and malformed URLs', () => {
  for (const url of ['http://fcm.googleapis.com/path','https://user@fcm.googleapis.com/path','https://@fcm.googleapis.com/path','https://fcm.googleapis.com:444/path','https://fcm.googleapis.com/path#fragment','https://fcm.googleapis.com/','not a URL',' https://fcm.googleapis.com/path']) assert.equal(validatedPushEndpoint(url), null);
});
