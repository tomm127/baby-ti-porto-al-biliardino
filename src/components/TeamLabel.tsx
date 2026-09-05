import type { TournamentBundle } from '../lib/api.ts';

export function TeamLabel({
  bundle,
  teamId,
  name,
  className = '',
}: {
  bundle: TournamentBundle;
  teamId: string | null;
  name?: string;
  className?: string;
}) {
  const team = teamId ? bundle.teams.find((candidate) => candidate.id === teamId) : undefined;
  const label = name ?? team?.name ?? 'Da definire';

  return <span className={`team-label${className ? ` ${className}` : ''}`}>
    {team?.avatar_url && <img
      key={team.avatar_url}
      className="team-label-avatar"
      src={team.avatar_url}
      alt=""
      loading="lazy"
      decoding="async"
      onError={(event) => { event.currentTarget.hidden = true; }}
    />}
    <span className="team-label-text">{label}</span>
  </span>;
}
