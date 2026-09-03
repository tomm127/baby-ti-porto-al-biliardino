import { ensureAnonymousPlayerSession, hasSupabaseConfig, supabase } from './supabase.ts';

export type NotificationState = 'unsupported' | 'needs-install' | 'default' | 'denied' | 'enabled' | 'disabled';

function client() {
  if (!supabase || !hasSupabaseConfig) throw new Error('Supabase non configurato.');
  return supabase;
}

export function isStandaloneApp() {
  return window.matchMedia?.('(display-mode: standalone)').matches
    || (navigator as Navigator & { standalone?: boolean }).standalone === true;
}

export function isIOSLike() {
  const ua = navigator.userAgent;
  return /iPad|iPhone|iPod/.test(ua) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

export function supportsWebPush() {
  return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}

export async function ensureServiceWorker() {
  if (!('serviceWorker' in navigator)) throw new Error('Service worker non supportato.');
  const existing = await navigator.serviceWorker.getRegistration('/');
  if (existing) return existing;
  await navigator.serviceWorker.register('/sw.js', { scope: '/' });
  return navigator.serviceWorker.ready;
}

function base64UrlToUint8Array(base64Url: string) {
  const padding = '='.repeat((4 - (base64Url.length % 4)) % 4);
  const base64 = (base64Url + padding).replace(/-/g, '+').replace(/_/g, '/');
  const raw = window.atob(base64);
  return Uint8Array.from([...raw].map((char) => char.charCodeAt(0)));
}

export async function getNotificationState(): Promise<NotificationState> {
  if (!supportsWebPush()) return 'unsupported';
  if (isIOSLike() && !isStandaloneApp()) return 'needs-install';
  if (Notification.permission === 'denied') return 'denied';
  if (Notification.permission === 'default') return 'default';

  const registration = await ensureServiceWorker();
  const subscription = await registration.pushManager.getSubscription();
  return subscription ? 'enabled' : 'disabled';
}

export async function enableNotifications(tournamentId: string): Promise<void> {
  if (!supportsWebPush()) throw new Error('Questo browser non supporta le notifiche push web.');
  if (isIOSLike() && !isStandaloneApp()) {
    throw new Error('Su iPhone/iPad aggiungi prima l’app alla schermata Home, poi aprila dall’icona e attiva le notifiche.');
  }

  const permission = await Notification.requestPermission();
  if (permission !== 'granted') {
    throw new Error(permission === 'denied' ? 'Permesso notifiche negato.' : 'Permesso notifiche non concesso.');
  }

  const vapidPublicKey = import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined;
  if (!vapidPublicKey) throw new Error('VITE_VAPID_PUBLIC_KEY non configurata.');

  const session = await ensureAnonymousPlayerSession();
  if (!session?.user.id) throw new Error('Sessione dispositivo non disponibile.');

  const registration = await ensureServiceWorker();
  let subscription = await registration.pushManager.getSubscription();
  if (!subscription) {
    subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: base64UrlToUint8Array(vapidPublicKey),
    });
  }

  const json = subscription.toJSON();
  const p256dh = json.keys?.p256dh;
  const auth = json.keys?.auth;
  if (!p256dh || !auth) throw new Error('Il browser non ha restituito le chiavi della subscription push.');

  const { error } = await client().from('push_subscriptions').upsert({
    user_id: session.user.id,
    endpoint: subscription.endpoint,
    p256dh,
    auth_key: auth,
    user_agent: navigator.userAgent,
    enabled: true,
    last_seen_at: new Date().toISOString(),
  }, { onConflict: 'user_id,endpoint' });
  if (error) throw error;

  // If this team is already currently called or is exactly next in the queue,
  // create the relevant notification now that the device has subscribed.
  const { error: enqueueError } = await client().rpc('enqueue_current_notification_for_me', { p_tournament_id: tournamentId });
  if (enqueueError) throw enqueueError;
  await dispatchPendingPushes();
}

export async function disableNotifications(): Promise<void> {
  if (!supportsWebPush()) return;
  const registration = await ensureServiceWorker();
  const subscription = await registration.pushManager.getSubscription();
  if (!subscription) return;

  const { data: sessionData } = await client().auth.getSession();
  const userId = sessionData.session?.user.id;
  if (userId) {
    const { error } = await client()
      .from('push_subscriptions')
      .delete()
      .eq('user_id', userId)
      .eq('endpoint', subscription.endpoint);
    if (error) throw error;
  }
  await subscription.unsubscribe();
}

export async function dispatchPendingPushes(): Promise<void> {
  const { error } = await client().functions.invoke('send-push', { body: {} });
  if (error) throw error;
}
