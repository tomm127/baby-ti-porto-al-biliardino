import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import { DEFAULT_LANGUAGE, LANGUAGE_STORAGE_KEY, normalizeLanguage, readLanguage, saveLanguage, translate, type Language } from './language.ts';

type LanguageContextValue = {
  language: Language;
  setLanguage: (language: Language) => void;
  t: (english: string, italian: string) => string;
};

const LanguageContext = createContext<LanguageContextValue | null>(null);

function browserStorage(): Storage | undefined {
  try { return window.localStorage; }
  catch { return undefined; }
}

export function LanguageProvider({ children }: { children: ReactNode }) {
  const [language, setCurrentLanguage] = useState(() => readLanguage(browserStorage()));
  const setLanguage = useCallback((next: Language) => {
    setCurrentLanguage(next);
    saveLanguage(browserStorage(), next);
  }, []);

  useEffect(() => {
    document.documentElement.lang = language;
  }, [language]);

  useEffect(() => {
    const onStorage = (event: StorageEvent) => {
      if (event.key === LANGUAGE_STORAGE_KEY) setCurrentLanguage(normalizeLanguage(event.newValue));
      if (event.key === null) setCurrentLanguage(DEFAULT_LANGUAGE);
    };
    window.addEventListener('storage', onStorage);
    return () => window.removeEventListener('storage', onStorage);
  }, []);

  const value = useMemo<LanguageContextValue>(() => ({
    language,
    setLanguage,
    t: (english, italian) => translate(language, english, italian),
  }), [language, setLanguage]);

  return <LanguageContext.Provider value={value}>{children}</LanguageContext.Provider>;
}

export function useLanguage(): LanguageContextValue {
  const value = useContext(LanguageContext);
  if (!value) throw new Error('useLanguage requires LanguageProvider');
  return value;
}
