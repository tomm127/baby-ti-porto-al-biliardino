import { useEffect } from 'react';
import { startPolling } from './polling.ts';

/** Initial loading and explicit post-mutation refresh remain owned by the page. */
export function useTournamentPolling(
  refresh: () => Promise<unknown>,
  enabled: boolean,
  intervalMs: number,
  pauseWhenHidden = true,
) {
  useEffect(() => {
    if (!enabled) return;
    return startPolling(refresh, intervalMs, pauseWhenHidden, {
      schedule: (callback, delay) => window.setTimeout(callback, delay),
      cancel: (handle) => window.clearTimeout(handle),
      hidden: () => document.hidden,
      onVisibilityChange: (callback) => {
        document.addEventListener('visibilitychange', callback);
        return () => document.removeEventListener('visibilitychange', callback);
      },
      random: Math.random,
    });
  }, [refresh, enabled, intervalMs, pauseWhenHidden]);
}
