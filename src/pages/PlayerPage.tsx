import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { calculateStandings, matchesAheadForTeam, type PlayedMatch, type Team as EngineTeam } from '../domain/index.ts';
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
import { disableNotifications, enableNotifications, getNotificationState, type NotificationState } from '../lib/notifications.ts';
import { usePwaInstall } from '../lib/pwaInstall.ts';
import { navigate } from '../router.ts';
import { KnockoutBracket } from '../components/KnockoutBracket.tsx';
import { useConnectivity } from '../lib/useConnectivity.ts';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';

interface Props { slug: string; matchId?: string; }

type Tab = 'home' | 'gironi' | 'tabellone' | 'partite' | 'squadra';

export function PlayerPage({ slug, matchId }: Props) {
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
  useEffect(() => {
    if (!online) return;
    const id = window.setInterval(() => void refresh(), 15000);
    return () => window.clearInterval(id);
  }, [refresh, online]);

  if (loading) return <CenteredMessage title="Caricamento torneo…" />;
  if (error || !bundle) return <CenteredMessage title="Non riesco ad aprire il torneo" body={error} back />;
  if (!teamId) return <><ConnectionBanner online={online} cachedAt={cachedAt} /><TeamChooser bundle={bundle} onChosen={refresh} /></>;

  const team = bundle.teams.find((t) => t.id === teamId);
  if (!team) return <CenteredMessage title="Squadra non trovata" body="Cambia associazione del dispositivo." back />;

  return (
    <main className="app-shell">
      <header className="app-header">
        <button className="icon-button" onClick={() => navigate('/')}>←</button>
        <div><strong>{bundle.tournament.name}</strong><span>Baby ti porto al biliardino</span></div>
        <div className={online && !cachedAt ? 'status-dot' : 'status-dot offline'} title={online && !cachedAt ? 'online' : 'dati non aggiornati'} />
      </header>

      <section className="content">
        <ConnectionBanner online={online} cachedAt={cachedAt} />
        {tab === 'home' && <PlayerHome bundle={bundle} teamId={teamId} onRefresh={refresh} />}
        {tab === 'gironi' && <GroupsView bundle={bundle} highlightTeamId={teamId} />}
        {tab === 'tabellone' && <section className="panel bracket-player-panel"><div className="panel-title"><h2>Tabellone</h2><span>{bundle.tournament.phase === 'groups' ? 'dopo i gironi' : 'eliminazione diretta'}</span></div><KnockoutBracket bundle={bundle} /></section>}
        {tab === 'partite' && <TeamMatches bundle={bundle} teamId={teamId} />}
        {tab === 'squadra' && <MyTeam bundle={bundle} teamId={teamId} onChanged={refresh} />}
      </section>

      <nav className="bottom-nav">
        <Nav active={tab === 'home'} onClick={() => setTab('home')} label="Home" icon="⌂" />
        <Nav active={tab === 'gironi'} onClick={() => setTab('gironi')} label="Gironi" icon="≡" />
        <Nav active={tab === 'tabellone'} onClick={() => setTab('tabellone')} label="Tabellone" icon="◇" />
        <Nav active={tab === 'partite'} onClick={() => setTab('partite')} label="Partite" icon="◫" />
        <Nav active={tab === 'squadra'} onClick={() => setTab('squadra')} label="Squadra" icon="●" />
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
  placeholder = 'Scrivi il nome della squadra',
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
        <span>{team.name}</span>
        {team.id === selectedId && <strong>✓</strong>}
      </button>) : <div className="team-search-empty">Nessuna squadra trovata</div>}
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
    <button className="text-button" onClick={() => navigate('/')}>← Tornei</button>
    <div className="eyebrow">{bundle.tournament.name}</div><h1>Qual è la tua squadra?</h1>
    <p className="lead small">Scrivi il nome della squadra oppure sceglila dai suggerimenti. All'inizio vengono mostrate tutte le squadre disponibili.</p>
    <label>Squadra</label>
    <SearchableTeamPicker teams={bundle.teams} selectedId={selected} onSelect={(teamId) => { setSelected(teamId); setPin(''); }} />
    {bundle.settings.team_pin_enabled && selected && <><label>PIN squadra</label><input inputMode="numeric" value={pin} onChange={(e) => setPin(e.target.value)} placeholder="PIN" /></>}
    {error && <div className="alert error">{error}</div>}
    {!online && <div className="alert warning">Per associare questo dispositivo a una squadra serve la connessione.</div>}
    <button className="button primary" disabled={busy || !selected || !online} onClick={() => void choose()}>{busy ? 'Associazione…' : 'Questa è la mia squadra'}</button>
  </section></main>;
}

function PlayerHome({ bundle, teamId }: { bundle: TournamentBundle; teamId: string; onRefresh: () => Promise<void> }) {
  const team = bundle.teams.find((t) => t.id === teamId)!;
  const live = bundle.matches
    .filter((m) => [m.team1_id, m.team2_id].includes(teamId) && ['called', 'ready', 'playing', 'awaiting_result'].includes(m.status))
    .sort(matchOrder)[0];
  const queued = bundle.matches
    .filter((m) => [m.team1_id, m.team2_id].includes(teamId) && m.status === 'queued')
    .sort((a, b) => (a.queue_position ?? 999999) - (b.queue_position ?? 999999))[0];
  const next = live ?? queued;

  const allQueued = bundle.matches.filter((m) => m.status === 'queued' && m.team1_id && m.team2_id).map((m) => ({
    id: m.id,
    team1Id: m.team1_id!,
    team2Id: m.team2_id!,
    queuePosition: m.queue_position ?? 999999,
  }));
  const ahead = live ? 0 : matchesAheadForTeam(allQueued, teamId);

  if (!next) return <><div className="team-pill">{team.name}</div><section className="next-card"><div className="eyebrow">PROSSIMA PARTITA</div><h2>Nessuna partita in coda</h2><p className="muted-on-dark">Il calendario potrebbe essere concluso o non ancora avviato.</p></section></>;

  const opponentId = next.team1_id === teamId ? next.team2_id : next.team1_id;
  const opponent = bundle.teams.find((t) => t.id === opponentId)?.name ?? 'Da definire';
  const field = bundle.fields.find((f) => f.id === next.field_id)?.name;
  const liveNow = ['called', 'ready', 'playing', 'awaiting_result'].includes(next.status);

  return <>
    <div className="team-pill">{team.name}</div>
    <section className={liveNow ? 'next-card urgent' : 'next-card'} onClick={() => liveNow && navigate(`/tournament/${bundle.tournament.slug}/match/${next.id}`)} role={liveNow ? 'button' : undefined}>
      <div className="eyebrow">{liveNow ? 'È IL VOSTRO TURNO' : 'PROSSIMA PARTITA'}</div>
      <div className="versus"><strong>{team.name}</strong><span>VS</span><strong>{opponent}</strong></div>
      <div className="next-meta"><span>{liveNow ? 'Adesso' : ahead === 0 ? 'Siete i prossimi' : `${ahead} ${ahead === 1 ? 'partita' : 'partite'} prima di voi`}</span><span>{field ?? 'Campo da assegnare'}</span></div>
      {liveNow && <div className="tap-hint">Tocca per aprire la partita →</div>}
    </section>
    <NotificationControls tournamentId={bundle.tournament.id} />
  </>;
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

  async function disable() {
    setBusy(true); setError('');
    try { await disableNotifications(); await refreshState(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }

  return <section className="notice-card notification-card">
    <div><strong>Avvisi 🔔</strong>
      {state === 'enabled' && <span>Notifiche attive. Riceverai “Preparatevi” e “È il vostro turno”.</span>}
      {state === 'default' && <span>Attiva gli avvisi per sapere quando manca una partita e quando dovete andare al campo.</span>}
      {state === 'disabled' && <span>Le notifiche sono consentite, ma questo dispositivo non è più registrato.</span>}
      {state === 'denied' && <span>Le notifiche sono bloccate nelle impostazioni del browser/dispositivo.</span>}
      {state === 'needs-install' && <span>Su iPhone/iPad installa prima la web app sulla schermata Home, poi aprila dall’icona.</span>}
      {state === 'unsupported' && <span>Questo browser non supporta le notifiche push web.</span>}
    </div>
    <div className="notification-actions">
      {pwa.canPromptInstall && <button className="button secondary" disabled={busy} onClick={() => void pwa.install()}>Installa app</button>}
      {pwa.needsIOSManualInstall && state === 'needs-install' && <span className="ios-install-hint">Condividi ↑ → Aggiungi alla schermata Home</span>}
      {(state === 'default' || state === 'disabled') && <button className="button primary" disabled={busy} onClick={() => void enable()}>{busy ? 'Attivazione…' : 'Attiva notifiche'}</button>}
      {state === 'enabled' && <button className="button ghost" disabled={busy} onClick={() => void disable()}>Disattiva</button>}
    </div>
    {error && <div className="alert error">{error}</div>}
  </section>;
}

function GroupsView({ bundle, highlightTeamId }: { bundle: TournamentBundle; highlightTeamId?: string }) {
  return <div className="group-stack">{bundle.groups.map((group) => {
    const memberships = bundle.groupTeams.filter((gt) => gt.group_id === group.id);
    const teams: EngineTeam[] = memberships.map((gt) => ({ id: gt.team_id, name: bundle.teams.find((t) => t.id === gt.team_id)?.name ?? '?', lotOrder: gt.lot_order }));
    const played: PlayedMatch[] = bundle.matches.filter((m) => m.group_id === group.id && ['finished','forfeit'].includes(m.status) && m.team1_id && m.team2_id && m.score_team1 != null && m.score_team2 != null).map((m) => ({
      id: m.id, groupId: group.id, team1Id: m.team1_id!, team2Id: m.team2_id!, scoreTeam1: m.score_team1!, scoreTeam2: m.score_team2!,
    }));
    const rows = calculateStandings(teams, played);
    return <section className="panel" key={group.id}><div className="panel-title"><h2>{group.name}</h2><span>PT · DR</span></div><div className="table standings-table">{rows.map((r, i) => <div className={r.teamId === highlightTeamId ? 'table-row highlighted' : 'table-row'} key={r.teamId}><span>{i + 1}</span><strong>{r.teamName}</strong><span>{r.points} pt</span><span>{signed(r.goalDifference)}</span></div>)}</div></section>;
  })}</div>;
}

function TeamMatches({ bundle, teamId }: { bundle: TournamentBundle; teamId: string }) {
  const items = bundle.matches.filter((m) => [m.team1_id, m.team2_id].includes(teamId)).sort(matchOrder);
  return <section className="panel"><h2>Le mie partite</h2><div className="match-list">{items.map((m) => {
    const a = teamName(bundle, m.team1_id), b = teamName(bundle, m.team2_id);
    const score = m.score_team1 != null ? `${m.score_team1} - ${m.score_team2}` : 'vs';
    const actionable = ['called','ready','playing','awaiting_result'].includes(m.status);
    return <button className="match-row-button" key={m.id} onClick={() => actionable && navigate(`/tournament/${bundle.tournament.slug}/match/${m.id}`)} disabled={!actionable}><span>{statusLabel(m.status)}</span><strong>{a} {score} {b}</strong></button>;
  })}</div></section>;
}

function MyTeam({ bundle, teamId, onChanged }: { bundle: TournamentBundle; teamId: string; onChanged: () => Promise<void> }) {
  const online = useConnectivity();
  const [newTeamId, setNewTeamId] = useState(teamId);
  const [pin, setPin] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function change() {
    setBusy(true); setError('');
    try { await claimTeam(newTeamId, bundle.settings.team_pin_enabled ? pin : undefined); await onChanged(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }
  async function remove() {
    setBusy(true);
    try { await leaveTeam(bundle.tournament.id); await onChanged(); }
    finally { setBusy(false); }
  }
  return <section className="panel form-panel"><h2>La mia squadra</h2><label>Squadra associata</label><select value={newTeamId} onChange={(e) => { setNewTeamId(e.target.value); setPin(''); }}>{bundle.teams.filter((t) => t.status === 'active').map((t) => <option value={t.id} key={t.id}>{t.name}</option>)}</select>{bundle.settings.team_pin_enabled && newTeamId !== teamId && <><label>PIN nuova squadra</label><input value={pin} inputMode="numeric" onChange={(e) => setPin(e.target.value)} /></>}{error && <div className="alert error">{error}</div>}<button className="button primary" disabled={busy || !online || newTeamId === teamId} onClick={() => void change()}>Cambia squadra</button><button className="button ghost" disabled={busy || !online} onClick={() => void remove()}>Dissocia questo dispositivo</button></section>;
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
  const expiring = useRef(false);

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
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => { const id = window.setInterval(() => setTick(Date.now()), 250); return () => window.clearInterval(id); }, []);
  useEffect(() => { if (!online) return; const id = window.setInterval(() => void refresh(), 3000); return () => window.clearInterval(id); }, [refresh, online]);

  const match = bundle?.matches.find((m) => m.id === matchId);
  const remaining = match ? secondsRemaining(match) : null;
  const countdown = match ? countdownRemaining(match.started_at) : 0;

  useEffect(() => {
    void tick;
    if (!online || !match || match.status !== 'playing' || match.duration_seconds == null || remaining !== 0 || countdown > 0 || expiring.current) return;
    expiring.current = true;
    markTimerExpired(match.id).then(refresh).catch((e) => setError(e instanceof Error ? e.message : String(e))).finally(() => { expiring.current = false; });
  }, [tick, online, match, remaining, countdown, refresh]);

  if (error && !bundle) return <CenteredMessage title="Errore partita" body={error} back />;
  if (!bundle || !match) return <CenteredMessage title="Caricamento partita…" />;
  if (!teamId || ![match.team1_id, match.team2_id].includes(teamId)) return <CenteredMessage title="Questa non è la tua partita" body="Solo i dispositivi associati alle due squadre e l'admin possono controllarla." back />;

  const resolvedMatchId = match.id;
  const a = teamName(bundle, match.team1_id), b = teamName(bundle, match.team2_id);
  const field = bundle.fields.find((f) => f.id === match.field_id)?.name ?? 'Campo';

  async function action(fn: () => Promise<unknown>) {
    setBusy(true); setError('');
    try { await fn(); await refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }

  async function submit() {
    const s1 = Number(score1), s2 = Number(score2);
    if (!Number.isInteger(s1) || !Number.isInteger(s2) || s1 < 0 || s2 < 0) { setError('Inserisci due punteggi validi.'); return; }
    await action(() => submitMatchResult(resolvedMatchId, s1, s2));
    setConfirming(false);
  }

  return <main className="match-screen">
    <ConnectionBanner online={online} cachedAt={cachedAt} />
    <header className="match-top"><button className="icon-button light" onClick={() => navigate(`/tournament/${slug}`)}>←</button><div><span>{bundle.tournament.name}</span><strong>{field}</strong></div></header>
    <section className="match-stage">
      <div className="match-team-names"><strong>{a}</strong><span>VS</span><strong>{b}</strong></div>
      {match.status === 'playing' && countdown > 0 && <div className="countdown"><span>{countdown}</span><small>PREPARATEVI</small></div>}
      {match.status === 'playing' && countdown === 0 && <><div className="match-clock">{match.duration_seconds == null ? 'IN CORSO' : formatClock(remaining)}</div>{match.goal_target && <div className="target-label">Primo a {match.goal_target} · oppure fine tempo</div>}{!online && remaining === 0 && <div className="offline-match-note">Tempo terminato. Continuate a giocare: appena torna la connessione passeremo automaticamente all'inserimento del risultato.</div>}</>}
      {['called','ready'].includes(match.status) && <><div className="waiting-title">Siete sul campo.</div><button className="giant-button" disabled={busy || !online} onClick={() => void action(() => startMatch(match.id))}>AVVIA PARTITA</button></>}
      {match.status === 'playing' && countdown === 0 && <div className="match-controls">{match.pause_allowed && (match.paused_at ? <button disabled={busy || !online} onClick={() => void action(() => resumeMatch(match.id))}>Riprendi</button> : <button disabled={busy || !online} onClick={() => void action(() => pauseMatch(match.id))}>Pausa</button>)}<button className="danger-soft" disabled={busy || !online} onClick={() => void action(() => endMatchEarly(match.id))}>Termina partita</button></div>}
      {match.status === 'awaiting_result' && <section className="score-entry"><div className="eyebrow light-text">PARTITA TERMINATA</div>{match.stage !== 'group' && <p>Se eravate pari allo scadere, continuate a giocare il <strong>golden goal</strong>. Poi inserite il risultato finale.</p>}<div className="score-inputs"><label><span>{a}</span><input type="number" min="0" inputMode="numeric" value={score1} onChange={(e) => { setScore1(e.target.value); setConfirming(false); }} /></label><strong>–</strong><label><span>{b}</span><input type="number" min="0" inputMode="numeric" value={score2} onChange={(e) => { setScore2(e.target.value); setConfirming(false); }} /></label></div>{!confirming ? <button className="giant-button" disabled={!online} onClick={() => setConfirming(true)}>Controlla risultato</button> : <div className="confirm-result"><strong>Confermi {a} {score1 || '0'} – {score2 || '0'} {b}?</strong><p>Dopo la conferma solo l'admin potrà modificarlo.</p><div><button onClick={() => setConfirming(false)}>Indietro</button><button className="confirm" disabled={busy || !online} onClick={() => void submit()}>CONFERMA</button></div></div>}</section>}
      {['finished','forfeit'].includes(match.status) && <section className="finished-result"><div className="eyebrow light-text">RISULTATO REGISTRATO</div><div>{match.score_team1} <span>–</span> {match.score_team2}</div><button onClick={() => navigate(`/tournament/${slug}`)}>Torna al torneo</button></section>}
      {error && <div className="alert error match-error">{error}</div>}
    </section>
  </main>;
}

function Nav({ active, onClick, label, icon }: { active: boolean; onClick: () => void; label: string; icon: string }) { return <button className={active ? 'nav-item active' : 'nav-item'} onClick={onClick}><span>{icon}</span>{label}</button>; }
function CenteredMessage({ title, body, back }: { title: string; body?: string; back?: boolean }) { return <main className="page page-centered"><section className="login-card">{back && <button className="text-button" onClick={() => navigate('/')}>← Indietro</button>}<h2>{title}</h2>{body && <p className="lead small">{body}</p>}</section></main>; }
function teamName(bundle: TournamentBundle, id: string | null) { return bundle.teams.find((t) => t.id === id)?.name ?? 'Da definire'; }
function signed(n: number) { return n > 0 ? `+${n}` : String(n); }
function matchOrder(a: MatchRow, b: MatchRow) { return (a.queue_position ?? a.sequence_number ?? 999999) - (b.queue_position ?? b.sequence_number ?? 999999); }
function statusLabel(status: MatchRow['status']) { const labels: Record<MatchRow['status'], string> = { scheduled:'PROGRAMMATA',queued:'IN CODA',called:'TOCCA A VOI',ready:'PRONTA',playing:'IN CORSO',awaiting_result:'RISULTATO',finished:'FINITA',postponed:'RIMANDATA',cancelled:'ANNULLATA',forfeit:'TAVOLINO' }; return labels[status]; }
