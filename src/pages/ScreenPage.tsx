import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from 'react';
import { calculateStandings, type PlayedMatch, type Team as EngineTeam } from '../domain/index.ts';
import { loadTournamentBundleResilient, type MatchRow, type TournamentBundle } from '../lib/api.ts';
import { countdownRemaining, formatClock, secondsRemaining } from '../lib/time.ts';
import { useConnectivity } from '../lib/useConnectivity.ts';
import { navigate } from '../router.ts';
import { KnockoutBracket } from '../components/KnockoutBracket.tsx';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';
import '../tv.css';

const GROUP_ROTATION_MS = 8000;

export function ScreenPage({ slug }: { slug: string }) {
  const [bundle, setBundle] = useState<TournamentBundle | null>(null);
  const [error, setError] = useState('');
  const [cachedAt, setCachedAt] = useState<string | null>(null);
  const [, setTick] = useState(Date.now());
  const [groupPage, setGroupPage] = useState(0);
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
  useEffect(() => {
    if (!online) return;
    const id = window.setInterval(() => void refresh(), 3000);
    return () => window.clearInterval(id);
  }, [refresh, online]);
  useEffect(() => {
    const id = window.setInterval(() => setTick(Date.now()), 250);
    return () => window.clearInterval(id);
  }, []);

  const standings = useMemo(() => bundle ? buildStandings(bundle) : [], [bundle]);
  // Ogni 8 secondi avanziamo di UN girone.
  // Anche con due gironi: A/B -> B/A, così la rotazione è visibile.
  const groupPageCount = Math.max(1, standings.length);

  useEffect(() => {
    if (groupPageCount <= 1) { setGroupPage(0); return; }
    const id = window.setInterval(() => setGroupPage((page) => (page + 1) % groupPageCount), GROUP_ROTATION_MS);
    return () => window.clearInterval(id);
  }, [groupPageCount]);

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

  if (!bundle) return <main className="screen-mode tv-v2"><header className="tv-header"><h1>{error || 'Caricamento…'}</h1><button className="screen-exit" onClick={() => navigate('/')}>Esci</button></header></main>;

  const activeFields = bundle.fields.filter((field) => field.is_active).sort((a,b) => a.sort_order - b.sort_order);
  const live = bundle.matches.filter((m) => ['called','ready','playing','awaiting_result'].includes(m.status));
  const byField = new Map(live.filter((m) => m.field_id).map((m) => [m.field_id!, m]));
  const queue = bundle.matches.filter((m) => m.status === 'queued').sort(queueOrder).slice(0, 10);
  const prepare = queue[0];
  const restQueue = queue.slice(1);
  const nextListStyle = { '--tv-next-count': String(Math.max(restQueue.length, 1)) } as CSSProperties;
  const leftGroup = standings.length ? standings[groupPage % standings.length] : undefined;
  const rightGroup = standings.length > 1 ? standings[(groupPage + 1) % standings.length] : undefined;
  const playerUrl = `${window.location.origin}/tournament/${bundle.tournament.slug}`;
  const qrUrl = `https://quickchart.io/qr?text=${encodeURIComponent(playerUrl)}&size=180&margin=1&ecLevel=M`;
  const fieldColumns = activeFields.length <= 4 ? Math.max(activeFields.length, 1) : Math.ceil(activeFields.length / 2);
  const fieldStyle = { '--tv-field-cols': String(fieldColumns) } as CSSProperties;

  const queuePanel = <div className="tv-queue-panel">
    <div className="tv-section-title"><span>PROSSIME PARTITE</span><strong>{queue.length ? `${queue.length} IN CODA` : 'NESSUNA IN CODA'}</strong></div>
    {prepare ? <div className={prepareFlash ? 'tv-prepare flash' : 'tv-prepare'}>
      <div className="tv-prepare-label">PREPARATEVI</div>
      <div className="tv-prepare-stage">{stageLabel(bundle, prepare)}</div>
      <div className="tv-prepare-match"><strong>{teamName(bundle, prepare.team1_id)}</strong><span>VS</span><strong>{teamName(bundle, prepare.team2_id)}</strong></div>
    </div> : <div className="tv-empty-queue">Nessuna partita in coda</div>}

    <div className="tv-next-list" style={nextListStyle}>
      {restQueue.map((match, index) => <div className="tv-next-row" key={match.id}>
        <span>{index + 2}</span>
        <div><small>{stageLabel(bundle, match)}</small><strong>{teamName(bundle, match.team1_id)} <em>vs</em> {teamName(bundle, match.team2_id)}</strong></div>
      </div>)}
    </div>
  </div>;

  return <main className="screen-mode tv-v2">
    {bundle.settings.emergency_paused && <div className="tv-tournament-pause"><div><span>Ⅱ</span><strong>TORNEO IN PAUSA</strong><p>Attendere indicazioni dell'organizzazione</p></div></div>}
    <ConnectionBanner online={online} cachedAt={cachedAt} />

    <header className="tv-header">
      <div className="tv-brand-block">
        <div className="tv-live-pill"><span /> BTPB LIVE</div>
        <div><h1>{bundle.tournament.name}</h1><small>Baby ti porto al biliardino</small></div>
      </div>
      <button className="screen-exit" onClick={() => navigate('/')}>Esci</button>
    </header>

    {error && <div className="alert error">{error}</div>}

    <section className="tv-fields" style={fieldStyle}>
      {activeFields.map((field) => <ScreenField key={field.id} name={field.name} match={byField.get(field.id)} bundle={bundle} flash={flashingFields.has(field.id)} />)}
    </section>

    {bundle.tournament.phase === 'groups' ? <section className="tv-middle tv-middle-groups">
      <StandingPanel group={leftGroup} page={groupPage} pageCount={groupPageCount} side="left" />
      {queuePanel}
      <StandingPanel group={rightGroup} page={groupPage} pageCount={groupPageCount} side="right" />
    </section> : <section className="tv-middle tv-middle-knockout">
      {queuePanel}
      <div className="tv-bracket-panel">
        <div className="tv-section-title"><span>TABELLONE</span><strong>ELIMINAZIONE DIRETTA</strong></div>
        <KnockoutBracket bundle={bundle} compact />
      </div>
    </section>}

    <footer className="tv-footer">
      <div className="tv-footer-brand"><img src="/brand/btpb-logo.png" alt="BTPB" /><div><strong>BTPB</strong><span>Segui il torneo dal telefono</span></div></div>
      <div className="tv-qr-copy"><strong>Apri BTPB</strong><span>Inquadra il QR per scegliere la tua squadra</span><small>{playerUrl.replace(/^https?:\/\//, '')}</small></div>
      <div className="tv-qr"><img src={qrUrl} alt={`QR code per ${playerUrl}`} /></div>
    </footer>
  </main>;
}

function StandingPanel({ group, page, pageCount, side }: { group: ReturnType<typeof buildStandings>[number] | undefined; page: number; pageCount: number; side: 'left' | 'right' }) {
  return <div className={`tv-standing-side tv-standing-${side}`}>
    <div className="tv-section-title"><span>CLASSIFICA</span><strong>{pageCount > 1 ? 'CAMBIO OGNI 8 S' : 'LIVE'}</strong></div>
    {group ? <>
      <h2>{group.name}</h2>
      <div className="tv-standing-head"><span>#</span><span>Squadra</span><span>PT</span><span>DR</span></div>
      <div className="tv-standing-body">
        {group.rows.map((row, index) => <div className="tv-standing-row" key={row.teamId}>
          <span>{index + 1}</span><strong>{row.teamName}</strong><span>{row.points}</span><span>{row.goalDifference > 0 ? '+' : ''}{row.goalDifference}</span>
        </div>)}
      </div>
      {pageCount > 1 && <div className="tv-page-dots">{Array.from({ length: pageCount }, (_, i) => <span className={i === page ? 'active' : ''} key={i} />)}</div>}
    </> : <div className="tv-empty-standing">In attesa del girone</div>}
  </div>;
}

function ScreenField({ name, match, bundle, flash }: { name: string; match?: MatchRow; bundle: TournamentBundle; flash: boolean }) {
  if (!match) return <article className="tv-field free"><div className="tv-field-name">{name}</div><div className="tv-free">LIBERO</div></article>;
  const countdown = countdownRemaining(match.started_at);
  const remaining = secondsRemaining(match);
  // Sulla TV il countdown 3-2-1 non viene mostrato.
  // Finché la partita non è realmente iniziata, il campo mostra PRONTA.
  let clock = 'PRONTA';
  if (match.status === 'playing' && countdown <= 0) {
    clock = match.duration_seconds == null ? 'IN CORSO' : formatClock(remaining);
  } else if (match.status === 'awaiting_result') {
    clock = match.duration_seconds == null ? 'IN CORSO' : '00:00';
  }

  return <article className={flash ? 'tv-field active new-match' : 'tv-field active'}>
    <div className="tv-field-name">{name}</div>
    <div className="tv-field-teams"><strong>{teamName(bundle, match.team1_id)}</strong><span>VS</span><strong>{teamName(bundle, match.team2_id)}</strong></div>
    <div className="tv-field-clock">{clock}</div>
    {flash && <div className="tv-new-match-label">NUOVA PARTITA</div>}
  </article>;
}

function buildStandings(bundle: TournamentBundle) {
  return bundle.groups.map((group) => {
    const members = bundle.groupTeams.filter((gt) => gt.group_id === group.id);
    const teams: EngineTeam[] = members.map((gt) => ({ id: gt.team_id, name: teamName(bundle, gt.team_id), lotOrder: gt.lot_order }));
    const played: PlayedMatch[] = bundle.matches.filter((m) => m.group_id === group.id && ['finished','forfeit'].includes(m.status) && m.team1_id && m.team2_id && m.score_team1 != null && m.score_team2 != null).map((m) => ({
      id: m.id, groupId: group.id, team1Id: m.team1_id!, team2Id: m.team2_id!, scoreTeam1: m.score_team1!, scoreTeam2: m.score_team2!,
    }));
    return { id: group.id, name: group.name, rows: calculateStandings(teams, played) };
  });
}

function stageLabel(bundle: TournamentBundle, match: MatchRow) {
  if (match.stage === 'group') return bundle.groups.find((group) => group.id === match.group_id)?.name ?? 'Girone';
  if (match.stage === 'final') return 'Finale';
  if (match.stage === 'third_place') return '3° / 4° posto';
  return bundle.knockoutRounds.find((round) => round.id === match.knockout_round_id)?.name ?? 'Eliminazione';
}
function queueOrder(a: MatchRow, b: MatchRow) { return (a.queue_position ?? a.sequence_number ?? 999999) - (b.queue_position ?? b.sequence_number ?? 999999); }
function teamName(bundle: TournamentBundle, id: string | null) { return bundle.teams.find((team) => team.id === id)?.name ?? 'Da definire'; }
