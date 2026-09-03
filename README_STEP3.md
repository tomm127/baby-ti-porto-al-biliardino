# Baby ti porto al biliardino — Step 3: Supabase Live Engine

Apply `supabase/migrations/002_live_engine.sql` after migration 001.

## New RPCs

### Admin setup
- `admin_install_group_schedule(tournament_id, matches_json)`
- `admin_start_tournament(tournament_id)`
- `admin_reorder_queue(tournament_id, ordered_match_ids)`

### Player + admin live controls
- `start_match(match_id)`
- `pause_match(match_id)`
- `resume_match(match_id)`
- `mark_timer_expired(match_id)`
- `end_match_early(match_id)`
- `submit_match_result(match_id, score1, score2)`

### Admin interventions
- `admin_postpone_match(match_id)`
- `admin_forfeit_match(match_id, loser_team_id)`
- `admin_cancel_match(match_id)`

## Concurrency rule

Every queue-advancing transaction takes a Postgres transaction advisory lock keyed to the tournament UUID. This prevents two simultaneous devices from both assigning the same next match / field.

## Result lock

After `submit_match_result` the match is `finished` and players cannot alter it again. Direct table updates remain blocked by RLS. The admin can correct data through admin privileges; all direct changes are captured by `audit_log`.

## Automatic next match

Submitting a result, a forfeit, cancellation or postponement calls `engine_fill_free_fields()` in the same transaction. It assigns the first queued matches to all currently free active fields, preserving strict queue order.
