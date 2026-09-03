import { useCallback, useEffect, useState } from 'react';
import { hasSupabaseConfig } from '../lib/supabase.ts';
import { listActiveTournamentsResilient, type TournamentRow } from '../lib/api.ts';
import { useConnectivity } from '../lib/useConnectivity.ts';
import { navigate } from '../router.ts';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';

export function LandingPage() {
  const [tournaments, setTournaments] = useState<TournamentRow[]>([]);
  const [loading, setLoading] = useState(hasSupabaseConfig);
  const [error, setError] = useState('');
  const [cachedAt, setCachedAt] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    if (!hasSupabaseConfig) return;
    try {
      const result = await listActiveTournamentsResilient();
      setTournaments(result.data);
      setCachedAt(result.source === 'cache' ? result.cachedAt : null);
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally { setLoading(false); }
  }, []);

  const online = useConnectivity(() => void refresh());
  useEffect(() => { void refresh(); }, [refresh]);

  return (
    <main className="page landing-page">
      <section className="hero-card landing-card">
        <div className="eyebrow">TORNEI DI BILIARDINO</div>
        <h1>Baby ti porto<br />al biliardino</h1>
        <p className="lead">Scegli il torneo, associa questo telefono alla tua squadra e lascia che la piattaforma ti chiami quando tocca a voi.</p>

        <ConnectionBanner online={online} cachedAt={cachedAt} />
        {!hasSupabaseConfig && <div className="alert warning"><strong>Supabase non è ancora collegato.</strong><span>Crea <code>.env.local</code> usando il file di esempio incluso nel progetto.</span></div>}
        {error && <div className="alert error">{error}</div>}

        <div className="tournament-list">
          <div className="section-heading"><strong>Tornei attivi</strong>{loading && <span>Caricamento…</span>}</div>
          {!loading && hasSupabaseConfig && tournaments.length === 0 && <div className="empty-state">Nessun torneo attivo. Creane uno dal pannello admin.</div>}
          {tournaments.map((t) => (
            <article className="tournament-card" key={t.id}>
              <div><div className="eyebrow">{t.phase === 'groups' ? 'FASE A GIRONI' : 'ELIMINAZIONE'}</div><h2>{t.name}</h2></div>
              <div className="tournament-actions">
                <button className="button primary" onClick={() => navigate(`/tournament/${t.slug}`)}>Gioca / segui</button>
                <button className="button secondary" onClick={() => navigate(`/screen/${t.slug}`)}>Schermo TV</button>
              </div>
            </article>
          ))}
        </div>

        <button className="button ghost admin-entry" onClick={() => navigate('/admin')}>Amministratore</button>
      </section>
    </main>
  );
}
