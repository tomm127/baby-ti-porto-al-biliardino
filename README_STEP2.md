# Baby ti porto al biliardino — Step 2: Tournament Engine

This step adds the pure TypeScript domain engine. It deliberately has no React or Supabase dependency.

## Implemented and tested

- Single round-robin generation using the circle method
- Odd-numbered groups with automatic bye rounds
- `group_sequential` queue mode
- strict `group_rotation` queue mode (A1, B1, C1, A2, B2, C2...)
- strict free-field assignment without fairness/rest reordering
- "matches ahead" calculation for a team
- group standings: 3/1/0 points, goal difference, goals scored, head-to-head, stable lot order
- head-to-head mini-table when 3+ teams remain tied
- qualification of the first N teams from each group
- cross-group ranking normalized by matches played
- first knockout round with global #1 vs last seed seeding
- automatic byes for non-power-of-two qualifier counts

## Run the engine tests

With Node 22+:

```bash
npm run test:engine
```

No npm packages are needed for these tests.

## Next step

Step 3 will connect these rules to Supabase transaction-safe RPC functions and begin the React/PWA shell.
