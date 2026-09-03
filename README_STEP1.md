# Baby ti porto al biliardino — Step 1

This folder contains the first database migration for the tournament platform.

## What is already modeled

- Multiple tournaments and permanent archive
- One admin identity
- Invisible anonymous identities for player devices
- Teams, optional per-team PINs, groups and manual/automatic assignment support
- Custom named fields
- Round-robin group matches
- Rigid live queue
- Match state machine
- Synchronized timer state with pause/resume support
- Different rules for groups, knockout, final and third-place match
- Knockout rounds and source-match links for automatic bracket advancement
- Multiple devices attached to the same team
- Push notification subscriptions
- Base standings statistics
- Match events and audit log
- Row Level Security

## Important security model

Players do not create a visible account. On first app launch the frontend will call `signInAnonymously()` and Supabase persists the session on the device. The UI then calls the `claim_team()` RPC to associate that anonymous device with a team.

The admin is a single permanent Supabase Auth user. The admin screen will ask only for a password; the fixed technical email/identifier can remain hidden from the UI. That Auth user's UUID is inserted once into `public.admin_users`.

## Apply the migration

1. Create a free Supabase project.
2. Enable **Anonymous Sign-Ins** under Authentication settings.
3. Open **SQL Editor**.
4. Paste and run `supabase/migrations/001_initial_schema.sql`.
5. Create the one permanent admin Auth user in the Supabase dashboard.
6. Copy that user's UUID and run:

```sql
insert into public.admin_users (user_id)
values ('PUT-ADMIN-AUTH-USER-UUID-HERE');
```

## Defaults currently inserted for a new tournament

These are only starting values and will be editable in the admin UI:

- group: 7 minutes, first to 10, no golden goal
- knockout: 7 minutes, first to 10, golden goal on a tie
- final: 10 minutes, first to 10, golden goal on a tie
- third place: 7 minutes, first to 10, golden goal on a tie
- 2 qualifiers per group
- team PIN protection off
- pause button on
- group rotation scheduling mode

## Next migration / development step

Implement transaction-safe server functions for:

- tournament creation helpers
- automatic round-robin generation
- queue generation (`group_sequential` / `group_rotation`)
- assigning the next queued match to a free field
- start / pause / resume timer
- submit and lock a result
- forfeit / postpone / cancel
- recalculate tie-breaks
- create and advance the knockout bracket

The frontend should never be allowed to directly mutate match state for player actions; it should call those server functions.
