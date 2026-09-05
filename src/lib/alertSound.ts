let alertAudio: HTMLAudioElement | null = null;
let gameAudioContext: AudioContext | null = null;

type SafariAudioWindow = Window & {
  webkitAudioContext?: typeof AudioContext;
};

function getAlertAudio() {
  if (!alertAudio) {
    alertAudio = new Audio('/sounds/btpb-alert.wav');
    alertAudio.preload = 'auto';
    alertAudio.volume = 1;
  }
  return alertAudio;
}

function getGameAudioContext() {
  if (gameAudioContext) return gameAudioContext;

  const AudioContextCtor =
    window.AudioContext ||
    (window as SafariAudioWindow).webkitAudioContext;

  if (!AudioContextCtor) return null;

  gameAudioContext = new AudioContextCtor();
  return gameAudioContext;
}

function scheduleTone(
  ctx: AudioContext,
  frequency: number,
  startAt: number,
  duration: number,
  volume: number,
  type: OscillatorType = 'sine',
) {
  const oscillator = ctx.createOscillator();
  const gain = ctx.createGain();

  oscillator.type = type;
  oscillator.frequency.setValueAtTime(frequency, startAt);

  gain.gain.setValueAtTime(0.0001, startAt);
  gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, volume), startAt + 0.018);
  gain.gain.exponentialRampToValueAtTime(0.0001, startAt + duration);

  oscillator.connect(gain);
  gain.connect(ctx.destination);

  oscillator.start(startAt);
  oscillator.stop(startAt + duration + 0.02);
}

function scheduleSweep(
  ctx: AudioContext,
  fromFrequency: number,
  toFrequency: number,
  startAt: number,
  duration: number,
  volume: number,
  type: OscillatorType = 'triangle',
) {
  const oscillator = ctx.createOscillator();
  const gain = ctx.createGain();

  oscillator.type = type;
  oscillator.frequency.setValueAtTime(fromFrequency, startAt);
  oscillator.frequency.exponentialRampToValueAtTime(
    Math.max(1, toFrequency),
    startAt + duration,
  );

  gain.gain.setValueAtTime(0.0001, startAt);
  gain.gain.exponentialRampToValueAtTime(Math.max(0.0002, volume), startAt + 0.025);
  gain.gain.setValueAtTime(Math.max(0.0002, volume), startAt + Math.max(0.03, duration - 0.12));
  gain.gain.exponentialRampToValueAtTime(0.0001, startAt + duration);

  oscillator.connect(gain);
  gain.connect(ctx.destination);
  oscillator.start(startAt);
  oscillator.stop(startAt + duration + 0.03);
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

/**
 * Run this during real user gestures. Once unlocked, countdown/end sounds are
 * produced by Web Audio and therefore use the phone's media-audio path rather
 * than depending on the notification sound channel.
 */
export async function unlockBtpbGameAudio() {
  const ctx = await runningGameAudioContext();
  if (!ctx) return false;

  // A practically silent, extremely short tone helps Safari/iOS establish
  // the audio session while we are still inside a user gesture.
  const now = ctx.currentTime + 0.005;
  scheduleTone(ctx, 440, now, 0.025, 0.0002);
  return true;
}

export function installBtpbGameAudioUnlock() {
  const unlock = () => {
    void unlockBtpbGameAudio();
  };

  // Keep these listeners installed: if a phone suspends audio after backgrounding,
  // the next interaction will resume the same audio context.
  window.addEventListener('pointerdown', unlock, { passive: true, capture: true });
  window.addEventListener('touchend', unlock, { passive: true, capture: true });
}

/**
 * Player match countdown only.
 * 3 and 2 = short beep; 1 = higher/longer start beep.
 */
export async function playBtpbCountdownBeep(step: number) {
  if (step < 1 || step > 3) return false;

  const ctx = await runningGameAudioContext();
  if (!ctx) return false;

  const now = ctx.currentTime + 0.01;

  if (step === 3) {
    scheduleSweep(ctx, 720, 880, now, 0.22, 0.25, 'sine');
    scheduleTone(ctx, 1440, now, 0.15, 0.055, 'sine');
  } else if (step === 2) {
    scheduleSweep(ctx, 820, 1020, now, 0.24, 0.28, 'sine');
    scheduleTone(ctx, 1640, now, 0.16, 0.06, 'sine');
  } else {
    scheduleSweep(ctx, 760, 1520, now, 0.92, 0.40, 'triangle');
    scheduleSweep(ctx, 1520, 2280, now, 0.92, 0.095, 'sine');
    scheduleTone(ctx, 3040, now + 0.10, 0.58, 0.035, 'sine');
  }

  return true;
}

/**
 * Strong end-of-match multimedia alarm, used only while the player match page
 * is active. Deliberately distinct from the 3-2-1 countdown.
 */
export async function playBtpbTimerEndAlarm() {
  const ctx = await runningGameAudioContext();
  if (!ctx) return false;

  const base = ctx.currentTime + 0.015;

  scheduleSweep(ctx, 1320, 1120, base, 0.34, 0.37, 'triangle');
  scheduleTone(ctx, 2640, base, 0.24, 0.055, 'sine');

  scheduleSweep(ctx, 1380, 1160, base + 0.48, 0.34, 0.38, 'triangle');
  scheduleTone(ctx, 2760, base + 0.48, 0.24, 0.055, 'sine');

  scheduleSweep(ctx, 1520, 720, base + 0.98, 1.55, 0.43, 'sawtooth');
  scheduleSweep(ctx, 3040, 1440, base + 0.98, 1.55, 0.055, 'sine');

  return true;
}

/**
 * Existing HTML media sound, retained for foreground push alerts.
 */
export async function primeBtpbAlertSound() {
  const audio = getAlertAudio();

  try {
    audio.currentTime = 0;
    audio.muted = true;
    await audio.play();
    audio.pause();
    audio.currentTime = 0;
    audio.muted = false;
  } catch {
    audio.muted = false;
  }
}

export async function playBtpbAlertSound() {
  const audio = getAlertAudio();

  try {
    audio.pause();
    audio.currentTime = 0;
    audio.muted = false;
    audio.volume = 1;
    await audio.play();
    return true;
  } catch {
    return false;
  }
}

export function installBtpbAlertSoundUnlock() {
  const unlock = () => {
    void primeBtpbAlertSound();
  };

  window.addEventListener('pointerdown', unlock, { once: true, passive: true });
  window.addEventListener('touchend', unlock, { once: true, passive: true });
}
