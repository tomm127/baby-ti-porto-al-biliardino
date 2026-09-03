import { navigate } from '../router.ts';

const placeholders = [
  { category: 'Campioni', description: 'Vincitori assoluti del torneo' },
  { category: 'Premio speciale', description: 'Categoria da definire' },
  { category: 'Miglior coppia', description: 'Categoria da definire' },
];

export function WinnersPage() {
  return (
    <main className="page winners-page">
      <section className="winners-shell">
        <header className="winners-header">
          <button className="winners-back" onClick={() => navigate('/')}>←</button>
          <div>
            <span>Baby Ti Porto al Biliardino</span>
            <h1>Albo vincitori</h1>
          </div>
        </header>

        <div className="winners-intro">
          <img src="/brand/btpb-logo.png" alt="" />
          <div>
            <strong>La storia del torneo</strong>
            <p>Qui raccoglieremo vincitori, categorie e foto delle edizioni passate.</p>
          </div>
        </div>

        <section className="winners-year">
          <div className="winners-year-title">
            <span>EDIZIONE</span>
            <h2>Prossimamente</h2>
          </div>

          <div className="winners-category-grid">
            {placeholders.map((item) => (
              <article className="winner-placeholder-card" key={item.category}>
                <div className="winner-photo-placeholder">
                  <span>FOTO</span>
                </div>
                <div>
                  <span>{item.category}</span>
                  <h3>Da aggiungere</h3>
                  <p>{item.description}</p>
                </div>
              </article>
            ))}
          </div>
        </section>

        <p className="winners-coming-soon">
          Struttura pronta. Aggiungeremo anni, categorie, nomi e fotografie in un secondo momento.
        </p>
      </section>
    </main>
  );
}
