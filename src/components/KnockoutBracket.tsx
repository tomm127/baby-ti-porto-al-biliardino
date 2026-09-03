import type { MatchRow, TournamentBundle } from '../lib/api.ts';

export function KnockoutBracket({ bundle, compact = false }: { bundle: TournamentBundle; compact?: boolean }) {
  const rounds = [...bundle.knockoutRounds].sort((a, b) => a.round_number - b.round_number);
  const third = bundle.matches.find((m) => m.stage === 'third_place');

  if (rounds.length === 0) {
    return <div className={compact ? 'bracket-empty compact' : 'bracket-empty'}>
      <strong>Tabellone non ancora generato</strong>
      <span>Comparirà automaticamente quando saranno concluse tutte le partite dei gironi.</span>
    </div>;
  }

  return <div className={compact ? 'knockout-wrap compact' : 'knockout-wrap'}>
    <div className="knockout-scroll">
      <div className="knockout-grid">
        {rounds.map((round) => {
          const matches = bundle.matches
            .filter((m) => m.knockout_round_id === round.id)
            .sort((a, b) => (a.bracket_slot ?? 999) - (b.bracket_slot ?? 999));
          return <section className="knockout-round" key={round.id}>
            <div className="knockout-round-title"><strong>{round.name}</strong><span>{matches.length} {matches.length === 1 ? 'partita' : 'partite'}</span></div>
            <div className="knockout-round-matches">
              {matches.map((match) => <BracketMatch key={match.id} match={match} bundle={bundle} compact={compact} />)}
            </div>
          </section>;
        })}
        {third && <section className="knockout-round third-place-column">
          <div className="knockout-round-title"><strong>3º / 4º posto</strong><span>finalina</span></div>
          <div className="knockout-round-matches"><BracketMatch match={third} bundle={bundle} compact={compact} /></div>
        </section>}
      </div>
    </div>
  </div>;
}

export function QualificationRanking({ bundle }: { bundle: TournamentBundle }) {
  if (!bundle.qualifiers.length) return null;
  return <section className="panel qualification-panel">
    <div className="panel-title"><h2>Ranking qualificate</h2><span>seeding globale</span></div>
    <div className="qualification-list">
      {bundle.qualifiers.map((q) => <div className="qualification-row" key={q.team_id}>
        <span className="seed-badge">#{q.global_seed}</span>
        <strong>{teamName(bundle, q.team_id)}</strong>
        <span>{groupName(bundle, q.group_id)} · {q.group_rank}ª</span>
        <span>{trimNumber(q.points_per_game)} pt/p</span>
        <span>DR/p {signedNumber(q.goal_difference_per_game)}</span>
      </div>)}
    </div>
  </section>;
}

function BracketMatch({ match, bundle, compact }: { match: MatchRow; bundle: TournamentBundle; compact: boolean }) {
  const team1 = teamName(bundle, match.team1_id);
  const team2 = teamName(bundle, match.team2_id);
  const seed1 = seedFor(bundle, match.team1_id);
  const seed2 = seedFor(bundle, match.team2_id);
  const bye = match.status === 'finished' && match.score_team1 == null && match.score_team2 == null && Boolean(match.winner_team_id);
  const scoreReady = match.score_team1 != null && match.score_team2 != null;

  return <div className={`bracket-match status-${match.status}${bye ? ' bye' : ''}`}>
    <div className={match.winner_team_id === match.team1_id ? 'bracket-team winner' : 'bracket-team'}>
      <span className="bracket-seed">{seed1 ? `#${seed1}` : '·'}</span>
      <strong>{team1}</strong>
      <span className="bracket-score">{scoreReady ? match.score_team1 : ''}</span>
    </div>
    <div className={match.winner_team_id === match.team2_id ? 'bracket-team winner' : 'bracket-team'}>
      <span className="bracket-seed">{seed2 ? `#${seed2}` : '·'}</span>
      <strong>{team2}</strong>
      <span className="bracket-score">{scoreReady ? match.score_team2 : ''}</span>
    </div>
    {!compact && <div className="bracket-status">{bye ? 'BYE' : statusLabel(match.status)}</div>}
  </div>;
}

function teamName(bundle: TournamentBundle, id: string | null) {
  if (!id) return 'Da definire';
  return bundle.teams.find((team) => team.id === id)?.name ?? 'Da definire';
}
function groupName(bundle: TournamentBundle, id: string) { return bundle.groups.find((group) => group.id === id)?.name ?? 'Girone'; }
function seedFor(bundle: TournamentBundle, teamId: string | null) { return bundle.qualifiers.find((q) => q.team_id === teamId)?.global_seed ?? null; }
function trimNumber(value: number) { return Number(value).toFixed(2).replace(/\.00$/, '').replace(/(\.\d)0$/, '$1'); }
function signedNumber(value: number) { const text = trimNumber(value); return Number(value) > 0 ? `+${text}` : text; }
function statusLabel(status: MatchRow['status']) {
  const labels: Record<MatchRow['status'], string> = {
    scheduled:'DA DEFINIRE', queued:'IN CODA', called:'CHIAMATA', ready:'PRONTA', playing:'IN CORSO', awaiting_result:'RISULTATO',
    finished:'FINITA', postponed:'RIMANDATA', cancelled:'ANNULLATA', forfeit:'TAVOLINO',
  };
  return labels[status];
}
