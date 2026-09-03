import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  adminGenerateKnockout,
  adminAddTeam,
  adminWithdrawTeam,
  adminRestoreTeam,
  adminDeleteTeamCompletely,
  adminForceMoveTeamToGroup,
  adminRenameTeam,
  adminSetTeamPin,
  adminAddField,
  adminUpdateField,
  adminAssignMatchField,
  adminReorderQueue,
  adminForfeitMatch,
  adminCancelMatch,
  adminUpdateTournamentRules,
  adminRenameGroup,
  adminPostponeMatch,
  adminStartTournament,
  adminUpdateMatchResult,
  createTournament,
  isCurrentUserAdmin,
  listAdminTournaments,
  loadTournamentBundleById,
  pauseMatch,
  regenerateGroupSchedule,
  resumeMatch,
  slugify,
  startMatch,
  endMatchEarly,
  submitMatchResult,
  type CreateTournamentInput,
  type MatchRow,
  type TournamentBundle,
  type TournamentRow,
} from '../lib/api.ts';
import { adminLogin, hasSupabaseConfig, supabase } from '../lib/supabase.ts';
import { formatClock, secondsRemaining } from '../lib/time.ts';
import { navigate } from '../router.ts';
import { KnockoutBracket, QualificationRanking } from '../components/KnockoutBracket.tsx';

type AdminTab = 'live' | 'teams' | 'groups' | 'bracket' | 'matches' | 'fields' | 'settings';

export function AdminPage() {
  const [authChecked, setAuthChecked] = useState(false);
  const [authenticated, setAuthenticated] = useState(false);
  const [password, setPassword] = useState('');
  const [loginError, setLoginError] = useState('');

  useEffect(() => {
    if (!supabase) { setAuthChecked(true); return; }
    supabase.auth.getSession().then(async ({ data }) => {
      if (!data.session || data.session.user.is_anonymous) { setAuthChecked(true); return; }
      try { setAuthenticated(await isCurrentUserAdmin()); } catch { setAuthenticated(false); }
      setAuthChecked(true);
    });
  }, []);

  async function login() {
    setLoginError('');
    try {
      await adminLogin(password);
      if (!(await isCurrentUserAdmin())) throw new Error('Questo utente esiste, ma non è registrato in admin_users. Segui README_STEP5.md.');
      setAuthenticated(true);
      setPassword('');
    } catch (e) { setLoginError(e instanceof Error ? e.message : String(e)); }
  }

  if (!authChecked) return <CenteredAdmin title="Controllo sessione…" />;
  if (!authenticated) {
    return <main className="page page-centered"><section className="login-card">
      <button className="text-button" onClick={() => navigate('/')}>← Torna indietro</button>
      <div className="eyebrow">AMMINISTRATORE</div><h1>Controllo torneo</h1>
      {!hasSupabaseConfig && <div className="alert warning">Supabase non è configurato. Crea prima <code>.env.local</code>.</div>}
      <label>Password</label><input type="password" value={password} onChange={(e) => setPassword(e.target.value)} onKeyDown={(e) => e.key === 'Enter' && void login()} placeholder="••••••••" />
      {loginError && <div className="alert error">{loginError}</div>}
      <button className="button primary" disabled={!password || !hasSupabaseConfig} onClick={() => void login()}>Entra</button>
      <p className="hint">L'email tecnica dell'admin resta nella configurazione dell'app; nell'interfaccia inserisci solo la password.</p>
    </section></main>;
  }

  return <AdminWorkspace onLogout={() => setAuthenticated(false)} />;
}

function AdminWorkspace({ onLogout }: { onLogout: () => void }) {
  const [tournaments, setTournaments] = useState<TournamentRow[]>([]);
  const [selectedId, setSelectedId] = useState<string>('');
  const [bundle, setBundle] = useState<TournamentBundle | null>(null);
  const [tab, setTab] = useState<AdminTab>('live');
  const [creating, setCreating] = useState(false);
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const refreshList = useCallback(async () => {
    const items = await listAdminTournaments();
    setTournaments(items);
    setSelectedId((current) => current || items[0]?.id || '');
    return items;
  }, []);

  const refreshBundle = useCallback(async (id?: string) => {
    const target = id ?? selectedId;
    if (!target) { setBundle(null); return; }
    try { setBundle(await loadTournamentBundleById(target)); setError(''); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
  }, [selectedId]);

  useEffect(() => { refreshList().catch((e) => setError(String(e))).finally(() => setLoading(false)); }, [refreshList]);
  useEffect(() => { if (selectedId) void refreshBundle(selectedId); }, [selectedId, refreshBundle]);
  useEffect(() => {
    if (!selectedId || bundle?.tournament.status !== 'active') return;
    const id = window.setInterval(() => void refreshBundle(selectedId), 3000);
    return () => window.clearInterval(id);
  }, [selectedId, bundle?.tournament.status, refreshBundle]);

  async function logout() {
    await supabase?.auth.signOut();
    onLogout();
  }

  async function created(t: TournamentRow) {
    setCreating(false);
    await refreshList();
    setSelectedId(t.id);
    setTab('live');
  }

  const selected = tournaments.find((t) => t.id === selectedId);

  return <main className="admin-shell">
    <aside className="sidebar">
      <div className="brand">BABY<br/><span>BILIARDINO</span></div>
      {([['live','Live'],['teams','Squadre'],['groups','Gironi'],['bracket','Tabellone'],['matches','Partite'],['fields','Campi'],['settings','Impostazioni']] as [AdminTab,string][]).map(([key,label]) => <button className={tab === key ? 'side-link active' : 'side-link'} key={key} onClick={() => { setCreating(false); setTab(key); }}>{label}</button>)}
      <div className="sidebar-spacer" />
      <button className="side-link" onClick={() => setCreating(true)}>＋ Nuovo torneo</button>
      <button className="side-link" onClick={() => void logout()}>Esci admin</button>
    </aside>

    <section className="admin-main">
      <header className="admin-top">
        <div>{selected && <div className="eyebrow">{selected.name}</div>}<h1>{creating ? 'Nuovo torneo' : tabTitle(tab)}</h1></div>
        <div className="admin-top-actions">
          {!creating && tournaments.length > 0 && <select value={selectedId} onChange={(e) => setSelectedId(e.target.value)}>{tournaments.map((t) => <option value={t.id} key={t.id}>{t.name} · {t.status}</option>)}</select>}
          {bundle?.tournament.status === 'active' && <span className="live-badge">● LIVE</span>}
        </div>
      </header>

      {error && <div className="alert error">{error}</div>}
      {loading && <div className="empty-state">Caricamento…</div>}
      {creating && <CreateTournamentForm onCreated={created} onCancel={() => setCreating(false)} />}
      {!creating && !loading && tournaments.length === 0 && <CreateTournamentForm onCreated={created} />}
      {!creating && bundle && <AdminTabContent tab={tab} bundle={bundle} refresh={refreshBundle} setError={setError} />}
    </section>
  </main>;
}

function AdminTabContent({ tab, bundle, refresh, setError }: { tab: AdminTab; bundle: TournamentBundle; refresh: () => Promise<void>; setError: (s: string) => void }) {
  if (tab === 'live') return <LiveAdmin bundle={bundle} refresh={refresh} setError={setError} />;
  if (tab === 'teams') return <TeamsAdmin bundle={bundle} refresh={refresh} setError={setError} />;
  if (tab === 'groups') return <GroupsAdmin bundle={bundle} refresh={refresh} setError={setError} />;
  if (tab === 'bracket') return <BracketAdmin bundle={bundle} refresh={refresh} setError={setError} />;
  if (tab === 'matches') return <MatchesAdmin bundle={bundle} refresh={refresh} setError={setError} />;
  if (tab === 'fields') return <FieldsAdmin bundle={bundle} refresh={refresh} setError={setError} />;
  return <SettingsAdmin bundle={bundle} refresh={refresh} setError={setError} />;
}

function LiveAdmin({ bundle, refresh, setError }: AdminPanelProps) {
  const [busy, setBusy] = useState('');
  const liveMatches = bundle.matches.filter((m) => ['called','ready','playing','awaiting_result'].includes(m.status));
  const queue = bundle.matches.filter((m) => m.status === 'queued').sort((a,b) => (a.queue_position ?? 999999) - (b.queue_position ?? 999999));
  const matchByField = new Map(liveMatches.filter((m) => m.field_id).map((m) => [m.field_id!, m]));
  const freeFields = bundle.fields.filter((f) => f.is_active && !matchByField.has(f.id));

  async function act(key: string, fn: () => Promise<unknown>) {
    setBusy(key); setError('');
    try { await fn(); await refresh(); } catch (e) { setError(e instanceof Error ? e.message : String(e)); } finally { setBusy(''); }
  }

  async function moveQueue(index: number, target: number) {
    if (target < 0 || target >= queue.length || target === index) return;
    const ids = queue.map((m) => m.id);
    const [picked] = ids.splice(index, 1);
    ids.splice(target, 0, picked);
    await act(`queue-${queue[index].id}`, () => adminReorderQueue(bundle.tournament.id, ids));
  }

  if (bundle.tournament.status === 'draft') return <section className="panel draft-launch">
    <div className="panel-title"><h2>Configurazione pronta</h2><span>DRAFT</span></div>
    <div className="stats-strip"><Stat n={bundle.teams.filter(t=>t.status==='active').length} label="squadre"/><Stat n={bundle.groups.length} label="gironi"/><Stat n={bundle.fields.filter(f=>f.is_active).length} label="campi"/><Stat n={bundle.matches.length} label="partite"/></div>
    <p>Controlla soprattutto le sezioni <strong>Squadre</strong> e <strong>Gironi</strong>. Finché il torneo è in bozza puoi modificare liberamente la struttura.</p>
    <div className="inline-actions"><button className="button secondary" onClick={() => void act('regen', () => regenerateGroupSchedule(bundle.tournament.id))}>{busy === 'regen' ? 'Rigenerazione…' : 'Rigenera calendario'}</button><button className="button primary" onClick={() => void act('start', () => adminStartTournament(bundle.tournament.id))}>{busy === 'start' ? 'Avvio…' : 'AVVIA TORNEO'}</button></div>
    <p className="hint">All'avvio tutte le partite dei gironi entrano nella coda rigida e i primi match vengono assegnati ai campi liberi.</p>
  </section>;

  return <>
    <div className="field-grid">{bundle.fields.filter((f) => f.is_active).map((field) => <AdminFieldCard key={field.id} fieldName={field.name} match={matchByField.get(field.id)} bundle={bundle} busy={busy} act={act} />)}</div>
    <section className="panel"><div className="panel-title"><h2>Coda partite</h2><span>ordine modificabile dall'admin</span></div>
      {queue.length === 0 && <div className="empty-state compact">Coda vuota</div>}
      {queue.slice(0, 30).map((m, i) => <div className="queue-row admin-queue-row" key={m.id}>
        <span className="queue-number">{i+1}</span>
        <strong>{teamName(bundle,m.team1_id)} vs {teamName(bundle,m.team2_id)}</strong>
        <div className="queue-controls">
          <button title="In cima" disabled={i===0 || busy.startsWith('queue-')} onClick={() => void moveQueue(i,0)}>⇈</button>
          <button title="Su" disabled={i===0 || busy.startsWith('queue-')} onClick={() => void moveQueue(i,i-1)}>↑</button>
          <button title="Giù" disabled={i===queue.length-1 || busy.startsWith('queue-')} onClick={() => void moveQueue(i,i+1)}>↓</button>
          <button disabled={busy === m.id} onClick={() => void act(m.id, () => adminPostponeMatch(m.id))}>In fondo</button>
          <select aria-label="Assegna a campo" defaultValue="" disabled={freeFields.length===0 || busy===m.id} onChange={(e)=>{ const field=e.currentTarget.value; e.currentTarget.value=''; if(field) void act(m.id,()=>adminAssignMatchField(m.id,field)); }}>
            <option value="">Campo…</option>{freeFields.map(f=><option value={f.id} key={f.id}>{f.name}</option>)}
          </select>
        </div>
      </div>)}
    </section>
  </>;
}

function AdminFieldCard({ fieldName, match, bundle, busy, act }: { fieldName: string; match?: MatchRow; bundle: TournamentBundle; busy: string; act: (k:string, fn:()=>Promise<unknown>)=>Promise<void> }) {
  const [, setTick] = useState(Date.now());
  const [confirmEnd, setConfirmEnd] = useState(false);
  useEffect(() => { const id = window.setInterval(() => setTick(Date.now()), 500); return () => window.clearInterval(id); }, []);
  if (!match) return <section className="field-card field-free"><div className="panel-title"><strong>{fieldName}</strong><span>LIBERO</span></div><div className="field-empty">Campo disponibile</div></section>;
  const liveMatch = match;
  const remaining = secondsRemaining(liveMatch);
  const t1=teamName(bundle,liveMatch.team1_id), t2=teamName(bundle,liveMatch.team2_id);
  function cancel(){ if(window.confirm(`Annullare ${t1} vs ${t2}?`)) void act(`cancel-${liveMatch.id}`,()=>adminCancelMatch(liveMatch.id)); }
  function forfeit(loserId:string|null, loserName:string){ if(loserId && window.confirm(`Sconfitta a tavolino per ${loserName}? Il risultato sarà ${liveMatch.goal_target ?? 1}-0.`)) void act(`forfeit-${liveMatch.id}`,()=>adminForfeitMatch(liveMatch.id,loserId)); }
  return <section className="field-card"><div className="panel-title"><strong>{fieldName}</strong><span>{liveMatch.status.replace('_',' ')}</span></div><div className="field-match"><strong>{t1}</strong><small>VS</small><strong>{t2}</strong></div><div className="big-timer">{liveMatch.duration_seconds == null ? '∞' : formatClock(remaining)}</div><div className="actions field-actions">
    {['called','ready'].includes(liveMatch.status) && <button disabled={busy===liveMatch.id} onClick={() => void act(liveMatch.id, () => startMatch(liveMatch.id))}>Avvia</button>}
    {liveMatch.status === 'playing' && liveMatch.pause_allowed && (liveMatch.paused_at ? <button disabled={busy===liveMatch.id} onClick={() => void act(liveMatch.id, () => resumeMatch(liveMatch.id))}>Riprendi</button> : <button disabled={busy===liveMatch.id} onClick={() => void act(liveMatch.id, () => pauseMatch(liveMatch.id))}>Pausa</button>)}
    {liveMatch.status === 'playing' && <button disabled={busy===liveMatch.id || confirmEnd} onClick={() => setConfirmEnd(true)}>Termina</button>}
    {liveMatch.status === 'awaiting_result' && <span className="awaiting-chip">Attesa risultato</span>}
    {!['finished','forfeit','cancelled'].includes(liveMatch.status) && <button disabled={busy.includes(liveMatch.id)} onClick={() => void act(`post-${liveMatch.id}`,()=>adminPostponeMatch(liveMatch.id))}>Rimanda</button>}
    {!['finished','forfeit','cancelled'].includes(liveMatch.status) && <button className="danger-soft" disabled={busy.includes(liveMatch.id)} onClick={cancel}>Annulla</button>}
  </div>
  {confirmEnd && liveMatch.status === 'playing' && <div className="admin-inline-confirm"><strong>Concludere la partita?</strong><span>La partita verrà chiusa e passerà all’inserimento del risultato.</span><div><button disabled={busy===liveMatch.id} onClick={() => setConfirmEnd(false)}>Continua</button><button className="danger-soft" disabled={busy===liveMatch.id} onClick={() => { setConfirmEnd(false); void act(liveMatch.id, () => endMatchEarly(liveMatch.id)); }}>Concludi partita</button></div></div>}
  {!['finished','forfeit','cancelled'].includes(liveMatch.status) && <div className="forfeit-row"><span>Tavolino:</span><button onClick={()=>forfeit(liveMatch.team1_id,t1)}>perde {t1}</button><button onClick={()=>forfeit(liveMatch.team2_id,t2)}>perde {t2}</button></div>}
  </section>;
}

function TeamsAdmin({ bundle, refresh, setError }: AdminPanelProps) {
  const [name,setName]=useState('');
  const [groupId,setGroupId]=useState(bundle.groups[0]?.id ?? '');
  const [pin,setPin]=useState('');
  const [busy,setBusy]=useState('');
  useEffect(()=>{ if(!bundle.groups.some(g=>g.id===groupId)) setGroupId(bundle.groups[0]?.id ?? ''); },[bundle.groups,groupId]);
  const editable=bundle.tournament.phase==='groups' && bundle.tournament.status!=='completed';

  async function act(key:string,fn:()=>Promise<unknown>){ setBusy(key);setError('');try{await fn();await refresh();}catch(e){setError(e instanceof Error?e.message:String(e));}finally{setBusy('');} }
  async function add(){ if(!name.trim()||!groupId)return; await act('add',async()=>{await adminAddTeam(bundle.tournament.id,groupId,name,pin||undefined);setName('');setPin('');}); }
  async function rename(teamId:string,current:string){ const next=window.prompt('Nuovo nome squadra',current); if(next===null||!next.trim()||next.trim()===current)return; await act(teamId,()=>adminRenameTeam(teamId,next)); }
  async function changePin(teamId:string){ const next=window.prompt('Nuovo PIN. Lascia vuoto per rimuoverlo.'); if(next===null)return; await act(`pin-${teamId}`,()=>adminSetTeamPin(teamId,next)); }
  async function move(teamId:string,currentGroup:string,target:string){ if(!target||target===currentGroup)return; const msg=bundle.tournament.status==='active'?'Spostare questa squadra durante il torneo cancellerà TUTTI i suoi risultati di girone già giocati e creerà le partite nel nuovo girone. Continuare?':'Spostare la squadra nel nuovo girone?'; if(!window.confirm(msg))return; await act(`move-${teamId}`,()=>adminForceMoveTeamToGroup(bundle.tournament.id,teamId,target)); }
  async function withdraw(teamId:string,name:string){ if(!window.confirm(`Ritirare ${name}? I risultati già conclusi restano; le partite non ancora concluse vengono rimosse.`))return; await act(`withdraw-${teamId}`,()=>adminWithdrawTeam(bundle.tournament.id,teamId)); }
  async function restore(teamId:string,name:string){ if(!window.confirm(`Riattivare ${name}? Le partite mancanti verranno aggiunte in fondo alla coda.`))return; await act(`restore-${teamId}`,()=>adminRestoreTeam(bundle.tournament.id,teamId)); }
  async function remove(teamId:string,name:string){ if(!window.confirm(`ELIMINARE COMPLETAMENTE ${name}? Verranno cancellati anche tutti i risultati di girone della squadra e la classifica sarà ricalcolata.`))return; await act(`delete-${teamId}`,()=>adminDeleteTeamCompletely(bundle.tournament.id,teamId)); }

  const groupByTeam=new Map(bundle.groupTeams.map(gt=>[gt.team_id,gt.group_id]));
  return <>
    <section className="panel team-add-panel"><div className="panel-title"><h2>Aggiungi squadra</h2><span>{bundle.teams.filter(t=>t.status==='active').length} attive</span></div>
      <div className="team-add-grid"><input placeholder="Nome squadra" value={name} disabled={!editable} onChange={e=>setName(e.target.value)}/><select value={groupId} disabled={!editable} onChange={e=>setGroupId(e.target.value)}>{bundle.groups.map(g=><option value={g.id} key={g.id}>{g.name}</option>)}</select>{bundle.settings.team_pin_enabled&&<input placeholder="PIN" value={pin} disabled={!editable} onChange={e=>setPin(e.target.value)}/>}<button className="button primary" disabled={!editable||!name.trim()||!groupId||busy==='add'} onClick={()=>void add()}>＋ Aggiungi</button></div>
      {bundle.tournament.status==='active'&&<p className="hint">Una squadra aggiunta a torneo avviato riceve le nuove partite in fondo alla coda: l'ordine già esistente non viene toccato.</p>}
      {!editable&&<div className="alert warning compact">La struttura delle squadre è bloccata dopo l'inizio del tabellone eliminatorio.</div>}
    </section>
    <section className="panel"><div className="panel-title"><h2>{bundle.teams.length} squadre</h2><span>controllo admin</span></div><div className="team-admin-list">{bundle.teams.map(t=>{const currentGroup=groupByTeam.get(t.id)??'';return <div className={`team-admin-row ${t.status==='withdrawn'?'withdrawn':''}`} key={t.id}><button className="team-name-button" disabled={busy.includes(t.id)} onClick={()=>void rename(t.id,t.name)}>{t.name}</button><select value={currentGroup} disabled={!editable||t.status==='withdrawn'||busy.includes(t.id)} onChange={e=>void move(t.id,currentGroup,e.target.value)}>{bundle.groups.map(g=><option value={g.id} key={g.id}>{g.name}</option>)}</select><span className={`status-pill ${t.status}`}>{t.status}</span><div className="team-row-actions"><button disabled={busy.includes(t.id)} onClick={()=>void changePin(t.id)}>PIN</button>{t.status==='active'?<button disabled={!editable||busy.includes(t.id)} onClick={()=>void withdraw(t.id,t.name)}>Ritira</button>:<button disabled={!editable||busy.includes(t.id)} onClick={()=>void restore(t.id,t.name)}>Riattiva</button>}<button className="danger-soft" disabled={!editable||busy.includes(t.id)} onClick={()=>void remove(t.id,t.name)}>Elimina</button></div></div>})}</div></section>
  </>;
}

function GroupsAdmin({ bundle, refresh, setError }: AdminPanelProps) {
  const [busy, setBusy] = useState('');
  async function move(teamId: string, groupId: string) {
    const current=bundle.groupTeams.find(gt=>gt.team_id===teamId)?.group_id;
    if(!current||current===groupId)return;
    if(bundle.tournament.status==='active'&&!window.confirm('Spostare una squadra a torneo avviato cancella tutti i suoi risultati di girone e genera le nuove partite nel girone di destinazione. Continuare?'))return;
    setBusy(teamId); setError('');
    try { await adminForceMoveTeamToGroup(bundle.tournament.id, teamId, groupId); await refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(''); }
  }
  return <div className="group-admin-grid">{bundle.groups.map((g) => <GroupAdminCard key={g.id} group={g} bundle={bundle} busy={busy} move={move} refresh={refresh} setError={setError} />)}</div>;
}

function GroupAdminCard({ group, bundle, busy, move, refresh, setError }: { group: TournamentBundle['groups'][number]; bundle: TournamentBundle; busy: string; move: (teamId:string, groupId:string)=>Promise<void>; refresh:()=>Promise<void>; setError:(s:string)=>void }) {
  const [name, setName] = useState(group.name);
  const [renaming, setRenaming] = useState(false);
  useEffect(() => setName(group.name), [group.name]);

  async function rename() {
    const clean = name.trim();
    if (!clean || clean === group.name) { setName(group.name); return; }
    setRenaming(true); setError('');
    try { await adminRenameGroup(group.id, clean); await refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); setName(group.name); }
    finally { setRenaming(false); }
  }

  const memberships = bundle.groupTeams.filter((gt)=>gt.group_id===group.id);
  return <section className="panel">
    <div className="panel-title group-title-editor">
      <div className="group-name-edit">
        <input aria-label={`Nome ${group.name}`} value={name} disabled={renaming} onChange={(e)=>setName(e.target.value)} onBlur={()=>void rename()} onKeyDown={(e)=>{ if(e.key==='Enter') (e.currentTarget as HTMLInputElement).blur(); if(e.key==='Escape') setName(group.name); }} />
        <span className="hint">clicca per rinominare</span>
      </div>
      <span>{memberships.length} squadre</span>
    </div>
    {memberships.map((gt) => { const team = bundle.teams.find((t)=>t.id===gt.team_id); return <div className="group-team-editor" key={gt.id}><strong>{team?.name}</strong><select disabled={bundle.tournament.phase !== 'groups' || bundle.tournament.status === 'completed' || team?.status==='withdrawn' || busy===gt.team_id} value={group.id} onChange={(e)=>void move(gt.team_id,e.target.value)}>{bundle.groups.map((target)=><option value={target.id} key={target.id}>{target.name}</option>)}</select></div>; })}
  </section>;
}

function BracketAdmin({ bundle, refresh, setError }: AdminPanelProps) {
  const [busy, setBusy] = useState(false);
  const groupMatches = bundle.matches.filter((m) => m.stage === 'group');
  const groupsComplete = groupMatches.length > 0 && groupMatches.every((m) => ['finished','forfeit'].includes(m.status));

  async function generate() {
    setBusy(true); setError('');
    try { await adminGenerateKnockout(bundle.tournament.id); await refresh(); }
    catch (e) { setError(e instanceof Error ? e.message : String(e)); }
    finally { setBusy(false); }
  }

  return <>
    <section className="panel bracket-admin-panel">
      <div className="panel-title"><h2>Eliminazione diretta</h2><span>{bundle.tournament.phase}</span></div>
      {bundle.knockoutRounds.length === 0 && <>
        <p>Il tabellone viene generato automaticamente quando si chiude l'ultima partita dei gironi.</p>
        {groupsComplete && <div className="inline-actions"><button className="button primary" disabled={busy} onClick={() => void generate()}>{busy ? 'Generazione…' : 'Genera tabellone ora'}</button></div>}
      </>}
      <KnockoutBracket bundle={bundle} />
    </section>
    <QualificationRanking bundle={bundle} />
  </>;
}

function MatchesAdmin({ bundle, refresh, setError }: AdminPanelProps) {
  const sorted = [...bundle.matches].sort((a,b)=>(a.sequence_number??999999)-(b.sequence_number??999999));
  return <section className="panel"><div className="panel-title"><h2>Partite</h2><span>{sorted.length} totali</span></div><div className="admin-match-list">{sorted.map((m)=><AdminMatchRow key={m.id} m={m} bundle={bundle} refresh={refresh} setError={setError}/>)}</div></section>;
}

function AdminMatchRow({ m, bundle, refresh, setError }: { m: MatchRow; bundle: TournamentBundle; refresh:()=>Promise<void>; setError:(s:string)=>void }) {
  const [s1,setS1]=useState(String(m.score_team1 ?? ''));
  const [s2,setS2]=useState(String(m.score_team2 ?? ''));
  const [busy,setBusy]=useState(false);
  const closed=['finished','forfeit'].includes(m.status);
  async function save() {
    const a=Number(s1), b=Number(s2); if(!Number.isInteger(a)||!Number.isInteger(b)||a<0||b<0){setError('Punteggio non valido.');return;}
    setBusy(true); setError('');
    try { if(closed) await adminUpdateMatchResult(m.id,a,b); else await submitMatchResult(m.id,a,b); await refresh(); }
    catch(e){setError(e instanceof Error?e.message:String(e));} finally{setBusy(false);}
  }
  return <div className="admin-match-row"><div><span className="status-mini">{m.status}</span><strong>{teamName(bundle,m.team1_id)} vs {teamName(bundle,m.team2_id)}</strong></div><div className="score-mini"><input type="number" min="0" value={s1} onChange={(e)=>setS1(e.target.value)}/><span>–</span><input type="number" min="0" value={s2} onChange={(e)=>setS2(e.target.value)}/><button disabled={busy || (!closed && !['playing','awaiting_result'].includes(m.status))} onClick={()=>void save()}>{closed?'Correggi':'Salva'}</button></div></div>;
}

function FieldsAdmin({ bundle, refresh, setError }: AdminPanelProps) {
  const [newName,setNewName]=useState('');
  const [busy,setBusy]=useState('');
  async function act(key:string,fn:()=>Promise<unknown>){setBusy(key);setError('');try{await fn();await refresh();}catch(e){setError(e instanceof Error?e.message:String(e));}finally{setBusy('');}}
  async function add(){if(!newName.trim())return;await act('add-field',async()=>{await adminAddField(bundle.tournament.id,newName);setNewName('');});}
  return <>
    <section className="panel"><div className="panel-title"><h2>Campi</h2><span>{bundle.fields.filter(f=>f.is_active).length} attivi</span></div>
      <div className="field-add-row"><input placeholder="Nome nuovo campo" value={newName} onChange={e=>setNewName(e.target.value)} onKeyDown={e=>e.key==='Enter'&&void add()}/><button className="button primary" disabled={!newName.trim()||busy==='add-field'} onClick={()=>void add()}>＋ Aggiungi campo</button></div>
      <p className="hint">Se aggiungi un campo durante il torneo, il motore gli assegna immediatamente la prima partita in coda. Un campo con una partita live non può essere disattivato.</p>
    </section>
    <div className="field-admin-grid">{bundle.fields.map(f=><FieldAdminRow key={f.id} field={f} busy={busy} act={act}/>)}</div>
  </>;
}

function FieldAdminRow({field,busy,act}:{field:TournamentBundle['fields'][number];busy:string;act:(k:string,fn:()=>Promise<unknown>)=>Promise<void>}){
  const [name,setName]=useState(field.name); useEffect(()=>setName(field.name),[field.name]);
  async function save(nextActive=field.is_active){const clean=name.trim()||field.name;setName(clean);await act(field.id,()=>adminUpdateField(field.id,clean,nextActive));}
  return <section className={`panel field-admin-card ${field.is_active?'':'inactive'}`}><div className="panel-title"><span>Ordine {field.sort_order}</span><span>{field.is_active?'ATTIVO':'OFF'}</span></div><input className="field-name-input" value={name} disabled={busy===field.id} onChange={e=>setName(e.target.value)} onBlur={()=>{if(name.trim()!==field.name)void save();}} onKeyDown={e=>{if(e.key==='Enter')(e.currentTarget as HTMLInputElement).blur();}}/><label className="switch-row"><input type="checkbox" checked={field.is_active} disabled={busy===field.id} onChange={e=>void save(e.target.checked)}/><span>Campo disponibile per il motore</span></label></section>;
}

function SettingsAdmin({ bundle, refresh, setError }: AdminPanelProps) {
  const rule=(scope:'group'|'knockout'|'final'|'third_place')=>bundle.rules.find(r=>r.scope===scope);
  const initMinutes=(scope:'group'|'knockout'|'final'|'third_place')=>{const s=rule(scope)?.duration_seconds;return s==null?'':String(s/60)};
  const initGoals=(scope:'group'|'knockout'|'final'|'third_place')=>{const g=rule(scope)?.goal_target;return g==null?'':String(g)};
  const [pause,setPause]=useState(bundle.settings.pause_enabled); const [qualifiers,setQualifiers]=useState(String(bundle.settings.qualifiers_per_group)); const [third,setThird]=useState(bundle.settings.third_place_enabled); const [pins,setPins]=useState(bundle.settings.team_pin_enabled);
  const [gm,setGm]=useState(initMinutes('group')); const [gg,setGg]=useState(initGoals('group')); const [km,setKm]=useState(initMinutes('knockout')); const [kg,setKg]=useState(initGoals('knockout')); const [fm,setFm]=useState(initMinutes('final')); const [fg,setFg]=useState(initGoals('final')); const [tm,setTm]=useState(initMinutes('third_place')); const [tg,setTg]=useState(initGoals('third_place')); const [busy,setBusy]=useState(false);
  useEffect(()=>{setPause(bundle.settings.pause_enabled);setQualifiers(String(bundle.settings.qualifiers_per_group));setThird(bundle.settings.third_place_enabled);setPins(bundle.settings.team_pin_enabled);setGm(initMinutes('group'));setGg(initGoals('group'));setKm(initMinutes('knockout'));setKg(initGoals('knockout'));setFm(initMinutes('final'));setFg(initGoals('final'));setTm(initMinutes('third_place'));setTg(initGoals('third_place'));},[bundle.tournament.id,bundle.settings.pause_enabled,bundle.settings.qualifiers_per_group,bundle.settings.third_place_enabled,bundle.settings.team_pin_enabled,bundle.rules]);
  const duration=(v:string)=>v.trim()===''?null:Math.max(1,Math.round(Number(v)*60)); const goal=(v:string)=>v.trim()===''?null:Math.max(1,Math.round(Number(v)));
  async function save(){setBusy(true);setError('');try{await adminUpdateTournamentRules(bundle.tournament.id,{pauseEnabled:pause,qualifiersPerGroup:Number(qualifiers),thirdPlaceEnabled:third,teamPinEnabled:pins,group:{durationSeconds:duration(gm),goalTarget:goal(gg)},knockout:{durationSeconds:duration(km),goalTarget:goal(kg)},final:{durationSeconds:duration(fm),goalTarget:goal(fg)},thirdPlace:{durationSeconds:duration(tm),goalTarget:goal(tg)}});await refresh();}catch(e){setError(e instanceof Error?e.message:String(e));}finally{setBusy(false);}}
  return <div className="settings-grid">
    <section className="panel settings-editor"><div className="panel-title"><h2>Regole modificabili</h2><span>future partite</span></div><label>Qualificate per girone<input type="number" min="1" value={qualifiers} onChange={e=>setQualifiers(e.target.value)}/></label><label className="check-row"><input type="checkbox" checked={pause} onChange={e=>setPause(e.target.checked)}/>Permetti pausa timer</label><label className="check-row"><input type="checkbox" checked={pins} onChange={e=>setPins(e.target.checked)}/>PIN squadre</label><label className="check-row"><input type="checkbox" checked={third} onChange={e=>setThird(e.target.checked)}/>3º/4º posto</label><div className="rule-editor-list"><EditableRule title="Gironi" minutes={gm} goals={gg} setMinutes={setGm} setGoals={setGg}/><EditableRule title="Eliminatorie" minutes={km} goals={kg} setMinutes={setKm} setGoals={setKg}/><EditableRule title="Finale" minutes={fm} goals={fg} setMinutes={setFm} setGoals={setFg}/><EditableRule title="3º/4º posto" minutes={tm} goals={tg} setMinutes={setTm} setGoals={setTg}/></div><button className="button primary" disabled={busy} onClick={()=>void save()}>{busy?'Salvataggio…':'SALVA REGOLE'}</button><p className="hint">Le modifiche si applicano alle partite non ancora iniziate. Una partita già in corso conserva timer e target con cui è partita.</p></section>
    <section className="panel"><h2>Stato</h2><KeyValue k="Ordine coda" v={bundle.settings.ordering_mode==='group_rotation'?'Rotazione gironi':'Girone per girone'}/><KeyValue k="Torneo" v={bundle.tournament.status}/><KeyValue k="Fase" v={bundle.tournament.phase}/><KeyValue k="Slug" v={bundle.tournament.slug}/><p className="hint">L'ordine generale non viene rigenerato a torneo avviato: per cambiarlo usa i controlli della coda nella pagina Live.</p></section>
  </div>;
}

function EditableRule({title,minutes,goals,setMinutes,setGoals}:{title:string;minutes:string;goals:string;setMinutes:(v:string)=>void;setGoals:(v:string)=>void}){return <div className="editable-rule"><strong>{title}</strong><label>min<input type="number" min="0" step="0.5" value={minutes} onChange={e=>setMinutes(e.target.value)}/></label><label>goal<input type="number" min="1" value={goals} onChange={e=>setGoals(e.target.value)}/></label></div>;}

function CreateTournamentForm({ onCreated, onCancel }: { onCreated:(t:TournamentRow)=>Promise<void>; onCancel?:()=>void }) {
  const [name,setName]=useState('');
  const [slug,setSlug]=useState('');
  const [teamText,setTeamText]=useState('');
  const [groupAssignmentMode,setGroupAssignmentMode]=useState<'auto'|'manual'>('auto');
  const [groupCount,setGroupCount]=useState(4);
  const [groupNames,setGroupNames]=useState<string[]>(['Girone A','Girone B','Girone C','Girone D']);
  const [fieldText,setFieldText]=useState('Campo 1, Campo 2, Campo 3');
  const [orderingMode,setOrderingMode]=useState<'group_rotation'|'group_sequential'>('group_rotation');
  const [qualifiers,setQualifiers]=useState(2);
  const [pins,setPins]=useState(false);
  const [pause,setPause]=useState(true);
  const [thirdPlace,setThirdPlace]=useState(false);
  const [groupMinutes,setGroupMinutes]=useState('7'); const [groupGoals,setGroupGoals]=useState('10');
  const [koMinutes,setKoMinutes]=useState('7'); const [koGoals,setKoGoals]=useState('10');
  const [finalMinutes,setFinalMinutes]=useState('10'); const [finalGoals,setFinalGoals]=useState('10');
  const [busy,setBusy]=useState(false); const [error,setError]=useState('');

  useEffect(()=>{ if(name && (!slug || slug===slugify(name.slice(0,-1)))) setSlug(slugify(name)); },[name]);

  const parseTeamLine = useCallback((line:string) => {
    const [n,...rest]=line.split('|');
    return {name:n.trim(),pin:rest.join('|').trim()||undefined};
  },[]);

  const manualGroups=useMemo(()=>{
    const normalized=teamText.replace(/\r\n/g,'\n').trim();
    if(!normalized) return [] as {name:string;pin?:string}[][];
    return normalized
      .split(/\n[ \t]*\n+/)
      .map(block=>block.split('\n').map(line=>line.trim()).filter(Boolean).map(parseTeamLine))
      .filter(group=>group.length>0);
  },[teamText,parseTeamLine]);

  const parsedTeams=useMemo(()=>{
    if(groupAssignmentMode==='manual') return manualGroups.flat();
    return teamText.split('\n').map(s=>s.trim()).filter(Boolean).map(parseTeamLine);
  },[teamText,groupAssignmentMode,manualGroups,parseTeamLine]);

  const teamGroupIndexes=useMemo(()=>groupAssignmentMode==='manual'
    ? manualGroups.flatMap((group,index)=>group.map(()=>index))
    : undefined,[groupAssignmentMode,manualGroups]);

  const effectiveGroupCount=groupAssignmentMode==='manual'?manualGroups.length:groupCount;

  useEffect(()=>{
    if(effectiveGroupCount<1) return;
    setGroupNames(current=>Array.from({length:effectiveGroupCount},(_,i)=>current[i]??`Girone ${String.fromCharCode(65+i)}`));
  },[effectiveGroupCount]);

  const resolvedGroupNames=useMemo(()=>Array.from({length:effectiveGroupCount},(_,i)=>groupNames[i]?.trim()||`Girone ${String.fromCharCode(65+i)}`),[effectiveGroupCount,groupNames]);
  const fieldNames=useMemo(()=>fieldText.split(',').map(s=>s.trim()).filter(Boolean),[fieldText]);

  function updateGroupName(index:number,value:string){
    setGroupNames(current=>{const next=[...current];next[index]=value;return next;});
  }

  async function create() {
    setError(''); setBusy(true);
    try {
      if(!name.trim()) throw new Error('Dai un nome al torneo.');
      if(parsedTeams.length<2) throw new Error('Inserisci almeno due squadre.');
      if(effectiveGroupCount<1) throw new Error('Inserisci almeno un girone.');
      if(new Set(parsedTeams.map(t=>t.name.toLowerCase())).size!==parsedTeams.length) throw new Error('Ci sono nomi squadra duplicati.');
      if(pins && parsedTeams.some(t=>!t.pin)) throw new Error('Con i PIN attivi usa il formato “Nome squadra | PIN” per ogni riga.');
      if(new Set(resolvedGroupNames.map(g=>g.toLocaleLowerCase('it'))).size!==resolvedGroupNames.length) throw new Error('I nomi dei gironi devono essere diversi tra loro.');
      if(groupAssignmentMode==='manual' && manualGroups.some(group=>group.length<qualifiers)) throw new Error(`Ogni girone deve contenere almeno ${qualifiers} squadre, perché hai scelto ${qualifiers} qualificate per girone.`);
      const toSeconds=(v:string)=>v.trim()===''?null:Math.round(Number(v)*60);
      const toGoal=(v:string)=>v.trim()===''?null:Number(v);
      const input:CreateTournamentInput={
        name,
        slug:slugify(slug||name),
        teams:parsedTeams,
        groupCount:effectiveGroupCount,
        groupNames:resolvedGroupNames,
        teamGroupIndexes,
        fieldNames,
        orderingMode,
        qualifiersPerGroup:qualifiers,
        knockoutEnabled:true,
        thirdPlaceEnabled:thirdPlace,
        pauseEnabled:pause,
        teamPinEnabled:pins,
        rules:{group:{durationSeconds:toSeconds(groupMinutes),goalTarget:toGoal(groupGoals)},knockout:{durationSeconds:toSeconds(koMinutes),goalTarget:toGoal(koGoals)},final:{durationSeconds:toSeconds(finalMinutes),goalTarget:toGoal(finalGoals)},third_place:{durationSeconds:toSeconds(koMinutes),goalTarget:toGoal(koGoals)}}
      };
      const t=await createTournament(input); await onCreated(t);
    } catch(e){setError(e instanceof Error?e.message:String(e));} finally{setBusy(false);}
  }

  return <div className="create-grid">
    <section className="panel form-panel"><div className="eyebrow">1 · IDENTITÀ</div><h2>Torneo</h2><label>Nome</label><input value={name} onChange={(e)=>setName(e.target.value)} placeholder="Summer Cup 2026"/><label>Slug URL</label><input value={slug} onChange={(e)=>setSlug(slugify(e.target.value))} placeholder="summer-cup-2026"/></section>

    <section className="panel form-panel"><div className="eyebrow">2 · SQUADRE</div><h2>Partecipanti</h2>
      <label>Come vuoi assegnare i gironi?<select value={groupAssignmentMode} onChange={(e)=>setGroupAssignmentMode(e.target.value as 'auto'|'manual')}><option value="auto">Distribuzione automatica equilibrata</option><option value="manual">Inserisco le squadre già divise per girone</option></select></label>
      <textarea rows={13} value={teamText} onChange={(e)=>setTeamText(e.target.value)} placeholder={groupAssignmentMode==='manual'?(pins?'Team 1 | 1111\nTeam 2 | 2222\n\nTeam 3 | 3333\nTeam 4 | 4444\nTeam 5 | 5555\n\nTeam 6 | 6666':'Team 1\nTeam 2\n\nTeam 3\nTeam 4\nTeam 5\n\nTeam 6'):(pins?'Pesto Boys | 1234\nSpritz United | 7788':'Pesto Boys\nSpritz United\nBanana FC')}/>
      {groupAssignmentMode==='manual' && <div className="alert info compact"><strong>Una riga vuota = nuovo girone.</strong><br/>Nell'esempio: Team 1–2 nel primo, Team 3–5 nel secondo, Team 6 nel terzo.</div>}
      <label className="check-row"><input type="checkbox" checked={pins} onChange={(e)=>setPins(e.target.checked)}/>Richiedi PIN individuale alle squadre</label>
      <span className="hint">{parsedTeams.length} squadre lette{groupAssignmentMode==='manual'?` · ${manualGroups.length} gironi rilevati`:''}</span>
      {groupAssignmentMode==='manual' && manualGroups.length>0 && <div className="group-import-preview">{manualGroups.map((group,index)=><div key={index}><strong>{resolvedGroupNames[index]??`Girone ${String.fromCharCode(65+index)}`}</strong><span>{group.length} squadre</span><small>{group.map(t=>t.name).join(', ')}</small></div>)}</div>}
    </section>

    <section className="panel form-panel"><div className="eyebrow">3 · STRUTTURA</div><h2>Gironi e campi</h2>
      <div className="two-cols">
        {groupAssignmentMode==='auto'?<label>Numero gironi<input type="number" min="1" max="26" value={groupCount} onChange={(e)=>setGroupCount(Number(e.target.value))}/></label>:<label>Gironi rilevati<input type="number" value={effectiveGroupCount} readOnly/></label>}
        <label>Qualificate/girone<input type="number" min="1" value={qualifiers} onChange={(e)=>setQualifiers(Number(e.target.value))}/></label>
      </div>
      <div className="group-name-list"><label>Nomi personalizzati dei gironi</label>{resolvedGroupNames.map((_,index)=><div className="group-name-row" key={index}><span>{index+1}</span><input value={groupNames[index]??''} onChange={(e)=>updateGroupName(index,e.target.value)} placeholder={`Girone ${String.fromCharCode(65+index)}`}/></div>)}</div>
      <label>Ordine partite<select value={orderingMode} onChange={(e)=>setOrderingMode(e.target.value as typeof orderingMode)}><option value="group_rotation">Una partita per girone a rotazione</option><option value="group_sequential">Un girone alla volta</option></select></label>
      <label>Nomi campi, separati da virgola<input value={fieldText} onChange={(e)=>setFieldText(e.target.value)}/></label>
      <label className="check-row"><input type="checkbox" checked={pause} onChange={(e)=>setPause(e.target.checked)}/>Permetti pausa timer</label><label className="check-row"><input type="checkbox" checked={thirdPlace} onChange={(e)=>setThirdPlace(e.target.checked)}/>Partita 3º/4º posto</label>
    </section>

    <section className="panel form-panel"><div className="eyebrow">4 · REGOLE</div><h2>Tempo e goal</h2><RuleInputs title="Gironi" minutes={groupMinutes} setMinutes={setGroupMinutes} goals={groupGoals} setGoals={setGroupGoals}/><RuleInputs title="Eliminatorie" minutes={koMinutes} setMinutes={setKoMinutes} goals={koGoals} setGoals={setKoGoals}/><RuleInputs title="Finale" minutes={finalMinutes} setMinutes={setFinalMinutes} goals={finalGoals} setGoals={setFinalGoals}/><p className="hint">Lascia vuoto il tempo per giocare solo “primo a N”. Nelle eliminatorie il pareggio a tempo scaduto passa al golden goal.</p></section>
    <section className="panel create-submit"><div><h2>Genera il torneo</h2><p>{groupAssignmentMode==='manual'?'Le squadre verranno inserite esattamente nei gironi indicati dagli spazi vuoti.':'Distribuzione automatica equilibrata nei gironi.'} Il calendario resta round-robin di sola andata e la coda segue la modalità scelta.</p></div>{error&&<div className="alert error">{error}</div>}<div className="inline-actions">{onCancel&&<button className="button secondary" onClick={onCancel}>Annulla</button>}<button className="button primary" disabled={busy} onClick={()=>void create()}>{busy?'Creazione…':'CREA TORNEO'}</button></div></section>
  </div>;
}

function RuleInputs({title,minutes,setMinutes,goals,setGoals}:{title:string;minutes:string;setMinutes:(v:string)=>void;goals:string;setGoals:(v:string)=>void}) { return <div className="rule-row"><strong>{title}</strong><label>min<input type="number" min="1" value={minutes} onChange={(e)=>setMinutes(e.target.value)}/></label><span>oppure</span><label>goal<input type="number" min="1" value={goals} onChange={(e)=>setGoals(e.target.value)}/></label></div>; }
function Stat({n,label}:{n:number;label:string}){return <div><strong>{n}</strong><span>{label}</span></div>;}
function KeyValue({k,v}:{k:string;v:string}){return <div className="key-value"><span>{k}</span><strong>{v}</strong></div>;}
function teamName(bundle:TournamentBundle,id:string|null){return bundle.teams.find(t=>t.id===id)?.name??'Da definire';}
function tabTitle(tab:AdminTab){return {live:'Torneo live',teams:'Squadre',groups:'Gironi',bracket:'Tabellone',matches:'Partite',fields:'Campi',settings:'Impostazioni'}[tab];}
function CenteredAdmin({title}:{title:string}){return <main className="page page-centered"><section className="login-card"><h2>{title}</h2></section></main>;}
interface AdminPanelProps{bundle:TournamentBundle;refresh:()=>Promise<void>;setError:(s:string)=>void;}
