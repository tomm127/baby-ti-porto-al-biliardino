import { useEffect, useState } from 'react';
import { AdminPage } from './pages/AdminPage.tsx';
import { LandingPage } from './pages/LandingPage.tsx';
import { PlayerPage } from './pages/PlayerPage.tsx';
import { ScreenPage } from './pages/ScreenPage.tsx';
import { WinnersPage } from './pages/WinnersPage.tsx';

export function App() {
  const [path, setPath] = useState(window.location.pathname);

  useEffect(() => {
    const onPop = () => setPath(window.location.pathname);
    window.addEventListener('popstate', onPop);
    return () => window.removeEventListener('popstate', onPop);
  }, []);

  const parts = path.split('/').filter(Boolean).map(decodeURIComponent);
  if (parts[0] === 'albo-vincitori') return <WinnersPage />;
  if (parts[0] === 'admin') return <AdminPage />;
  if (parts[0] === 'screen' && parts[1]) return <ScreenPage slug={parts[1]} />;
  if (parts[0] === 'tournament' && parts[1]) {
    const matchId = parts[2] === 'match' ? parts[3] : undefined;
    return <PlayerPage slug={parts[1]} matchId={matchId} />;
  }
  return <LandingPage />;
}
