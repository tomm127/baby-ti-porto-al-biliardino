let alertAudio: HTMLAudioElement | null = null;

function getAlertAudio() {
  if (!alertAudio) {
    alertAudio = new Audio('/sounds/btpb-alert.wav');
    alertAudio.preload = 'auto';
    alertAudio.volume = 1;
  }
  return alertAudio;
}

/**
 * Call this from a real user gesture (e.g. enable notifications / start match)
 * so iOS/Android are more likely to allow later media playback.
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
