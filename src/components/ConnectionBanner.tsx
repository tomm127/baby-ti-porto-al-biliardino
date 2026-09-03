export function ConnectionBanner({ online, cachedAt }: { online: boolean; cachedAt?: string | null }) {
  if (online && !cachedAt) return null;
  const time = cachedAt ? new Date(cachedAt).toLocaleTimeString('it-IT', { hour: '2-digit', minute: '2-digit' }) : null;
  return <div className={online ? 'connection-banner stale' : 'connection-banner offline'} role="status">
    <strong>{online ? 'Dati temporaneamente non aggiornati' : 'Sei offline'}</strong>
    <span>{time ? `Mostro l'ultima copia salvata delle ${time}.` : 'I comandi verranno riattivati appena torna la connessione.'}</span>
  </div>;
}
