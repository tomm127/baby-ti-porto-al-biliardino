import { useEffect } from 'react';

export function useRefresh(callback: () => void, milliseconds: number, enabled = true) {
  useEffect(() => {
    if (!enabled) return;
    const id = window.setInterval(callback, milliseconds);
    const onVisible = () => { if (document.visibilityState === 'visible') callback(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => {
      window.clearInterval(id);
      document.removeEventListener('visibilitychange', onVisible);
    };
  }, [callback, milliseconds, enabled]);
}
