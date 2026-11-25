// Only explicitly supported Web Push providers may receive server requests.
const allowedHosts = new Set([
  'web.push.apple.com',
  'fcm.googleapis.com',
  'updates.push.services.mozilla.com',
]);

export function validatedPushEndpoint(raw: string): string | null {
  if (typeof raw !== 'string' || !/^https:\/\//i.test(raw) || /[\s\\#]/.test(raw)) return null;
  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:' || url.username || url.password || url.port ||
        !allowedHosts.has(url.hostname) || url.pathname === '/') return null;
    // Reject any user-info or noncanonical authority, including empty user-info.
    const authority = raw.slice(8).split(/[/?]/, 1)[0].toLowerCase();
    if (authority !== url.hostname && authority !== url.hostname + ':443') return null;
    return url.href;
  } catch { return null; }
}
