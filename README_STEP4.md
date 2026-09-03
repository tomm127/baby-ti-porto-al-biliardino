# Baby ti porto al biliardino — Step 4: React/PWA shell

The application now has one codebase and four routes:

- `/` tournament selection landing page
- `/tournament/:id` player/mobile view
- `/admin` admin view
- `/screen/:id` public TV/dashboard view

For now these screens use mock tournament data so layout and navigation can be built before wiring each query to Supabase.

## Local run

1. Install Node.js 22+.
2. From this folder run `npm install`.
3. Copy `.env.example` to `.env.local` and add your Supabase URL/publishable key when ready.
4. Run `npm run dev`.
5. Open `http://localhost:5173`.

## PWA

A basic manifest and service worker are present. Icons and full offline behavior will be completed later. The service worker registers only in production builds.

## Next

Connect real Supabase data in this order:
1. active tournament list
2. anonymous player session
3. team selection/claim
4. admin password login
5. admin tournament setup wizard
6. live match RPC controls
