import { useLanguage } from '../lib/i18n.tsx';

export function ConnectionBanner({ online, cachedAt }: { online: boolean; cachedAt?: string | null }) {
  const { language, t } = useLanguage();
  if (online && !cachedAt) return null;
  const time = cachedAt ? new Date(cachedAt).toLocaleTimeString(language === 'it' ? 'it-IT' : 'en-GB', { hour: '2-digit', minute: '2-digit' }) : null;
  return <div className={online ? 'connection-banner stale' : 'connection-banner offline'} role="status">
    <strong>{online ? t('Data temporarily out of date', 'Dati temporaneamente non aggiornati') : t('You are offline', 'Sei offline')}</strong>
    <span>{time ? t(`Showing the last saved copy from ${time}.`, `Mostro l'ultima copia salvata delle ${time}.`) : t('Controls will be re-enabled when the connection returns.', 'I comandi verranno riattivati appena torna la connessione.')}</span>
  </div>;
}
