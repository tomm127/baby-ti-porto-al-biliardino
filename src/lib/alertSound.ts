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
  const frequency = step === 3 ? 620 : step === 2 ? 720 : 1020;
  const duration = step === 1 ? 0.34 : 0.16;
  const volume = step === 1 ? 0.34 : 0.25;

  scheduleTone(ctx, frequency, now, duration, volume, 'triangle');
  scheduleTone(ctx, frequency * 2, now, duration, volume * 0.22, 'sine');

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
  const bursts = [
    { at: 0.00, frequency: 760, duration: 0.24, volume: 0.34 },
    { at: 0.31, frequency: 760, duration: 0.24, volume: 0.34 },
    { at: 0.62, frequency: 980, duration: 0.40, volume: 0.38 },
    { at: 1.12, frequency: 820, duration: 0.58, volume: 0.36 },
  ];

  for (const burst of bursts) {
    scheduleTone(ctx, burst.frequency, base + burst.at, burst.duration, burst.volume, 'triangle');
    scheduleTone(ctx, burst.frequency * 2, base + burst.at, burst.duration, burst.volume * 0.20, 'sine');
  }

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
