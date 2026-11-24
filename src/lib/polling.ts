// Framework-independent scheduler: only one automatic refresh at a time.
export interface PollingEnvironment {
  schedule: (callback: () => void, delay: number) => number;
  cancel: (handle: number) => void;
  hidden: () => boolean;
  onVisibilityChange: (callback: () => void) => () => void;
  random: () => number;
}

export function startPolling(
  refresh: () => Promise<unknown>,
  intervalMs: number,
  pauseWhenHidden: boolean,
  env: PollingEnvironment,
): () => void {
  let stopped = false;
  let running = false;
  let timer: number | undefined;
  const canPoll = () => !stopped && (!pauseWhenHidden || !env.hidden());

  function clear() {
    if (timer !== undefined) env.cancel(timer);
    timer = undefined;
  }

  function schedule(delay: number) {
    clear();
    if (!canPoll() || running) return;
    timer = env.schedule(() => { timer = undefined; void run(); }, delay);
  }

  async function run() {
    if (!canPoll() || running) return;
    running = true;
    try { await refresh(); }
    catch { /* Page refresh functions already report failures; keep polling. */ }
    finally {
      running = false;
      schedule(intervalMs);
    }
  }

  const unsubscribe = env.onVisibilityChange(() => {
    clear();
    // Refresh as soon as a hidden tab becomes visible. If a request is
    // already running, let it finish and resume the normal cadence.
    if (canPoll() && !env.hidden()) void run();
    else if (canPoll()) schedule(intervalMs);
  });
  // Spread initial requests across devices; no synchronized bursts.
  schedule(intervalMs + Math.floor(env.random() * intervalMs * 0.1));
  return () => { stopped = true; clear(); unsubscribe(); };
}
