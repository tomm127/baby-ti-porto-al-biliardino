export type Language = 'en' | 'it';
export const DEFAULT_LANGUAGE: Language = 'en';
export const LANGUAGE_STORAGE_KEY = 'btpb:language';

type LanguageStorage = Pick<Storage, 'getItem' | 'setItem'>;

export function normalizeLanguage(value: unknown): Language {
  return value === 'it' ? 'it' : DEFAULT_LANGUAGE;
}

export function readLanguage(storage?: LanguageStorage): Language {
  try { return normalizeLanguage(storage?.getItem(LANGUAGE_STORAGE_KEY)); }
  catch { return DEFAULT_LANGUAGE; }
}

export function saveLanguage(storage: LanguageStorage | undefined, language: Language): void {
  try { storage?.setItem(LANGUAGE_STORAGE_KEY, language); }
  catch { /* The app still works when browser storage is unavailable. */ }
}

export function translate(language: Language, english: string, italian: string): string {
  return language === 'it' ? italian : english;
}
