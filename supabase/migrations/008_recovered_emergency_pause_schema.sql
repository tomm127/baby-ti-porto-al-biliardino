-- BTPB — reconstructed emergency-pause columns, 2026-11-24.
-- Source: production information_schema.columns export.
-- This is not the original migration 008. Additional constraints, if any,
-- must be reconciled against the production schema before a fresh deployment.
-- For version control / fresh database reconstruction; do not rerun on production.
-- Requires 001–007; precedes 009_recovered_function_changes.sql.

begin;

alter table public.matches
  add column if not exists emergency_pause_was_running boolean not null default false,
  add column if not exists emergency_pause_was_countdown boolean not null default false;

alter table public.tournament_settings
  add column if not exists emergency_paused boolean not null default false,
  add column if not exists emergency_paused_at timestamp with time zone;

commit;
