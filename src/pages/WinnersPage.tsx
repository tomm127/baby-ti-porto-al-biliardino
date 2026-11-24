import { navigate } from '../router.ts';
import { useLanguage } from '../lib/i18n.tsx';
import { LanguageSwitch } from '../components/LanguageSwitch.tsx';

export function WinnersPage() {
  const { t } = useLanguage();
  const placeholders = [
    { id: 'champions', category: t('Champions', 'Campioni'), description: t('Overall tournament winners', 'Vincitori assoluti del torneo') },
    { id: 'award', category: t('Special award', 'Premio speciale'), description: t('Category to be announced', 'Categoria da definire') },
    { id: 'pair', category: t('Best pair', 'Miglior coppia'), description: t('Category to be announced', 'Categoria da definire') },
  ];
  return (
    <main className="page winners-page">
      <section className="winners-shell">
        <header className="winners-header">
          <button className="winners-back" aria-label={t("Back", "Indietro")} onClick={() => navigate('/')}>←</button>
          <div>
            <span>Baby Ti Porto al Biliardino</span>
            <h1>{t("Hall of fame", "Albo vincitori")}</h1>
          </div>
          <div className="winners-language-control"><LanguageSwitch /></div>
        </header>

        <div className="winners-intro">
          <img src="/brand/btpb-logo.png" alt="" />
          <div>
            <strong>{t("Tournament history", "La storia del torneo")}</strong>
            <p>{t("This page will collect winners, categories and photos from previous editions.", "Qui raccoglieremo vincitori, categorie e foto delle edizioni passate.")}</p>
          </div>
        </div>

        <section className="winners-year">
          <div className="winners-year-title">
            <span>{t("EDITION", "EDIZIONE")}</span>
            <h2>{t("Coming soon", "Prossimamente")}</h2>
          </div>

          <div className="winners-category-grid">
            {placeholders.map((item) => (
              <article className="winner-placeholder-card" key={item.id}>
                <div className="winner-photo-placeholder">
                  <span>{t("PHOTO", "FOTO")}</span>
                </div>
                <div>
                  <span>{item.category}</span>
                  <h3>{t("To be added", "Da aggiungere")}</h3>
                  <p>{item.description}</p>
                </div>
              </article>
            ))}
          </div>
        </section>

        <p className="winners-coming-soon">
          {t("Years, categories, names and photos will be added in a future release.", "Struttura pronta. Aggiungeremo anni, categorie, nomi e fotografie in un secondo momento.")}
        </p>
      </section>
    </main>
  );
}
