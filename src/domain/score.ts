// Match scores must be explicitly entered and fit the PostgreSQL integer type.
export function parseMatchScore(raw: string): number | null {
  const value = raw.trim();
  if (!/^\d+$/.test(value)) return null;
  const score = Number(value);
  return Number.isSafeInteger(score) && score <= 2147483647 ? score : null;
}
