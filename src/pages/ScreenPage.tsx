import { useCallback, useEffect, useMemo, useState } from 'react';
import { calculateStandings, type PlayedMatch, type Team as EngineTeam } from '../domain/index.ts';
import { loadTournamentBundleResilient, type MatchRow, type TournamentBundle } from '../lib/api.ts';
import { countdownRemaining, formatClock, secondsRemaining } from '../lib/time.ts';
import { useConnectivity } from '../lib/useConnectivity.ts';
import { navigate } from '../router.ts';
import { KnockoutBracket } from '../components/KnockoutBracket.tsx';
import { ConnectionBanner } from '../components/ConnectionBanner.tsx';

export function ScreenPage({ slug }: { slug: string }) {
  const [bundle,setBundle]=useState<TournamentBundle|null>(null);
  const [error,setError]=useState('');
  const [cachedAt,setCachedAt]=useState<string|null>(null);
  const [,setTick]=useState(Date.now());
  const refresh=useCallback(async()=>{try{const result=await loadTournamentBundleResilient(slug);setBundle(result.bundle);setCachedAt(result.source==='cache'?result.cachedAt:null);setError('');}catch(e){setError(e instanceof Error?e.message:String(e));}},[slug]);
  const online=useConnectivity(()=>void refresh());
  useEffect(()=>{void refresh();},[refresh]);
  useEffect(()=>{if(!online)return;const id=window.setInterval(()=>void refresh(),5000);return()=>window.clearInterval(id);},[refresh,online]);
  useEffect(()=>{const id=window.setInterval(()=>setTick(Date.now()),500);return()=>window.clearInterval(id);},[]);

  const standings=useMemo(()=>bundle?buildStandings(bundle):[],[bundle]);
  if(!bundle)return <main className="screen-mode"><header><h1>{error||'Caricamento…'}</h1><button className="screen-exit" onClick={()=>navigate('/')}>Esci</button></header></main>;
  const live=bundle.matches.filter(m=>['called','ready','playing','awaiting_result'].includes(m.status));
  const byField=new Map(live.filter(m=>m.field_id).map(m=>[m.field_id!,m]));
  const queue=bundle.matches.filter(m=>m.status==='queued').sort((a,b)=>(a.queue_position??999999)-(b.queue_position??999999)).slice(0,8);

  return <main className="screen-mode">
    <ConnectionBanner online={online} cachedAt={cachedAt}/>
    <header><div><div className="eyebrow">{bundle.tournament.name}</div><h1>Baby ti porto al biliardino</h1></div><button className="screen-exit" onClick={()=>navigate('/')}>Esci</button></header>
    {error&&<div className="alert error">{error}</div>}
    <section className="screen-fields">{bundle.fields.filter(f=>f.is_active).map(f=><ScreenField key={f.id} name={f.name} match={byField.get(f.id)} bundle={bundle}/>)}</section>
    <section className="screen-bottom"><div className="screen-panel"><h2>Prossime</h2>{queue.length===0&&<div className="screen-muted">Nessuna partita in coda</div>}{queue.map((m,i)=><div className="screen-next" key={m.id}><span>{i+1}</span><strong>{teamName(bundle,m.team1_id)} vs {teamName(bundle,m.team2_id)}</strong></div>)}</div>{bundle.tournament.phase==='groups'?<div className="screen-panel standings-screen"><h2>Classifiche</h2>{standings.map(g=><div className="screen-group" key={g.id}><h3>{g.name}</h3>{g.rows.slice(0,6).map((r,i)=><div className="screen-standing" key={r.teamId}><strong>{i+1}. {r.teamName}</strong><span>{r.points} pt · {r.goalDifference>0?'+':''}{r.goalDifference}</span></div>)}</div>)}</div>:<div className="screen-panel screen-bracket-panel"><h2>Tabellone</h2><KnockoutBracket bundle={bundle} compact /></div>}</section>
  </main>;
}

function ScreenField({name,match,bundle}:{name:string;match?:MatchRow;bundle:TournamentBundle}){
  if(!match)return <div className="screen-field free"><div className="eyebrow">{name}</div><strong>CAMPO LIBERO</strong><div className="screen-free-mark">✓</div></div>;
  const countdown=countdownRemaining(match.started_at);
  const remaining=secondsRemaining(match);
  let clock='PRONTI';
  if(match.status==='playing'&&countdown>0)clock=String(countdown);
  else if(match.status==='playing')clock=match.duration_seconds==null?'IN CORSO':formatClock(remaining);
  else if(match.status==='awaiting_result')clock='RISULTATO';
  return <div className="screen-field"><div className="eyebrow">{name}</div><strong>{teamName(bundle,match.team1_id)}</strong><span>VS</span><strong>{teamName(bundle,match.team2_id)}</strong><div>{clock}</div></div>;
}

function buildStandings(bundle:TournamentBundle){return bundle.groups.map(group=>{const members=bundle.groupTeams.filter(gt=>gt.group_id===group.id);const teams:EngineTeam[]=members.map(gt=>({id:gt.team_id,name:teamName(bundle,gt.team_id),lotOrder:gt.lot_order}));const played:PlayedMatch[]=bundle.matches.filter(m=>m.group_id===group.id&&['finished','forfeit'].includes(m.status)&&m.team1_id&&m.team2_id&&m.score_team1!=null&&m.score_team2!=null).map(m=>({id:m.id,groupId:group.id,team1Id:m.team1_id!,team2Id:m.team2_id!,scoreTeam1:m.score_team1!,scoreTeam2:m.score_team2!}));return{id:group.id,name:group.name,rows:calculateStandings(teams,played)};});}
function teamName(bundle:TournamentBundle,id:string|null){return bundle.teams.find(t=>t.id===id)?.name??'Da definire';}
