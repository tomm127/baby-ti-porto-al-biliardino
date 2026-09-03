const CLOCK_OFFSET_KEY = 'baby-biliardino:server-clock-offset-ms';
let serverClockOffsetMs = readStoredOffset();

function readStoredOffset() {
  if (typeof window === 'undefined') return 0;
  try {
    const value = Number(window.localStorage.getItem(CLOCK_OFFSET_KEY));
    return Number.isFinite(value) ? value : 0;
  } catch {
    return 0;
  }
}

function storeOffset(value: number) {
  if (typeof window === 'undefined') return;
  try { window.localStorage.setItem(CLOCK_OFFSET_KEY, String(Math.round(value))); } catch { /* storage may be disabled */ }
}

/**
 * Calibrate the browser clock against a server timestamp using the midpoint of
 * the request round trip. This keeps the 3-2-1 and the match timer aligned even
 * if one phone's local clock is a few seconds wrong.
 */
export function syncServerClock(serverIso: string | null | undefined, requestStartedMs: number, responseReceivedMs: number) {
  if (!serverIso) return;
  const serverMs = new Date(serverIso).getTime();
  if (!Number.isFinite(serverMs)) return;
  const midpoint = requestStartedMs + (responseReceivedMs - requestStartedMs) / 2;
  const candidate = serverMs - midpoint;
  // A wildly wrong value usually means a malformed timestamp. Ignore it rather
  // than ruining an in-progress timer.
  if (Math.abs(candidate) > 24 * 60 * 60 * 1000) return;
  serverClockOffsetMs = candidate;
  storeOffset(candidate);
}

export function serverNowMs() {
  return Date.now() + serverClockOffsetMs;
}

export function getServerClockOffsetMs() {
  return serverClockOffsetMs;
}

export function secondsRemaining(match: {
  timer_remaining_seconds: number | null;
  timer_started_at: string | null;
}): number | null {
  if (match.timer_remaining_seconds == null) return null;
  if (!match.timer_started_at) return Math.max(0, match.timer_remaining_seconds);
  const elapsed = Math.max(0, Math.floor((serverNowMs() - new Date(match.timer_started_at).getTime()) / 1000));
  return Math.max(0, match.timer_remaining_seconds - elapsed);
}

export function countdownRemaining(startedAt: string | null): number {
  if (!startedAt) return 0;
  return Math.max(0, Math.ceil((new Date(startedAt).getTime() - serverNowMs()) / 1000));
}

export function formatClock(seconds: number | null): string {
  if (seconds == null) return 'SENZA TIMER';
  const safe = Math.max(0, Math.floor(seconds));
  const m = Math.floor(safe / 60);
  const s = safe % 60;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
}
