# Baby ti porto al biliardino — Step 6

Step 6 adds:

- installable PWA metadata + icons
- standards-based Web Push subscriptions
- "Preparatevi" notification for the single strict queue-head match
- "È IL VOSTRO TURNO" notification when a field is assigned
- notification click opens the tournament/match
- system notification vibration hints where supported
- push subscription persistence in Supabase
- server-side notification outbox
- Supabase Edge Function that sends encrypted Web Push messages using VAPID
- late opt-in: if a player enables notifications after becoming next/called, the relevant current alert is queued immediately

The tournament engine ordering remains unchanged and strict.

## Files added/changed

- `supabase/migrations/004_push_notifications.sql`
- `supabase/functions/send-push/index.ts`
- `src/lib/notifications.ts`
- `src/lib/pwaInstall.ts`
- `public/sw.js`
- `public/manifest.webmanifest`
- `public/icons/*`
- `scripts/generate-vapid.mjs`
- `.env.example`

## Setup

### 1. Apply migration 004

Supabase > SQL Editor > New query.
Run all of:

`supabase/migrations/004_push_notifications.sql`

Do not rerun 001–003 if already applied.

### 2. Generate VAPID keys locally

From the project folder:

```bash
node scripts/generate-vapid.mjs
```

It prints:

```text
VAPID_PUBLIC_KEY=...
VAPID_PRIVATE_KEY=...
```

Keep the private key secret.

### 3. Add the public VAPID key to the local frontend

Add one line to `.env.local`:

```env
VITE_VAPID_PUBLIC_KEY=YOUR_PUBLIC_KEY
```

Restart `npm run dev` after changing `.env.local`.

### 4. Add VAPID secrets to Supabase

Supabase > Edge Functions > Secrets.
Add:

```text
VAPID_PUBLIC_KEY = same public key
VAPID_PRIVATE_KEY = private key
VAPID_SUBJECT = mailto:YOUR_EMAIL
```

Do not add the VAPID private key to `.env.local` or frontend code.

### 5. Deploy Edge Function

Supabase > Edge Functions > Deploy a new function > Via Editor.

Name:

```text
send-push
```

Paste the complete contents of:

`supabase/functions/send-push/index.ts`

Deploy the function with JWT verification enabled (default).

### 6. Restart the local app

```bash
npm run dev
```

Open the player interface, choose a team, and use the new "Attiva notifiche" button.

On desktop Chrome/Edge, localhost is sufficient for testing Web Push.

### 7. Verify the subscription

Supabase > Table Editor > `push_subscriptions`.

After enabling notifications, there should be a row for that device/user.

### 8. Test the flow

Use a small tournament with at least two fields/queued matches.

- a subscribed team's match reaches the strict queue head -> `Preparatevi`
- when a field is assigned -> `È IL VOSTRO TURNO!`
- tapping the second notification opens `/tournament/<slug>/match/<match-id>`

Notification delivery is triggered after queue-advancing client actions such as tournament start, result submission, or admin postpone. Notification sending failure does not block tournament progression.

## iPhone / iPad

Web Push is supported for Home Screen web apps. For a real iPhone test, deploy the app to an HTTPS URL first, add it to the Home Screen, open it from its icon, then tap "Attiva notifiche". The app UI shows the install hint when needed.

## Important behavior

Push sound/vibration ultimately follows the user's operating-system notification settings, Focus/Do Not Disturb, and browser support. The service worker supplies vibration hints where the platform honors them; the app cannot force a device to make sound.
