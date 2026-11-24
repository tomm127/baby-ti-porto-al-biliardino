import { useEffect, useState } from 'react';
import { navigate } from '../router.ts';
import { useLanguage } from '../lib/i18n.tsx';
import { LanguageSwitch } from '../components/LanguageSwitch.tsx';
import { ensureAnonymousPlayerSession, supabase } from '../lib/supabase.ts';
import './winners-history.css';

interface HallOfFameRow {
  tournament_id: string;
  tournament_name: string;
  completed_at: string;
  champion_name: string;
  champion_avatar: string | null;
  runner_up_name: string;
  runner_up_avatar: string | null;
  third_place_name: string | null;
  third_place_avatar: string | null;
  champion_score: number | null;
  runner_up_score: number | null;
}

// StrictMode and rapid retry can share an ongoing read, without caching stale results.
let pending: Promise<HallOfFameRow[]> | null = null;
function loadHistory(): Promise<HallOfFameRow[]> {
  if (pending) return pending;
  pending = (async () => {
    if (!supabase) throw new Error('Supabase not configured');
    if (!(await ensureAnonymousPlayerSession())) throw new Error('Session unavailable');
    const { data, error } = await supabase.rpc('get_hall_of_fame');
    if (error) throw new Error(error.message);
    return (data ?? []) as HallOfFameRow[];
  })().finally(() => { pending = null; });
  return pending;
}

function PodiumCard({ rank, name, avatar, label }: { rank: number; name: string; avatar: string | null; label: string }) {
  const [failed, setFailed] = useState(false);
  useEffect(() => setFailed(false), [avatar]);
  return <article className={`winner-placeholder-card history-podium rank-${rank}`}>
    <div className="history-portrait">
      {avatar && !failed ? <img src={avatar} alt="" loading="lazy" onError={() => setFailed(true)} /> : <span aria-hidden="true">{rank === 1 ? '🏆' : rank === 2 ? '🥈' : '🥉'}</span>}
    </div>
    <div><span>{label}</span><h3>{name}</h3></div>
  </article>;
}

export function WinnersPage() {
  const { t, language } = useLanguage();
  const [rows, setRows] = useState<HallOfFameRow[]>([]);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setFailed(false);
    loadHistory().then((result) => {
      if (!cancelled) setRows(result);
    }).catch((error: unknown) => {
      console.warn('Hall of fame:', error);
      if (!cancelled) setFailed(true);
    }).finally(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [attempt]);
  useEffect(() => {
    const reconnect = () => setAttempt((value) => value + 1);
    window.addEventListener('online', reconnect);
    return () => window.removeEventListener('online', reconnect);
  }, []);
  const date = (value: string) => new Intl.DateTimeFormat(language === 'it' ? 'it-IT' : 'en-GB', { dateStyle: 'long', timeZone: 'Europe/Zurich' }).format(new Date(value));

  return <main className="page winners-page">
    <section className="winners-shell">
      <header className="winners-header">
        <button className="winners-back" aria-label={t('Back', 'Indietro')} onClick={() => navigate('/?choose=1')}>←</button>
        <div><span>Baby Ti Porto al Biliardino</span><h1>{t('Hall of fame', 'Albo vincitori')}</h1></div>
        <div className="winners-language-control"><LanguageSwitch /></div>
      </header>
      <div className="winners-intro">
        <img src="/brand/btpb-logo.png" alt="" />
        <div><strong>{t('Tournament history', 'La storia del torneo')}</strong><p>{t('The champions and podiums of completed tournaments.', 'I campioni e i podi dei tornei conclusi.')}</p></div>
      </div>
      <div className="history-toolbar"><button className="button secondary" disabled={loading} onClick={() => setAttempt((value) => value + 1)}>{t('Refresh', 'Aggiorna')}</button></div>
      {loading && <p role="status" className="winners-coming-soon">{t('Loading results…', 'Caricamento risultati…')}</p>}
      {failed && <div className="alert error" role="alert">{t('Unable to refresh results. Please try again.', 'Impossibile aggiornare i risultati. Riprova.')}</div>}
      {!loading && !failed && rows.length === 0 && <section className="winners-year"><h2>{t('No champions yet', 'Ancora nessun campione')}</h2><p>{t('Results will appear here once a tournament with a final is completed.', 'I risultati appariranno qui alla conclusione di un torneo con finale.')}</p></section>}
      <div className="history-editions">{rows.map((row) => <section key={row.tournament_id} className="winners-year">
        <div className="winners-year-title"><span>{date(row.completed_at)}</span><h2>{row.tournament_name}</h2></div>
        <div className="winners-category-grid">
          <PodiumCard rank={1} name={row.champion_name} avatar={row.champion_avatar} label={t('Champions', 'Campioni')} />
          <PodiumCard rank={2} name={row.runner_up_name} avatar={row.runner_up_avatar} label={t('Runner-up', 'Secondo posto')} />
          {row.third_place_name && <PodiumCard rank={3} name={row.third_place_name} avatar={row.third_place_avatar} label={t('Third place', 'Terzo posto')} />}
        </div>
        {row.champion_score !== null && row.runner_up_score !== null && <p className="history-final-score">{t('Final score', 'Risultato finale')}: <strong>{row.champion_score} – {row.runner_up_score}</strong></p>}
      </section>)}</div>
    </section>
  </main>;
}
