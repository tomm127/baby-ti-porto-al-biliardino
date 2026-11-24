import { btpbText, useBtpbUiLanguage, btpbError } from '../lib/btpbUiText.ts';
import { useCallback, useEffect, useRef, useState, type CSSProperties } from 'react';
import { loadTournamentBundleResilient, type MatchRow, type TournamentBundle } from '../lib/api.ts';
import { countdownRemaining, formatClock, secondsRemaining } from '../lib/time.ts';
import { useConnectivity } from '../lib/useConnectivity.ts';
import { useTournamentPolling } from '../lib/useTournamentPolling.ts';
import { navigate } from '../router.ts';
import { KnockoutBracket } from '../components/KnockoutBracket.tsx';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';
import { TeamLabel } from '../components/TeamLabel.tsx';
import { LanguageSwitch } from '../components/LanguageSwitch.tsx';
import '../tv.css';


export function ScreenPage({ slug }: { slug: string }) {
  useBtpbUiLanguage();
  const [bundle, setBundle] = useState<TournamentBundle | null>(null);
  const [error, setError] = useState('');
  const [cachedAt, setCachedAt] = useState<string | null>(null);
  const [, setTick] = useState(Date.now());
  const [flashingFields, setFlashingFields] = useState<Set<string>>(new Set());
  const [prepareFlash, setPrepareFlash] = useState(false);
  const previousFieldMatches = useRef<Map<string, string>>(new Map());
  const previousPrepareMatch = useRef<string | null>(null);
  const initialized = useRef(false);

  const refresh = useCallback(async () => {
    try {
      const result = await loadTournamentBundleResilient(slug);
      setBundle(result.bundle);
      setCachedAt(result.source === 'cache' ? result.cachedAt : null);
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, [slug]);

  const online = useConnectivity(() => void refresh());
  useEffect(() => { void refresh(); }, [refresh]);
  useTournamentPolling(refresh, online, 3000);
  useEffect(() => {
    const id = window.setInterval(() => setTick(Date.now()), 250);
    return () => window.clearInterval(id);
  }, []);

  useEffect(() => {
    if (!bundle) return;
    const live = bundle.matches.filter((m) => ['called','ready','playing','awaiting_result'].includes(m.status) && m.field_id);
    const current = new Map(live.map((m) => [m.field_id!, m.id]));
    const queue = bundle.matches.filter((m) => m.status === 'queued').sort(queueOrder);
    const prepareId = queue[0]?.id ?? null;

    if (initialized.current) {
      const changedFields = new Set<string>();
      for (const [fieldId, matchId] of current) {
        if (previousFieldMatches.current.get(fieldId) !== matchId) changedFields.add(fieldId);
      }
      if (changedFields.size) {
        setFlashingFields(changedFields);
        window.setTimeout(() => setFlashingFields(new Set()), 2800);
      }
      if (prepareId && prepareId !== previousPrepareMatch.current) {
        setPrepareFlash(true);
        window.setTimeout(() => setPrepareFlash(false), 2800);
      }
    } else {
      initialized.current = true;
    }

    previousFieldMatches.current = current;
    previousPrepareMatch.current = prepareId;
  }, [bundle]);

  if (!bundle) return <main className="screen-mode tv-v2"><header className="tv-header"><h1>{error ? btpbError(error) : btpbText("Caricamento…")}</h1><div className="tv-language-actions"><LanguageSwitch /><button className="screen-exit" onClick={() => navigate('/')}>{btpbText("Esci")}</button></div></header></main>;

  const activeFields = bundle.fields.filter((field) => field.is_active).sort((a,b) => a.sort_order - b.sort_order);
  const live = bundle.matches.filter((m) => ['called','ready','playing','awaiting_result'].includes(m.status));
  const byField = new Map(live.filter((m) => m.field_id).map((m) => [m.field_id!, m]));
  const allQueued = bundle.matches.filter((m) => m.status === 'queued').sort(queueOrder);
  const queue = allQueued.slice(0, 10);
  const queueSlots = Array.from({ length: 10 }, (_, index) => queue[index] ?? null);
  const playerUrl = `${window.location.origin}/tournament/${bundle.tournament.slug}`;
  const qrUrl = `https://quickchart.io/qr?text=${encodeURIComponent(playerUrl)}&size=180&margin=1&ecLevel=M`;
  const fieldColumns = activeFields.length <= 4 ? Math.max(activeFields.length, 1) : Math.ceil(activeFields.length / 2);
  const fieldStyle = { '--tv-field-cols': String(fieldColumns) } as CSSProperties;

  const queuePanel = <div className="tv-queue-panel tv-queue-fixed-10">
    <div className="tv-section-title"><span>{btpbText("PROSSIME PARTITE")}</span><strong>{allQueued.length ? `${allQueued.length}${btpbText(" IN CODA")}` : btpbText("NESSUNA IN CODA")}</strong></div>

    <div className="tv-fixed-queue-list">
      {queueSlots.map((match, index) => {
        const isPrepare = index === 0 && Boolean(match);

        if (!match) {
          return <div className="tv-fixed-queue-row empty" key={`empty-${index}`}>
            <span className="tv-fixed-queue-number">{index + 1}</span>
            <div className="tv-fixed-queue-empty-line" />
          </div>;
        }

        return <div
          className={isPrepare
            ? (prepareFlash ? 'tv-fixed-queue-row prepare flash' : 'tv-fixed-queue-row prepare')
            : 'tv-fixed-queue-row'}
          key={match.id}
        >
          <span className="tv-fixed-queue-number">{index + 1}</span>
          <div className="tv-fixed-queue-content">
            <div className="tv-fixed-queue-meta">
              {isPrepare && <strong>{btpbText("PROSSIMI")}</strong>}
              <small>{stageLabel(bundle, match)}</small>
            </div>
            <div className="tv-fixed-queue-match">
              <strong><TeamLabel bundle={bundle} teamId={match.team1_id} name={teamName(bundle, match.team1_id)} /></strong>
              <em>vs</em>
              <strong><TeamLabel bundle={bundle} teamId={match.team2_id} name={teamName(bundle, match.team2_id)} /></strong>
            </div>
          </div>
        </div>;
      })}
    </div>
  </div>;

  return <main className="screen-mode tv-v2">
    {bundle.settings.emergency_paused && <div className="tv-tournament-pause"><div><span>Ⅱ</span><strong>{btpbText("TORNEO IN PAUSA")}</strong><p>{btpbText("Attendere indicazioni dell'organizzazione")}</p></div></div>}
    <ConnectionBanner online={online} cachedAt={cachedAt} />

    <header className="tv-header">
      <div className="tv-brand-block">
        <div><h1>Baby Ti Porto al Biliardino</h1></div>
      </div>
      <div className="tv-language-actions">
        <LanguageSwitch />
        <button className="screen-exit" onClick={() => navigate('/')}>{btpbText("Esci")}</button>
      </div>
    </header>

    {error && <div className="alert error">{btpbError(error)}</div>}

    <section className="tv-fields" style={fieldStyle}>
      {activeFields.map((field) => <ScreenField key={field.id} name={field.name} match={byField.get(field.id)} bundle={bundle} flash={flashingFields.has(field.id)} />)}
    </section>

    {bundle.tournament.phase === 'groups' ? <section className="tv-middle tv-middle-queue-only">
      {queuePanel}
    </section> : <section className="tv-middle tv-middle-knockout">
      {queuePanel}
      <div className="tv-bracket-panel">
        <div className="tv-section-title"><span>{btpbText("TABELLONE")}</span><strong>{btpbText("ELIMINAZIONE DIRETTA")}</strong></div>
        <KnockoutBracket bundle={bundle} compact />
      </div>
    </section>}

    <footer className="tv-footer">
      <div className="tv-footer-brand"><img src="/brand/btpb-logo.png" alt="BTPB" /><div><strong>BTPB</strong><span>{btpbText("Segui il torneo dal telefono")}</span></div></div>
      <div className="tv-qr-copy"><strong>{btpbText("Apri BTPB")}</strong><span>{btpbText("Inquadra il QR per scegliere la tua squadra")}</span><small>{playerUrl.replace(/^https?:\/\//, '')}</small></div>
      <div className="tv-qr"><img src={qrUrl} alt={`${btpbText("QR code per ")}${playerUrl}`} /></div>
    </footer>
  </main>;
}

function ScreenField({ name, match, bundle, flash }: { name: string; match?: MatchRow; bundle: TournamentBundle; flash: boolean }) {
  if (!match) return <article className="tv-field free"><div className="tv-field-name">{name}</div><div className="tv-free">{btpbText("LIBERO")}</div></article>;
  const countdown = countdownRemaining(match.started_at);
  const remaining = secondsRemaining(match);
  // Sulla TV il countdown 3-2-1 non viene mostrato.
  // Finché la partita non è realmente iniziata, il campo mostra PRONTA.
  let clock = btpbText("PRONTA");
  if (match.status === 'playing' && countdown <= 0) {
    clock = match.duration_seconds == null ? btpbText("IN CORSO") : formatClock(remaining);
  } else if (match.status === 'awaiting_result') {
    clock = match.duration_seconds == null ? btpbText("IN CORSO") : '00:00';
  }

  return <article className={flash ? 'tv-field active new-match' : 'tv-field active'}>
    <div className="tv-field-name">{name}</div>
    <div className="tv-field-teams"><strong><TeamLabel bundle={bundle} teamId={match.team1_id} name={teamName(bundle, match.team1_id)} /></strong><span>VS</span><strong><TeamLabel bundle={bundle} teamId={match.team2_id} name={teamName(bundle, match.team2_id)} /></strong></div>
    <div className="tv-field-clock">{clock}</div>
    {flash && <div className="tv-new-match-label">{btpbText("NUOVA PARTITA")}</div>}
  </article>;
}

function stageLabel(bundle: TournamentBundle, match: MatchRow) {
  if (match.stage === 'group') return bundle.groups.find((group) => group.id === match.group_id)?.name ?? btpbText("Girone");
  if (match.stage === 'final') return btpbText("Finale");
  if (match.stage === 'third_place') return btpbText("3° / 4° posto");
  return btpbText(bundle.knockoutRounds.find((round) => round.id === match.knockout_round_id)?.name ?? "Eliminazione");
}
function queueOrder(a: MatchRow, b: MatchRow) { return (a.queue_position ?? a.sequence_number ?? 999999) - (b.queue_position ?? b.sequence_number ?? 999999); }
function teamName(bundle: TournamentBundle, id: string | null) { return bundle.teams.find((team) => team.id === id)?.name ?? btpbText("Da definire"); }
