import { btpbText, useBtpbUiLanguage, btpbError } from '../lib/btpbUiText.ts';
import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { matchesAheadForTeam } from '../domain/index.ts';
import { rankSnapshotGroup } from '../domain/snapshotStandings.ts';
import {
  claimTeam,
  endMatchEarly,
  getMyTeamAssignment,
  leaveTeam,
  loadTournamentBundleResilient,
  markTimerExpired,
  pauseMatch,
  resumeMatch,
  startMatch,
  submitMatchResult,
  type MatchRow,
  type TournamentBundle,
} from '../lib/api.ts';
import { countdownRemaining, formatClock, secondsRemaining } from '../lib/time.ts';
import { enableNotifications, getNotificationState, type NotificationState } from '../lib/notifications.ts';
import { usePwaInstall } from '../lib/pwaInstall.ts';
import { navigate } from '../router.ts';
import { KnockoutBracket } from '../components/KnockoutBracket.tsx';
import { useConnectivity } from '../lib/useConnectivity.ts';
import { useTournamentPolling } from '../lib/useTournamentPolling.ts';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';
import { TeamLabel } from '../components/TeamLabel.tsx';
import { LanguagePreferenceRow } from '../components/LanguageSwitch.tsx';
import { playBtpbCountdownBeep, playBtpbTimerEndAlarm, primeBtpbAlertSound, unlockBtpbGameAudio } from '../lib/alertSound.ts';

interface Props { slug: string; matchId?: string; }

type Tab = 'home' | 'gironi' | 'partite' | 'tabellone' | 'squadra';
const LAST_PLAYER_TOURNAMENT_KEY = 'btpb:last-player-tournament';

export function PlayerPage({ slug, matchId }: Props) {
  useBtpbUiLanguage();
  if (matchId) return <MatchPage slug={slug} matchId={matchId} />;
  return <TournamentPlayerPage slug={slug} />;
}

function TournamentPlayerPage({ slug }: { slug: string }) {
  const [bundle, setBundle] = useState<TournamentBundle | null>(null);
  const [teamId, setTeamId] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>('home');
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [cachedAt, setCachedAt] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const result = await loadTournamentBundleResilient(slug);
      const next = result.bundle;
      const assignment = await getMyTeamAssignment(next.tournament.id);
      setBundle(next);
      setTeamId(assignment);
      if (assignment) window.localStorage.setItem(LAST_PLAYER_TOURNAMENT_KEY, next.tournament.slug);
      setCachedAt(result.source === 'cache' ? result.cachedAt : null);
      setError('');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [slug]);

  const online = useConnectivity(() => void refresh());

  useEffect(() => { void refresh(); }, [refresh]);
  useTournamentPolling(refresh, online, 15000);

  if (loading) return <CenteredMessage title={btpbText("Caricamento torneo…")} />;
  if (error || !bundle) return <CenteredMessage title={btpbText("Non riesco ad aprire il torneo")} body={btpbError(error)} back />;
  if (!teamId) return <><ConnectionBanner online={online} cachedAt={cachedAt} /><TeamChooser bundle={bundle} onChosen={refresh} />{bundle.settings.emergency_paused && <TournamentPausedOverlay />}</>;

  const team = bundle.teams.find((t) => t.id === teamId);
  if (!team) return <CenteredMessage title={btpbText("Squadra non trovata")} body={btpbText("Cambia associazione del dispositivo.")} back />;

  return (
    <main className="app-shell">
      {bundle.settings.emergency_paused && <TournamentPausedOverlay />}
      <header className="app-header">
        <button className="icon-button" aria-label={btpbText("Cambia torneo")} onClick={() => { window.localStorage.removeItem(LAST_PLAYER_TOURNAMENT_KEY); navigate('/?choose=1'); }}>←</button>
        <div><strong>Baby Ti Porto al Biliardino</strong><span>{bundle.tournament.name}</span></div>
        <div className={online && !cachedAt ? 'status-dot' : 'status-dot offline'} title={online && !cachedAt ? 'online' : btpbText("dati non aggiornati")} />
      </header>

      <section className="content">
        <ConnectionBanner online={online} cachedAt={cachedAt} />
        {tab === 'home' && <PlayerHome bundle={bundle} teamId={teamId} />}
        {tab === 'gironi' && <GroupsView bundle={bundle} highlightTeamId={teamId} />}
        {tab === 'partite' && <AllMatchesView bundle={bundle} />}
        {tab === 'tabellone' && <section className="panel bracket-player-panel"><div className="panel-title"><h2>{btpbText("Tabellone")}</h2><span>{bundle.tournament.phase === 'groups' ? btpbText("dopo i gironi") : btpbText("eliminazione diretta")}</span></div><KnockoutBracket bundle={bundle} /></section>}
        {tab === 'squadra' && <MyTeam bundle={bundle} teamId={teamId} onChanged={refresh} />}
      </section>

      <nav className="bottom-nav">
        <Nav active={tab === 'home'} onClick={() => setTab('home')} label="Home" icon="⌂" />
        <Nav active={tab === 'gironi'} onClick={() => setTab('gironi')} label={btpbText("Gironi")} icon="≡" />
        <Nav active={tab === 'partite'} onClick={() => setTab('partite')} label={btpbText("Partite")} icon="◫" />
        <Nav active={tab === 'tabellone'} onClick={() => setTab('tabellone')} label={btpbText("Tabellone")} icon="◇" />
        <Nav active={tab === 'squadra'} onClick={() => setTab('squadra')} label={btpbText("Squadra")} icon="●" />
      </nav>
    </main>
  );
}

function normalizeTeamSearch(value: string) {
  return value
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .trimStart()
    .toLocaleLowerCase('it');
}

function SearchableTeamPicker({
  teams,
  selectedId,
  onSelect,
  placeholder = btpbText("Scrivi il nome della squadra"),
}: {
  teams: TournamentBundle['teams'];
  selectedId: string;
  onSelect: (teamId: string) => void;
  placeholder?: string;
}) {
  const activeTeams = useMemo(
    () => teams.filter((team) => team.status === 'active').sort((a, b) => a.name.localeCompare(b.name, 'it')),
    [teams],
  );
  const selectedTeam = activeTeams.find((team) => team.id === selectedId);
  const [query, setQuery] = useState(selectedTeam?.name ?? '');
  const [open, setOpen] = useState(true);
  const [activeIndex, setActiveIndex] = useState(0);

  useEffect(() => {
    const current = activeTeams.find((team) => team.id === selectedId);
    if (current && query !== current.name) setQuery(current.name);
    if (!selectedId && activeTeams.every((team) => team.name !== query)) return;
  }, [activeTeams, selectedId]);

  const normalizedQuery = normalizeTeamSearch(query);
  const suggestions = activeTeams.filter((team) => {
    if (!normalizedQuery) return true;
    return normalizeTeamSearch(team.name).startsWith(normalizedQuery);
  });

  useEffect(() => { setActiveIndex(0); }, [query]);

  function selectTeam(teamId: string) {
    const team = activeTeams.find((candidate) => candidate.id === teamId);
    if (!team) return;
    onSelect(team.id);
    setQuery(team.name);
    setOpen(false);
  }

  function handleChange(value: string) {
    setQuery(value);
    setOpen(true);
    const exact = activeTeams.find((team) => normalizeTeamSearch(team.name) === normalizeTeamSearch(value));
    onSelect(exact?.id ?? '');
  }

  function handleKeyDown(event: KeyboardEvent<HTMLInputElement>) {
    if (!open && (event.key === 'ArrowDown' || event.key === 'ArrowUp')) {
      setOpen(true);
      return;
    }
    if (!suggestions.length) return;
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      setActiveIndex((index) => Math.min(index + 1, suggestions.length - 1));
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      setActiveIndex((index) => Math.max(index - 1, 0));
    } else if (event.key === 'Enter' && open) {
      event.preventDefault();
      selectTeam(suggestions[activeIndex].id);
    } else if (event.key === 'Escape') {
      setOpen(false);
    }
  }

  return <div className="team-search">
    <input
      value={query}
      placeholder={placeholder}
      autoComplete="off"
      spellCheck={false}
      onFocus={() => setOpen(true)}
      onBlur={() => window.setTimeout(() => setOpen(false), 100)}
      onChange={(event) => handleChange(event.target.value)}
      onKeyDown={handleKeyDown}
      aria-autocomplete="list"
      aria-expanded={open}
    />
    {open && <div className="team-search-results" role="listbox">
      {suggestions.length > 0 ? suggestions.map((team, index) => <button
        type="button"
        key={team.id}
        className={index === activeIndex ? 'team-search-option active' : 'team-search-option'}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => selectTeam(team.id)}
        role="option"
        aria-selected={team.id === selectedId}
      >
        <span className="team-search-option-name">{team.avatar_url && <img src={team.avatar_url} alt="" />}<span>{team.name}</span></span>
        {team.id === selectedId && <strong>✓</strong>}
      </button>) : <div className="team-search-empty">{btpbText("Nessuna squadra trovata")}</div>}
    </div>}
  </div>;
}

function TeamChooser({ bundle, onChosen }: { bundle: TournamentBundle; onChosen: () => Promise<void> }) {
  const online = useConnectivity();
  const [selected, setSelected] = useState('');
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function choose() {
    if (!selected) return;
    setBusy(true); setError('');
    try {
      await claimTeam(selected, bundle.settings.team_pin_enabled ? pin : undefined);
      await onChosen();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally { setBusy(false); }
  }

  return <main className="page page-centered"><section className="login-card team-chooser">
    <button className="text-button" onClick={() => navigate('/')}>{btpbText("← Tornei")}</button>
    <div className="eyebrow">{bundle.tournament.name}</div><h1>{btpbText("Qual è la tua squadra?")}</h1>
    <p className="lead small">{btpbText("Scrivi il nome della squadra oppure sceglila dai suggerimenti. All'inizio vengono mostrate tutte le squadre disponibili.")}</p>
    <label>{btpbText("Squadra")}</label>
    <SearchableTeamPicker teams={bundle.teams.filter((team) => bundle.groupTeams.some((membership) => membership.team_id === team.id))} selectedId={selected} onSelect={(teamId) => { setSelected(teamId); setPin(''); }} />
    {bundle.settings.team_pin_enabled && selected && <><label>{btpbText("PIN squadra")}</label><input inputMode="numeric" value={pin} onChange={(e) => setPin(e.target.value)} placeholder="PIN" /></>}
    {error && <div className="alert error">{btpbError(error)}</div>}
    {!online && <div className="alert warning">{btpbText("Per associare questo dispositivo a una squadra serve la connessione.")}</div>}
    <button className="button primary" disabled={busy || !selected || !online} onClick={() => void choose()}>{busy ? btpbText("Associazione…") : btpbText("Questa è la mia squadra")}</button>
  </section></main>;
}

function PlayerHome({ bundle, teamId }: { bundle: TournamentBundle; teamId: string }) {
  const team = bundle.teams.find((t) => t.id === teamId)!;
  const ownMatches = bundle.matches.filter((m) => [m.team1_id, m.team2_id].includes(teamId) && m.status !== 'cancelled');
  const activeFieldCount = bundle.fields.filter((field) => field.is_active).length;
  const playedCount = ownMatches.filter((m) => ['finished','forfeit'].includes(m.status)).length;
  const remainingCount = ownMatches.filter((m) => !['finished','forfeit','cancelled'].includes(m.status)).length;

  const membership = bundle.groupTeams.find((gt) => gt.team_id === teamId);
  let points = 0;
  let position: number | null = null;
  let groupName = '';
  if (membership) {
    const group = bundle.groups.find((g) => g.id === membership.group_id);
    groupName = group?.name ?? '';
    const standings = rankSnapshotGroup(bundle, membership.group_id);
    // Retired teams retain their historical points, but no qualification position.
    points = bundle.standings.find(r => r.group_id === membership.group_id && r.team_id === teamId)?.points ?? 0;
    const rowIndex = standings.findIndex((row) => row.teamId === teamId);
    if (rowIndex >= 0) {
      position = rowIndex + 1;
      points = standings[rowIndex].points;
    }
  }

  const live = ownMatches.filter((m) => ['called', 'ready', 'playing', 'awaiting_result'].includes(m.status)).sort(matchOrder)[0];
  const queued = ownMatches.filter((m) => m.status === 'queued').sort(matchOrder)[0];
  const next = live ?? queued;
  const allQueued = bundle.matches.filter((m) => m.status === 'queued' && m.team1_id && m.team2_id).map((m) => ({
    id: m.id, team1Id: m.team1_id!, team2Id: m.team2_id!, queuePosition: m.queue_position ?? 999999,
  }));
  const ahead = live ? 0 : (matchesAheadForTeam(allQueued, teamId) ?? 0);
  const past = ownMatches.filter((m) => ['finished','forfeit'].includes(m.status)).sort((a,b) => (Date.parse(b.ended_at ?? '') || 0) - (Date.parse(a.ended_at ?? '') || 0) || matchOrder(b,a));
  const future = ownMatches.filter((m) => !['finished','forfeit','cancelled'].includes(m.status)).sort(matchOrder);
  const ownTimeline = [...past, ...future];

  let nextCard: ReactNode;
  if (!next) {
    nextCard = <section className="next-card"><div className="eyebrow">{btpbText("PROSSIMA PARTITA")}</div><h2>{btpbText("Nessuna partita in coda")}</h2><p className="muted-on-dark">{btpbText("Il calendario potrebbe essere concluso o non ancora avviato.")}</p></section>;
  } else {
    const opponentId = next.team1_id === teamId ? next.team2_id : next.team1_id;
    const opponent = teamName(bundle, opponentId);
    const field = bundle.fields.find((f) => f.id === next.field_id)?.name;
    const liveNow = ['called', 'ready', 'playing', 'awaiting_result'].includes(next.status);
    nextCard = <section className={liveNow ? 'next-card urgent' : 'next-card'} onClick={() => liveNow && navigate(`/tournament/${bundle.tournament.slug}/match/${next.id}`)} role={liveNow ? 'button' : undefined}>
      <div className="eyebrow">{liveNow ? btpbText("È IL VOSTRO TURNO") : btpbText("PROSSIMA PARTITA")}</div>
      <div className="versus"><strong><TeamLabel bundle={bundle} teamId={teamId} name={team.name} /></strong><span>VS</span><strong><TeamLabel bundle={bundle} teamId={opponentId} name={opponent} /></strong></div>
      <div className={liveNow ? 'ahead-hero live-turn' : 'ahead-hero'}>{!liveNow && ahead > 0 && <small className="ahead-queue-label">{btpbText("CODA")}</small>}<strong>{liveNow ? btpbText("TOCCA A VOI") : ahead === 0 ? btpbText("PROSSIMI") : ahead}</strong><span>{liveNow ? (field ? `${btpbText("VAI AL ")}${field.toUpperCase()}` : btpbText("CAMPO DA ASSEGNARE")) : ahead === 0 ? btpbText("SIETE I PROSSIMI") : `${ahead === 1 ? btpbText("PARTITA") : btpbText("PARTITE")}${btpbText(" PRIMA DI VOI")}`}</span>{!liveNow && <small className="ahead-fields-note">{btpbText("Considera che ci sono ")}{activeFieldCount} {activeFieldCount === 1 ? btpbText("campo") : btpbText("campi")}</small>}</div>
      {!liveNow && <div className="next-field">{field ?? btpbText("Campo da assegnare")}</div>}
      {liveNow && <div className="tap-hint">{btpbText("INIZIA PARTITA →")}</div>}
    </section>;
  }

  return <>
    <section className="team-hero"><span>{btpbText("LA TUA SQUADRA")}</span><h1><TeamLabel bundle={bundle} teamId={teamId} name={team.name} /></h1>{groupName && <div><small>{groupName}</small></div>}</section>
    {nextCard}
    <section className="player-stats"><div><strong>{playedCount}</strong><span>{btpbText("Giocate")}</span></div><div><strong>{remainingCount}</strong><span>{btpbText("Da giocare")}</span></div><div><strong>{points}</strong><span>{btpbText("Punti")}</span></div><div><strong>{position ? `#${position}` : '–'}</strong><span>{btpbText("Posizione")}</span></div></section>
    <NotificationControls tournamentId={bundle.tournament.id} />
    <section className="panel player-own-matches"><div className="panel-title"><h2>{btpbText("Le tue partite")}</h2><span>{ownTimeline.length}</span></div><div className="player-match-list">{ownTimeline.length === 0 && <div className="empty-state">{btpbText("Nessuna partita ancora programmata.")}</div>}{ownTimeline.map((m) => <PlayerMatchListRow key={m.id} bundle={bundle} match={m} />)}</div></section>
  </>;
}

function PlayerMatchListRow({ bundle, match }: { bundle: TournamentBundle; match: MatchRow }) {
  const finished = ['finished','forfeit'].includes(match.status);
  const a = teamName(bundle, match.team1_id), b = teamName(bundle, match.team2_id);
  return <div className="player-match-row"><div><span>{matchStageLabel(bundle, match)}</span><small>{statusLabel(match.status)}</small></div><strong><TeamLabel bundle={bundle} teamId={match.team1_id} name={a} /></strong><div className={finished ? 'player-score' : 'player-versus'}>{finished ? `${match.score_team1 ?? 0} – ${match.score_team2 ?? 0}` : 'VS'}</div><strong><TeamLabel bundle={bundle} teamId={match.team2_id} name={b} /></strong></div>;
}

function NotificationControls({ tournamentId }: { tournamentId: string }) {
  const [state, setState] = useState<NotificationState>('default');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const pwa = usePwaInstall();

  const refreshState = useCallback(async () => {
    try { setState(await getNotificationState()); }
    catch { setState('unsupported'); }
  }, []);

  useEffect(() => { void refreshState(); }, [refreshState, pwa.installed]);

  async function enable() {
    setBusy(true); setError('');
    try { await enableNotifications(tournamentId); await refreshState(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }


  if (state === 'enabled') return null;

  return <section className="notice-card notification-card">
    <div><strong>{btpbText("Avvisi 🔔")}</strong>
      {state === 'default' && <span>{btpbText("Attiva gli avvisi per sapere quando manca una partita e quando dovete andare al campo.")}</span>}
      {state === 'disabled' && <span>{btpbText("Le notifiche sono consentite, ma questo dispositivo non è più registrato.")}</span>}
      {state === 'denied' && <span>{btpbText("Le notifiche sono bloccate nelle impostazioni del browser/dispositivo.")}</span>}
      {state === 'needs-install' && <span>{btpbText("Su iPhone/iPad installa prima la web app sulla schermata Home, poi aprila dall’icona.")}</span>}
      {state === 'unsupported' && <span>{btpbText("Questo browser non supporta le notifiche push web.")}</span>}
    </div>
    <div className="notification-actions">
      {pwa.canPromptInstall && <button className="button secondary" disabled={busy} onClick={() => void pwa.install()}>{btpbText("Installa app")}</button>}
      {pwa.needsIOSManualInstall && state === 'needs-install' && <span className="ios-install-hint">{btpbText("Condividi ↑ → Aggiungi alla schermata Home")}</span>}
      {(state === 'default' || state === 'disabled') && <button className="button primary" disabled={busy} onClick={() => void enable()}>{busy ? btpbText("Attivazione…") : btpbText("Attiva notifiche")}</button>}
    </div>
    {error && <div className="alert error">{btpbError(error)}</div>}
  </section>;
}

function GroupsView({ bundle, highlightTeamId }: { bundle: TournamentBundle; highlightTeamId?: string }) {
  const [openGroupId, setOpenGroupId] = useState<string | null>(null);
  return <div className="group-stack">{bundle.groups.map((group) => {
    const groupMatches = bundle.matches.filter((m) => m.group_id === group.id && m.stage === 'group' && m.status !== 'cancelled');
    const rows = rankSnapshotGroup(bundle, group.id);
    const open = openGroupId === group.id;
    return <section className="panel group-card-v2" key={group.id}>
      <button className="group-card-heading" onClick={() => setOpenGroupId(open ? null : group.id)}><div><h2>{group.name}</h2><span>{rows.length}{btpbText(" squadre")}</span></div><strong>{open ? '−' : '+'}</strong></button>
      <div className="group-table-scroll"><div className="group-table-wide"><div className="group-wide-row header"><span>#</span><strong>{btpbText("Squadra")}</strong><span>{btpbText("PT")}</span><span>G</span><span>{btpbText("Da giocare")}</span><span>{btpbText("DR")}</span></div>{rows.map((r,i) => { const toPlay = groupMatches.filter((m) => [m.team1_id,m.team2_id].includes(r.teamId) && !['finished','forfeit','cancelled'].includes(m.status)).length; return <div className={r.teamId === highlightTeamId ? 'group-wide-row highlighted' : 'group-wide-row'} key={r.teamId}><span>{i+1}</span><strong><TeamLabel bundle={bundle} teamId={r.teamId} name={r.teamName} /></strong><span>{r.points}</span><span>{r.played}</span><span>{toPlay}</span><span>{signed(r.goalDifference)}</span></div>; })}</div></div>
      {open && <div className="group-match-detail"><h3>{btpbText("Tutte le partite")}</h3>{groupMatches.slice().sort(matchOrder).map((m) => <PlayerMatchListRow key={m.id} bundle={bundle} match={m} />)}</div>}
    </section>;
  })}</div>;
}

function AllMatchesView({ bundle }: { bundle: TournamentBundle }) {
  const [mode, setMode] = useState<'past'|'future'>('future');
  const [query, setQuery] = useState('');
  const [, setFieldTick] = useState(Date.now());
  const liveStatuses: MatchRow['status'][] = ['called','ready','playing','awaiting_result'];

  useEffect(() => {
    const id = window.setInterval(() => setFieldTick(Date.now()), 250);
    return () => window.clearInterval(id);
  }, []);

  function liveFieldClock(match: MatchRow) {
    if (match.status === 'called' || match.status === 'ready') return btpbText("PRONTA");

    if (match.status === 'playing') {
      const countdown = countdownRemaining(match.started_at);
      if (countdown > 0) return btpbText("PRONTA");
      if (match.duration_seconds == null) return btpbText("IN CORSO");
      return formatClock(secondsRemaining(match));
    }

    if (match.status === 'awaiting_result') {
      return match.duration_seconds == null ? btpbText("IN CORSO") : '00:00';
    }

    return '';
  }
  const activeFields = bundle.fields.filter((f) => f.is_active).sort((a,b) => a.sort_order-b.sort_order);
  const normalized = normalizeTextSearch(query);
  const past = bundle.matches.filter((m) => ['finished','forfeit'].includes(m.status)).sort((a,b) => (Date.parse(b.ended_at ?? '') || 0) - (Date.parse(a.ended_at ?? '') || 0) || matchOrder(b,a));
  const future = bundle.matches.filter((m) => !['finished','forfeit','cancelled'].includes(m.status)).sort(matchOrder);
  const source = mode === 'past' ? past : future;
  const filtered = source.filter((m) => !normalized || normalizeTextSearch(`${teamName(bundle,m.team1_id)} ${teamName(bundle,m.team2_id)} ${matchStageLabel(bundle,m)}`).includes(normalized));
  return <div className="matches-page-v2">
    <section className="live-fields-section"><div className="section-heading-v2"><div><span>LIVE</span><h2>{btpbText("Campi")}</h2></div><small>{activeFields.length}{btpbText(" attivi")}</small></div><div className="player-live-fields">{activeFields.map((field) => { const match = bundle.matches.find((m) => m.field_id === field.id && liveStatuses.includes(m.status)); return <article className={match ? 'player-live-field active' : 'player-live-field'} key={field.id}><span>{field.name}</span>{match ? <><div className="player-live-field-teams"><strong><TeamLabel bundle={bundle} teamId={match.team1_id} /></strong><small>VS</small><strong><TeamLabel bundle={bundle} teamId={match.team2_id} /></strong></div><div className="player-live-field-clock">{liveFieldClock(match)}</div></> : <div className="field-free-player">{btpbText("LIBERO")}</div>}</article>; })}</div></section>
    <section className="panel all-matches-panel"><div className="matches-toolbar"><div className="segmented-control"><button className={mode === 'past' ? 'active' : ''} onClick={() => setMode('past')}>{btpbText("Passate")}</button><button className={mode === 'future' ? 'active' : ''} onClick={() => setMode('future')}>{btpbText("Future")}</button></div><div className="match-search"><span>⌕</span><input value={query} onChange={(e) => setQuery(e.target.value)} placeholder={btpbText("Cerca squadra o girone")} /></div></div><div className="player-match-list global">{filtered.length === 0 && <div className="empty-state">{btpbText("Nessuna partita trovata.")}</div>}{filtered.map((m) => <PlayerMatchListRow key={m.id} bundle={bundle} match={m} />)}</div></section>
  </div>;
}

function MyTeam({ bundle, teamId, onChanged }: { bundle: TournamentBundle; teamId: string; onChanged: () => Promise<void> }) {
  const online = useConnectivity();
  const [newTeamId, setNewTeamId] = useState(teamId);
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [teamChangeSuccess, setTeamChangeSuccess] = useState<string | null>(null);
  const currentTeam = teamName(bundle, teamId);
  async function change() {
    if (!newTeamId || newTeamId === teamId) return;
    const nextTeamName = teamName(bundle, newTeamId);
    setBusy(true); setError('');
    try {
      await claimTeam(newTeamId, bundle.settings.team_pin_enabled ? pin : undefined);
      window.localStorage.setItem(LAST_PLAYER_TOURNAMENT_KEY, bundle.tournament.slug);
      await onChanged();
      setTeamChangeSuccess(nextTeamName);
    }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }
  async function remove() {
    setBusy(true);
    try { await leaveTeam(bundle.tournament.id); window.localStorage.removeItem(LAST_PLAYER_TOURNAMENT_KEY); await onChanged(); }
    finally { setBusy(false); }
  }
  return <section className="panel form-panel my-team-v2"><div className="eyebrow">{btpbText("SQUADRA ASSOCIATA")}</div><h2><TeamLabel bundle={bundle} teamId={teamId} name={currentTeam} /></h2><p className="hint">{btpbText("Per cambiare squadra cercane un'altra qui sotto e conferma.")}</p><label>{btpbText("Nuova squadra")}</label><SearchableTeamPicker teams={bundle.teams.filter((team) => bundle.groupTeams.some((membership) => membership.team_id === team.id))} selectedId={newTeamId} onSelect={(id) => { setNewTeamId(id); setPin(''); }} placeholder={btpbText("Cerca la nuova squadra")} />{bundle.settings.team_pin_enabled && newTeamId && newTeamId !== teamId && <><label>{btpbText("PIN nuova squadra")}</label><input value={pin} inputMode="numeric" onChange={(e) => setPin(e.target.value)} /></>}{error && <div className="alert error">{btpbError(error)}</div>}<button className="button primary" disabled={busy || !online || !newTeamId || newTeamId === teamId} onClick={() => void change()}>{btpbText("Cambia squadra")}</button><button className="button ghost" disabled={busy || !online} onClick={() => void remove()}>{btpbText("Dissocia questo dispositivo")}</button>{teamChangeSuccess && <div className="team-change-feedback-backdrop">
    <div className="team-change-feedback" role="dialog" aria-modal="true" aria-labelledby="team-change-feedback-title">
      <div className="team-change-feedback-check">✓</div>
      <h3 id="team-change-feedback-title">{btpbText("Squadra cambiata")}</h3>
      <p>{btpbText("Questo telefono ora è associato a ")}<strong>{teamChangeSuccess}</strong>.</p>
      <button className="button primary" autoFocus onClick={() => setTeamChangeSuccess(null)}>OK</button>
    </div>
  </div>}
  <LanguagePreferenceRow /></section>;
}

function MatchPage({ slug, matchId }: { slug: string; matchId: string }) {
  const [bundle, setBundle] = useState<TournamentBundle | null>(null);
  const [teamId, setTeamId] = useState<string | null>(null);
  const [error, setError] = useState('');
  const [cachedAt, setCachedAt] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [tick, setTick] = useState(Date.now());
  const [score1, setScore1] = useState('');
  const [score2, setScore2] = useState('');
  const [confirming, setConfirming] = useState(false);
  const [confirmEnd, setConfirmEnd] = useState(false);
  const [timerEndAlert, setTimerEndAlert] = useState(false);
  const expiring = useRef(false);
  const endFeedbackPlayed = useRef<string | null>(null);
  const endAlertTimeout = useRef<number | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const countdownBeepKey = useRef<string | null>(null);
  const previousTimerState = useRef<{ id: string; status: MatchRow['status']; remaining: number | null } | null>(null);

  const refresh = useCallback(async () => {
    try {
      const result = await loadTournamentBundleResilient(slug);
      const b = result.bundle;
      setBundle(b);
      setTeamId(await getMyTeamAssignment(b.tournament.id));
      setCachedAt(result.source === 'cache' ? result.cachedAt : null);
      setError('');
    } catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  }, [slug]);

  const online = useConnectivity(() => void refresh());


  function unlockMatchAudio() {
    try {
      const AudioContextCtor = window.AudioContext || (window as any).webkitAudioContext;
      if (!AudioContextCtor) return;
      if (!audioContextRef.current) audioContextRef.current = new AudioContextCtor();
      if (audioContextRef.current.state === 'suspended') void audioContextRef.current.resume();
    } catch {
      // Audio is best-effort; visual feedback always remains available.
    }
  }

  function playMatchEndSound() {
    void playBtpbTimerEndAlarm();
  }

  function showSystemEndNotification() {
    if (!('Notification' in window) || Notification.permission !== 'granted' || !('serviceWorker' in navigator)) return;

    void navigator.serviceWorker.ready.then((registration) => registration.showNotification(btpbText("TEMPO FINITO"), {
      body: btpbText("Partita terminata. Inserite il risultato."),
      icon: '/icons/icon-192.png',
      badge: '/icons/badge-96.png',
      tag: `btpb-timer-end-${matchId}`,
      renotify: true,
      silent: false,
      data: { url: `/tournament/${slug}/match/${matchId}` },
    } as NotificationOptions)).catch(() => undefined);
  }

  function fireMatchEndFeedback() {
    setTimerEndAlert(true);
    playMatchEndSound();

    try {
      if ('vibrate' in navigator) navigator.vibrate([350, 120, 350, 120, 650]);
    } catch {
      // Vibration API is not available on every phone/browser.
    }

    if (!('vibrate' in navigator)) showSystemEndNotification();

    if (endAlertTimeout.current) window.clearTimeout(endAlertTimeout.current);
    endAlertTimeout.current = window.setTimeout(() => setTimerEndAlert(false), 6000);
  }

  async function startPlayerMatch(currentMatchId: string) {
    // Real user gesture: unlock both Web Audio and the HTML media fallback.
    void unlockBtpbGameAudio();
    void primeBtpbAlertSound();
    unlockMatchAudio();
    return startMatch(currentMatchId);
  }
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    const unlock = () => unlockMatchAudio();
    window.addEventListener('pointerdown', unlock, { once: true });
    window.addEventListener('touchend', unlock, { once: true });
    return () => {
      window.removeEventListener('pointerdown', unlock);
      window.removeEventListener('touchend', unlock);
      if (endAlertTimeout.current) window.clearTimeout(endAlertTimeout.current);
    };
  }, []);
  useEffect(() => { const id = window.setInterval(() => setTick(Date.now()), 250); return () => window.clearInterval(id); }, []);
  useTournamentPolling(refresh, online, 3000, false);

  const match = bundle?.matches.find((m) => m.id === matchId);
  const remaining = match ? secondsRemaining(match) : null;
  const countdown = match ? countdownRemaining(match.started_at) : 0;

  useEffect(() => {
    if (!match || match.status !== 'playing' || countdown < 1 || countdown > 3) return;

    const key = `${match.id}:${countdown}`;
    if (countdownBeepKey.current === key) return;

    countdownBeepKey.current = key;
    void playBtpbCountdownBeep(countdown);
  }, [match?.id, match?.status, countdown]);


  useEffect(() => {
    void tick;

    if (!match) {
      previousTimerState.current = null;
      return;
    }

    const previous = previousTimerState.current;

    const timerEndedLocally =
      match.status === 'playing' &&
      match.duration_seconds != null &&
      countdown === 0 &&
      remaining != null &&
      remaining <= 0;

    const timerEndedOnServer =
      match.status === 'awaiting_result' &&
      match.duration_seconds != null &&
      match.timer_remaining_seconds === 0 &&
      previous?.id === match.id &&
      previous.status === 'playing';

    if (
      (timerEndedLocally || timerEndedOnServer) &&
      endFeedbackPlayed.current !== match.id
    ) {
      endFeedbackPlayed.current = match.id;
      fireMatchEndFeedback();
    }

    previousTimerState.current = {
      id: match.id,
      status: match.status,
      remaining,
    };

    if (
      !online ||
      bundle?.settings.emergency_paused ||
      !timerEndedLocally ||
      expiring.current
    ) return;

    expiring.current = true;
    markTimerExpired(match.id)
      .then(refresh)
      .catch((e) => setError(e instanceof Error ? e.message : String(e)))
      .finally(() => { expiring.current = false; });
  }, [tick, online, match, remaining, countdown, refresh, bundle?.settings.emergency_paused]);

  if (error && !bundle) return <CenteredMessage title={btpbText("Errore partita")} body={btpbError(error)} back />;
  if (!bundle || !match) return <CenteredMessage title={btpbText("Caricamento partita…")} />;
  if (!teamId || ![match.team1_id, match.team2_id].includes(teamId)) return <CenteredMessage title={btpbText("Questa non è la tua partita")} body={btpbText("Solo i dispositivi associati alle due squadre e l'admin possono controllarla.")} back />;

  const resolvedMatchId = match.id;
  const a = teamName(bundle, match.team1_id), b = teamName(bundle, match.team2_id);
  const field = bundle.fields.find((f) => f.id === match.field_id)?.name ?? btpbText("Campo");

  async function action(fn: () => Promise<unknown>) {
    setBusy(true); setError('');
    try { await fn(); await refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }

  async function openScoreEntryFromEndAlert() {
    const currentMatch = match;
    if (!currentMatch) return;
    if (endAlertTimeout.current) {
      window.clearTimeout(endAlertTimeout.current);
      endAlertTimeout.current = null;
    }

    setTimerEndAlert(false);

    if (currentMatch.status === 'awaiting_result') return;
    if (currentMatch.status !== 'playing') return;

    if (!online) {
      setError('Per passare all’inserimento del punteggio serve la connessione.');
      return;
    }

    setBusy(true);
    setError('');

    try {
      try {
        await markTimerExpired(currentMatch.id);
      } catch {
        // L'altro telefono può aver già completato la transizione.
      }
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  async function submit() {
    const s1 = Number(score1), s2 = Number(score2);
    if (!Number.isInteger(s1) || !Number.isInteger(s2) || s1 < 0 || s2 < 0) { setError('Inserisci due punteggi validi.'); return; }
    await action(() => submitMatchResult(resolvedMatchId, s1, s2));
    setConfirming(false);
  }

  return <main className={timerEndAlert ? 'match-screen match-end-alerting' : 'match-screen'}>
    {bundle.settings.emergency_paused && <TournamentPausedOverlay dark />}
    {timerEndAlert && <div
      className="match-end-flash"
      role="button"
      tabIndex={0}
      aria-label={btpbText("Tempo finito. Tocca per inserire il punteggio.")}
      aria-live="assertive"
      onClick={() => void openScoreEntryFromEndAlert()}
      onKeyDown={(event) => {
        if (event.key === 'Enter' || event.key === ' ') {
          event.preventDefault();
          void openScoreEntryFromEndAlert();
        }
      }}
    >
      <strong>{btpbText("TEMPO FINITO")}</strong>
      <span>{btpbText("PARTITA TERMINATA")}</span>
      <small>{btpbText("TOCCA PER INSERIRE IL PUNTEGGIO")}</small>
    </div>}
    <ConnectionBanner online={online} cachedAt={cachedAt} />
    <header className="match-top"><button className="icon-button light" onClick={() => navigate(`/tournament/${slug}`)}>←</button><div><span>{bundle.tournament.name}</span><strong>{field}</strong></div></header>
    <section className="match-stage">
      <div className="match-team-names"><strong><TeamLabel bundle={bundle} teamId={match.team1_id} name={a} /></strong><span>VS</span><strong><TeamLabel bundle={bundle} teamId={match.team2_id} name={b} /></strong></div>
      {match.status === 'playing' && countdown > 0 && <div className="countdown"><span>{countdown}</span><small>{btpbText("PREPARATEVI")}</small></div>}
      {match.status === 'playing' && countdown === 0 && <><div className="match-clock">{match.duration_seconds == null ? btpbText("IN CORSO") : formatClock(remaining)}</div>{match.goal_target && <div className="target-label">{btpbText("Primo a ")}{match.goal_target}{btpbText(" · oppure fine tempo")}</div>}{!online && remaining === 0 && <div className="offline-match-note">{btpbText("Tempo terminato. Continuate a giocare: appena torna la connessione passeremo automaticamente all'inserimento del risultato.")}</div>}</>}
      {['called','ready'].includes(match.status) && <><div className="waiting-title">{btpbText("Siete sul campo.")}</div><button className="giant-button" disabled={busy || !online} onClick={() => void action(() => startPlayerMatch(match.id))}>{btpbText("AVVIA PARTITA")}</button></>}
      {match.status === 'playing' && countdown === 0 && <div className="match-controls">{match.pause_allowed && (match.paused_at ? <button disabled={busy || !online || confirmEnd} onClick={() => void action(() => resumeMatch(match.id))}>{btpbText("Riprendi")}</button> : <button disabled={busy || !online || confirmEnd} onClick={() => void action(() => pauseMatch(match.id))}>{btpbText("Pausa")}</button>)}<button className="danger-soft" disabled={busy || !online || confirmEnd} onClick={() => setConfirmEnd(true)}>{btpbText("Termina partita")}</button></div>}
      {confirmEnd && match.status === 'playing' && <div className="confirm-result end-match-confirm"><strong>{btpbText("Concludere la partita?")}</strong><p>{btpbText("La partita verrà chiusa e si passerà all’inserimento del risultato.")}</p><div><button disabled={busy} onClick={() => setConfirmEnd(false)}>{btpbText("Continua a giocare")}</button><button className="confirm end-confirm-button" disabled={busy || !online} onClick={() => { setConfirmEnd(false); void action(() => endMatchEarly(match.id)); }}>{btpbText("CONCLUDI PARTITA")}</button></div></div>}
      {match.status === 'awaiting_result' && <section className="score-entry"><div className="eyebrow light-text">{btpbText("PARTITA TERMINATA")}</div>{match.stage !== 'group' && <p>{btpbText("Se eravate pari allo scadere, continuate a giocare il ")}<strong>golden goal</strong>{btpbText(". Poi inserite il risultato finale.")}</p>}<div className="score-inputs"><label><span><TeamLabel bundle={bundle} teamId={match.team1_id} name={a} /></span><input type="number" min="0" inputMode="numeric" value={score1} onChange={(e) => { setScore1(e.target.value); setConfirming(false); }} /></label><strong>–</strong><label><span><TeamLabel bundle={bundle} teamId={match.team2_id} name={b} /></span><input type="number" min="0" inputMode="numeric" value={score2} onChange={(e) => { setScore2(e.target.value); setConfirming(false); }} /></label></div>{!confirming ? <button className="giant-button" disabled={!online} onClick={() => setConfirming(true)}>{btpbText("Controlla risultato")}</button> : <div className="confirm-result"><strong>{btpbText("Confermi ")}{a} {score1 || '0'} – {score2 || '0'} {b}?</strong><p>{btpbText("Dopo la conferma solo l'admin potrà modificarlo.")}</p><div><button onClick={() => setConfirming(false)}>{btpbText("Indietro")}</button><button className="confirm" disabled={busy || !online} onClick={() => void submit()}>{btpbText("CONFERMA")}</button></div></div>}</section>}
      {['finished','forfeit'].includes(match.status) && <section className="finished-result"><div className="eyebrow light-text">{btpbText("RISULTATO REGISTRATO")}</div><div>{match.score_team1} <span>–</span> {match.score_team2}</div><button onClick={() => navigate(`/tournament/${slug}`)}>{btpbText("Torna al torneo")}</button></section>}
      {error && <div className="alert error match-error">{btpbError(error)}</div>}
    </section>
  </main>;
}

function TournamentPausedOverlay({ dark = false }: { dark?: boolean }) {
  return <div className={dark ? 'tournament-paused-overlay dark' : 'tournament-paused-overlay'}>
    <div><span>Ⅱ</span><strong>{btpbText("TORNEO IN PAUSA")}</strong><p>{btpbText("Attendere indicazioni dell'organizzazione.")}</p></div>
  </div>;
}

function Nav({ active, onClick, label, icon }: { active: boolean; onClick: () => void; label: string; icon: string }) { return <button className={active ? 'nav-item active' : 'nav-item'} onClick={onClick}><span>{icon}</span>{label}</button>; }
function CenteredMessage({ title, body, back }: { title: string; body?: string; back?: boolean }) { return <main className="page page-centered"><section className="login-card">{back && <button className="text-button" onClick={() => navigate('/')}>{btpbText("← Indietro")}</button>}<h2>{title}</h2>{body && <p className="lead small">{body}</p>}</section></main>; }
function teamName(bundle: TournamentBundle, id: string | null) { return bundle.teams.find((t) => t.id === id)?.name ?? btpbText("Da definire"); }
function signed(n: number) { return n > 0 ? `+${n}` : String(n); }
function normalizeTextSearch(value: string) { return value.normalize('NFD').replace(/[\u0300-\u036f]/g, '').trim().toLocaleLowerCase('it'); }
function matchStageLabel(bundle: TournamentBundle, match: MatchRow) {
  if (match.stage === 'group') return bundle.groups.find((g) => g.id === match.group_id)?.name ?? btpbText("Girone");
  if (match.stage === 'final') return btpbText("Finale");
  if (match.stage === 'third_place') return btpbText("3° / 4° posto");
  return btpbText(bundle.knockoutRounds.find((r) => r.id === match.knockout_round_id)?.name ?? "Eliminazione");
}
function matchOrder(a: MatchRow, b: MatchRow) { return (a.queue_position ?? a.sequence_number ?? 999999) - (b.queue_position ?? b.sequence_number ?? 999999); }
function statusLabel(status: MatchRow['status']) { const labels: Record<MatchRow['status'], string> = { scheduled:btpbText("PROGRAMMATA"),queued:btpbText("IN CODA"),called:btpbText("TOCCA A VOI"),ready:btpbText("PRONTA"),playing:btpbText("IN CORSO"),awaiting_result:btpbText("RISULTATO"),finished:btpbText("FINITA"),postponed:btpbText("RIMANDATA"),cancelled:btpbText("ANNULLATA"),forfeit:btpbText("TAVOLINO") }; return labels[status]; }
