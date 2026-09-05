type SoundKey = 'race' | 'bell' | 'notification';

const SOUND_URLS: Record<SoundKey, string> = {
  race: '/sounds/race-start-beeps-125125.mp3',
  bell: '/sounds/boxing-bell-1-232450.mp3',
  notification: '/sounds/new-notification-09-352705.mp3',
};

let gameAudioContext: AudioContext | null = null;
let unlockListenersInstalled = false;

const buffers = new Map<SoundKey, AudioBuffer>();
const loadingBuffers = new Map<SoundKey, Promise<AudioBuffer | null>>();

let raceSource: AudioBufferSourceNode | null = null;
let racePlayingUntil = 0;
let bellSource: AudioBufferSourceNode | null = null;

type SafariAudioWindow = Window & {
  webkitAudioContext?: typeof AudioContext;
};

function getGameAudioContext() {
  if (gameAudioContext) return gameAudioContext;

  const AudioContextCtor =
    window.AudioContext ||
    (window as SafariAudioWindow).webkitAudioContext;

  if (!AudioContextCtor) return null;

  gameAudioContext = new AudioContextCtor();
  return gameAudioContext;
}

function scheduleSilentUnlockTone(ctx: AudioContext) {
  const oscillator = ctx.createOscillator();
  const gain = ctx.createGain();
  const now = ctx.currentTime + 0.005;

  oscillator.frequency.setValueAtTime(440, now);
  gain.gain.setValueAtTime(0.00001, now);
  gain.gain.setValueAtTime(0.00001, now + 0.025);

  oscillator.connect(gain);
  gain.connect(ctx.destination);
  oscillator.start(now);
  oscillator.stop(now + 0.03);
}

async function runningGameAudioContext() {
  const ctx = getGameAudioContext();
  if (!ctx) return null;

  try {
    if (ctx.state === 'suspended') await ctx.resume();
  } catch {
    return null;
  }

  return ctx.state === 'running' ? ctx : null;
}

async function loadSoundBuffer(key: SoundKey) {
  const existing = buffers.get(key);
  if (existing) return existing;

  const loading = loadingBuffers.get(key);
  if (loading) return loading;

  const promise = (async () => {
    const ctx = getGameAudioContext();
    if (!ctx) return null;

    try {
      const response = await fetch(SOUND_URLS[key], { cache: 'force-cache' });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);

      const encoded = await response.arrayBuffer();
      const decoded = await ctx.decodeAudioData(encoded.slice(0));
      buffers.set(key, decoded);
      return decoded;
    } catch (error) {
      console.warn(`BTPB: non riesco a caricare il suono ${key}`, error);
      return null;
    } finally {
      loadingBuffers.delete(key);
    }
  })();

  loadingBuffers.set(key, promise);
  return promise;
}

async function playBuffer(
  key: SoundKey,
  offsetSeconds = 0,
  volume = 1,
) {
  const ctx = await runningGameAudioContext();
  if (!ctx) return null;

  const buffer = await loadSoundBuffer(key);
  if (!buffer) return null;

  const source = ctx.createBufferSource();
  const gain = ctx.createGain();

  source.buffer = buffer;
  gain.gain.value = Math.max(0, Math.min(1, volume));

  source.connect(gain);
  gain.connect(ctx.destination);

  const safeOffset = Math.max(
    0,
    Math.min(offsetSeconds, Math.max(0, buffer.duration - 0.03)),
  );

  source.start(0, safeOffset);
  return { ctx, source, buffer, safeOffset };
}

function installGlobalAudioUnlock() {
  if (unlockListenersInstalled) return;
  unlockListenersInstalled = true;

  const unlock = () => {
    void unlockBtpbGameAudio();
  };

  // Keep listeners active. iOS can suspend audio after the PWA backgrounds;
  // the next user interaction resumes the same media audio session.
  window.addEventListener('pointerdown', unlock, { passive: true, capture: true });
  window.addEventListener('touchend', unlock, { passive: true, capture: true });
}

/**
 * Unlock the media audio path on iOS/Android and preload all three real sounds.
 */
export async function unlockBtpbGameAudio() {
  const ctx = await runningGameAudioContext();
  if (!ctx) return false;

  scheduleSilentUnlockTone(ctx);

  void Promise.all([
    loadSoundBuffer('race'),
    loadSoundBuffer('bell'),
    loadSoundBuffer('notification'),
  ]);

  return true;
}

export function installBtpbGameAudioUnlock() {
  installGlobalAudioUnlock();
}

/**
 * Real Pixabay "Race Start Beeps".
 *
 * The file contains 4 tones: three 450 Hz countdown tones and a final
 * higher 900 Hz GO tone. BTPB's server countdown is 3 seconds, so:
 *
 *   t=0  -> UI 3 + first low beep
 *   t=1  -> UI 2 + second low beep
 *   t=2  -> UI 1 + third low beep
 *   t=3  -> timer starts + high GO beep
 *
 * PlayerPage still calls this function for 3, 2 and 1. We start the complete
 * file once. If a phone joins the countdown late, it seeks forward so the
 * final high beep remains aligned as closely as possible with timer start.
 */
export async function playBtpbCountdownBeep(step: number) {
  if (step < 1 || step > 3) return false;

  const ctx = await runningGameAudioContext();
  if (!ctx) return false;

  // If the full race sequence is already running, do not restart it at 2 or 1.
  if (step !== 3 && raceSource && racePlayingUntil > ctx.currentTime + 0.05) {
    return true;
  }

  if (step === 3 && raceSource) {
    try { raceSource.stop(); } catch { /* already ended */ }
    raceSource = null;
    racePlayingUntil = 0;
  }

  // If this phone first notices the match at 2 or 1, catch up in the source.
  const offset = step === 3 ? 0 : step === 2 ? 1 : 2;
  const played = await playBuffer('race', offset, 0.96);
  if (!played) return false;

  raceSource = played.source;
  racePlayingUntil =
    played.ctx.currentTime + Math.max(0, played.buffer.duration - played.safeOffset);

  const ownSource = played.source;
  played.source.onended = () => {
    if (raceSource === ownSource) {
      raceSource = null;
      racePlayingUntil = 0;
    }
  };

  return true;
}

/**
 * Real "Boxing Bell 1" for the end of the match.
 */
export async function playBtpbTimerEndAlarm() {
  if (raceSource) {
    try { raceSource.stop(); } catch { /* already ended */ }
    raceSource = null;
    racePlayingUntil = 0;
  }

  if (bellSource) {
    try { bellSource.stop(); } catch { /* already ended */ }
    bellSource = null;
  }

  const played = await playBuffer('bell', 0, 1);
  if (!played) return false;

  bellSource = played.source;
  const ownSource = played.source;
  played.source.onended = () => {
    if (bellSource === ownSource) bellSource = null;
  };

  return true;
}

/**
 * Foreground push alert: real "New Notification 09".
 */
export async function primeBtpbAlertSound() {
  const unlocked = await unlockBtpbGameAudio();
  if (!unlocked) return false;
  await loadSoundBuffer('notification');
  return true;
}

export async function playBtpbAlertSound() {
  const played = await playBuffer('notification', 0, 1);
  return Boolean(played);
}

export function installBtpbAlertSoundUnlock() {
  installGlobalAudioUnlock();
}
