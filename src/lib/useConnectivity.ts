import { useEffect, useState } from 'react';

export function browserIsOnline() {
  return typeof navigator === 'undefined' ? true : navigator.onLine;
}

export function requireOnline() {
  if (!browserIsOnline()) {
    throw new Error('Connessione assente. I dati restano visibili, ma per modificare il torneo devi tornare online.');
  }
}

export function useConnectivity(onReconnect?: () => void) {
  const [online, setOnline] = useState(browserIsOnline());

  useEffect(() => {
    const handleOnline = () => {
      setOnline(true);
      onReconnect?.();
    };
    const handleOffline = () => setOnline(false);
    window.addEventListener('online', handleOnline);
    window.addEventListener('offline', handleOffline);
    return () => {
      window.removeEventListener('online', handleOnline);
      window.removeEventListener('offline', handleOffline);
    };
  }, [onReconnect]);

  return online;
}
