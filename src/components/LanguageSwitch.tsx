import { useLanguage } from '../lib/i18n.tsx';
import './LanguageSwitch.css';

export function LanguageSwitch() {
  const { language, setLanguage, t } = useLanguage();
  return <div className="btpb-language-switch" role="group" aria-label={t('Language', 'Lingua')}>
    <button type="button" lang="en" aria-label="English" aria-pressed={language === 'en'} onClick={() => setLanguage('en')}>EN</button>
    <button type="button" lang="it" aria-label="Italiano" aria-pressed={language === 'it'} onClick={() => setLanguage('it')}>IT</button>
  </div>;
}

export function LanguagePreferenceRow() {
  const { t } = useLanguage();
  return <div className="player-language-row">
    <span>{t('Language', 'Lingua')}</span>
    <LanguageSwitch />
  </div>;
}
