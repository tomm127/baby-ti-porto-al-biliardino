# Manual database integration tests

Run each SQL file in its entirety in Supabase SQL Editor **after migrations 001–024**. Prefer a dedicated test project, otherwise use an idle database. An existing admin record is required. The scripts use transaction-local test identity and roll back their fixture rows, even on success; sequence values can still advance. No push deliveries are invoked.

- `btpb_integration_smoke_test.sql`: two small tournament scenarios, including knockout, byes, timers and cancellation.
- `btpb_benchmark_100_sample.sql`: 100 teams, 450 scheduled group matches, 12 sampled results and snapshot measurements.
- `btpb_benchmark_24_full.sql`: a 24-team tournament through the final, 48 played matches.

These are manual sequential database checks, not concurrent-user load tests. They do not belong in the migrations directory. GitHub Actions runs the TypeScript tests and production build without database credentials.

Reported status on 25 November 2026: all three scripts passed on the deployed Supabase database before migration 024. The full 100-team end-to-end SQL benchmark hit the SQL Editor upstream timeout and is not included here. Numerical benchmark timings have not been supplied.
