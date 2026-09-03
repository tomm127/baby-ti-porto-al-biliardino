import { createClient, type Session } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;

export const hasSupabaseConfig = Boolean(url && key);

export const supabase = hasSupabaseConfig
  ? createClient(url!, key!, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null;

let anonymousSessionPromise: Promise<Session | null> | null = null;

export async function ensureAnonymousPlayerSession() {
  if (!supabase) return null;
  const { data: sessionData } = await supabase.auth.getSession();
  if (sessionData.session) return sessionData.session;

  if (!anonymousSessionPromise) {
    anonymousSessionPromise = supabase.auth.signInAnonymously()
      .then(({ data, error }) => {
        if (error) throw error;
        return data.session;
      })
      .finally(() => { anonymousSessionPromise = null; });
  }
  return anonymousSessionPromise;
}

export async function adminLogin(password: string) {
  if (!supabase) throw new Error('Supabase non configurato');
  const email = import.meta.env.VITE_ADMIN_EMAIL as string | undefined;
  if (!email) throw new Error('VITE_ADMIN_EMAIL non configurata');

  const { data, error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) throw error;
  return data.session;
}
