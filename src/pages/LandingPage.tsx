import { useCallback, useEffect, useState } from 'react';
import { hasSupabaseConfig } from '../lib/supabase.ts';
import { listActiveTournamentsResilient, type TournamentRow } from '../lib/api.ts';
import { useConnectivity } from '../lib/useConnectivity.ts';
import { navigate } from '../router.ts';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';

const LAST_PLAYER_TOURNAMENT_KEY = 'btpb:last-player-tournament';

export function LandingPage() {
  const [tournaments, setTournaments] = useState<TournamentRow[]>([]);
  const [loading, setLoading] = useState(hasSupabaseConfig);
  const [error, setError] = useState('');
  const [cachedAt, setCachedAt] = useState<string | null>(null);
  const [resumingPlayer, setResumingPlayer] = useState(false);

  const refresh = useCallback(async () => {
    if (!hasSupabaseConfig) return;
    try {
      const result = await listActiveTournamentsResilient();
      setTournaments(result.data);
      setCachedAt(result.source === 'cache' ? result.cachedAt : null);
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, []);

  const online = useConnectivity(() => void refresh());

  useEffect(() => {
    const chooseExplicitly = new URLSearchParams(window.location.search).get('choose') === '1';
    if (chooseExplicitly) return;

    const rememberedSlug = window.localStorage.getItem(LAST_PLAYER_TOURNAMENT_KEY);
    if (!rememberedSlug) return;

    setResumingPlayer(true);
    navigate(`/tournament/${rememberedSlug}`);
  }, []);

  useEffect(() => { if (!resumingPlayer) void refresh(); }, [refresh, resumingPlayer]);

  if (resumingPlayer) {
    return <main className="page landing-page landing-v2 landing-resuming-player">
      <div className="landing-resume-copy">Apro la tua squadra…</div>
    </main>;
  }

  return (
    <main className="page landing-page landing-v2">
      <button className="landing-winners-link" onClick={() => navigate('/albo-vincitori')}>
        Albo vincitori
      </button>

      <button className="landing-admin-link" onClick={() => navigate('/admin')}>
        Admin
      </button>

      <section className="landing-shell-v2">
        <div className="landing-brand-v2">
          <img src="/brand/btpb-logo.png" alt="Baby Ti Porto al Biliardino" />
          <div>
            <h1>Baby Ti Porto al Biliardino</h1>
            <p>Scegli il torneo e inizia.</p>
          </div>
        </div>

        <ConnectionBanner online={online} cachedAt={cachedAt} />

        {!hasSupabaseConfig && (
          <div className="alert warning">
            <strong>Supabase non è ancora collegato.</strong>
            <span>Crea <code>.env.local</code> usando il file di esempio incluso nel progetto.</span>
          </div>
        )}

        {error && <div className="alert error">{error}</div>}

        <div className="landing-tournament-list-v2">
          {loading && (
            <div className="landing-loading-v2">Caricamento tornei…</div>
          )}

          {!loading && hasSupabaseConfig && tournaments.length === 0 && (
            <div className="landing-empty-v2">
              Nessun torneo attivo.
            </div>
          )}

          {tournaments.map((t) => (
            <article className="landing-tournament-v2" key={t.id}>
              <div className="landing-tournament-title-v2">
                <span>{t.phase === 'groups' ? 'FASE A GIRONI' : 'ELIMINAZIONE'}</span>
                <h2>{t.name}</h2>
              </div>

              <button
                className="landing-play-v2"
                onClick={() => navigate(`/tournament/${t.slug}`)}
              >
                <strong>PARTECIPA</strong>
                <span>Entra nel torneo</span>
              </button>

              <button
                className="landing-tv-v2"
                onClick={() => navigate(`/screen/${t.slug}`)}
              >
                <span>Schermo TV</span>
                <strong>→</strong>
              </button>
            </article>
          ))}
        </div>
      </section>
    </main>
  );
}
