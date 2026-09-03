import { createClient } from 'npm:@supabase/supabase-js@2.112.4';
import webpush from 'npm:web-push@3.6.7';

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

type PushJob = {
  id: number;
  tournament_id: string;
  match_id: string | null;
  user_id: string;
  kind: 'prepare' | 'called';
  title: string;
  body: string;
  url: string;
  payload: Record<string, unknown>;
};

type SubscriptionRow = {
  id: string;
  endpoint: string;
  p256dh: string;
  auth_key: string;
};

function getFirstKey(raw: string | undefined) {
  if (!raw) return undefined;
  const parsed = JSON.parse(raw) as Record<string, string>;
  return parsed.default ?? Object.values(parsed)[0];
}

function getAdminKey() {
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? getFirstKey(Deno.env.get('SUPABASE_SECRET_KEYS'));
  if (!key) throw new Error('Supabase secret key unavailable');
  return key;
}

function getPublishableKey() {
  const key = Deno.env.get('SUPABASE_ANON_KEY') ?? getFirstKey(Deno.env.get('SUPABASE_PUBLISHABLE_KEYS'));
  if (!key) throw new Error('Supabase publishable key unavailable');
  return key;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader?.startsWith('Bearer ')) {
      return new Response(JSON.stringify({ error: 'Authentication required' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL');
    if (!supabaseUrl) throw new Error('SUPABASE_URL missing');

    // Verify that this invocation comes from a real Supabase user (anonymous
    // player or admin), then perform the outbox work with the secret key.
    const verifier = createClient(supabaseUrl, getPublishableKey(), {
      global: { headers: { Authorization: authHeader } },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: userData, error: userError } = await verifier.auth.getUser();
    if (userError || !userData.user) {
      return new Response(JSON.stringify({ error: 'Invalid user session' }), {
        status: 401,
        headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      });
    }

    const vapidPublic = Deno.env.get('VAPID_PUBLIC_KEY');
    const vapidPrivate = Deno.env.get('VAPID_PRIVATE_KEY');
    const vapidSubject = Deno.env.get('VAPID_SUBJECT') ?? 'mailto:admin@example.com';
    if (!vapidPublic || !vapidPrivate) throw new Error('VAPID secrets missing');
    webpush.setVapidDetails(vapidSubject, vapidPublic, vapidPrivate);

    const admin = createClient(supabaseUrl, getAdminKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: jobsData, error: jobsError } = await admin.rpc('claim_push_jobs', { p_limit: 50 });
    if (jobsError) throw jobsError;
    const jobs = (jobsData ?? []) as PushJob[];

    let sent = 0;
    let failed = 0;
    let subscriptionsRemoved = 0;

    for (const job of jobs) {
      const { data: subscriptionsData, error: subscriptionsError } = await admin
        .from('push_subscriptions')
        .select('id,endpoint,p256dh,auth_key')
        .eq('user_id', job.user_id)
        .eq('enabled', true);

      if (subscriptionsError) {
        await admin.rpc('complete_push_job', {
          p_job_id: job.id,
          p_success: false,
          p_error: subscriptionsError.message,
        });
        failed++;
        continue;
      }

      const subscriptions = (subscriptionsData ?? []) as SubscriptionRow[];
      // A player may simply not have enabled notifications. That is not a
      // delivery failure; future events can still work once they subscribe.
      if (subscriptions.length === 0) {
        await admin.rpc('complete_push_job', { p_job_id: job.id, p_success: true, p_error: null });
        continue;
      }

      const payload = JSON.stringify({
        title: job.title,
        body: job.body,
        url: job.url,
        kind: job.kind,
        tag: `${job.kind}:${job.match_id ?? job.id}`,
        data: job.payload,
      });

      let anySuccess = false;
      const errors: string[] = [];

      for (const subscription of subscriptions) {
        try {
          await webpush.sendNotification(
            {
              endpoint: subscription.endpoint,
              keys: { p256dh: subscription.p256dh, auth: subscription.auth_key },
            },
            payload,
            { TTL: job.kind === 'called' ? 300 : 900, urgency: 'high' },
          );
          anySuccess = true;
        } catch (error) {
          const statusCode = typeof error === 'object' && error && 'statusCode' in error
            ? Number((error as { statusCode?: number }).statusCode)
            : 0;
          const errorMessage = error instanceof Error ? error.message : String(error);
          errors.push(errorMessage);

          // Browser invalidated/unsubscribed this endpoint: remove it.
          if (statusCode === 404 || statusCode === 410) {
            await admin.from('push_subscriptions').delete().eq('id', subscription.id);
            subscriptionsRemoved++;
          }
        }
      }

      await admin.rpc('complete_push_job', {
        p_job_id: job.id,
        p_success: anySuccess,
        p_error: anySuccess ? null : errors.join(' | ').slice(0, 1000),
      });

      if (anySuccess) sent++;
      else failed++;
    }

    return new Response(JSON.stringify({ claimed: jobs.length, sent, failed, subscriptionsRemoved }), {
      status: 200,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return new Response(JSON.stringify({ error: message }), {
      status: 500,
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  }
});
