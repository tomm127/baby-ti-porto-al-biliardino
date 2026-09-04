import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import { App } from './App.tsx';
import './styles.css';
import { installBtpbAlertSoundUnlock, playBtpbAlertSound } from './lib/alertSound.ts';

createRoot(document.getElementById('root')!).render(<StrictMode><App /></StrictMode>);

installBtpbAlertSoundUnlock();

if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch((error) => console.warn('Service worker:', error));
  });
}


if ('serviceWorker' in navigator) {
  navigator.serviceWorker.addEventListener('message', (event) => {
    if (event.data?.type === 'BTPB_PUSH_ALERT') {
      void playBtpbAlertSound();
    }
  });
}
