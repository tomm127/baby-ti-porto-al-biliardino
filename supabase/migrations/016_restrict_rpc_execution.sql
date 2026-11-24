-- BTPB migration 016: restrict RPC execution privileges (revised).
-- Based on the 58 audited functions and their actual argument types.
-- No changes to function bodies, data, table permissions or default grants.
-- Existing service_role access to all 58 functions is preserved.
-- Run the entire file in one SQL Editor execution.

BEGIN;

REVOKE EXECUTE ON FUNCTION
    public.admin_add_field(uuid, text),
    public.admin_add_team(uuid, uuid, text, text),
    public.admin_apply_group_layout(uuid, jsonb),
    public.admin_assign_match_field(uuid, uuid),
    public.admin_bulk_add_teams(uuid, uuid, jsonb),
    public.admin_cancel_match(uuid),
    public.admin_delete_team_completely(uuid),
    public.admin_force_move_team_group(uuid, uuid),
    public.admin_forfeit_match(uuid, uuid),
    public.admin_generate_knockout(uuid),
    public.admin_install_group_schedule(uuid, jsonb),
    public.admin_postpone_match(uuid),
    public.admin_reorder_queue(uuid, uuid[]),
    public.admin_reset_tournament_matches(uuid),
    public.admin_restore_team(uuid),
    public.admin_set_emergency_pause(uuid, boolean),
    public.admin_set_match_result(uuid, integer, integer),
    public.admin_set_team_avatar(uuid, text),
    public.admin_set_team_pin(uuid, text),
    public.admin_start_tournament(uuid),
    public.admin_update_field(uuid, text, boolean),
    public.admin_update_match_result(uuid, integer, integer),
    public.admin_update_tournament_rules(uuid, boolean, integer, boolean, boolean, integer, integer, integer, integer, integer, integer, integer, integer),
    public.admin_withdraw_team(uuid),
    public.can_control_match(uuid),
    public.can_view_tournament(uuid),
    public.claim_team(uuid, text),
    public.end_match_early(uuid),
    public.enqueue_current_notification_for_me(uuid),
    public.get_tournament_snapshot(text),
    public.get_tournament_snapshot_by_id(uuid),
    public.is_admin(),
    public.leave_team(uuid),
    public.mark_timer_expired(uuid),
    public.pause_match(uuid),
    public.resume_match(uuid),
    public.start_match(uuid),
    public.submit_match_result(uuid, integer, integer),
    public.claim_push_jobs(integer),
    public.complete_push_job(bigint, boolean, text),
    public.audit_row_change(),
    public.engine_advance_knockout(uuid),
    public.engine_after_match_closed(uuid),
    public.engine_create_knockout(uuid),
    public.engine_enqueue_match_notification(uuid, text),
    public.engine_enqueue_prepare_for_next(uuid),
    public.engine_fill_free_fields(uuid),
    public.engine_group_ranking(uuid, uuid),
    public.engine_groups_complete(uuid),
    public.engine_maybe_advance_after_structure_edit(uuid),
    public.engine_normalize_queue(uuid),
    public.engine_round_name(integer),
    public.engine_seed_order(integer),
    public.initialize_tournament_defaults(),
    public.lock_tournament(uuid),
    public.require_admin(),
    public.require_group_structure_editable(uuid),
    public.set_updated_at()
FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION
    public.admin_add_field(uuid, text),
    public.admin_add_team(uuid, uuid, text, text),
    public.admin_apply_group_layout(uuid, jsonb),
    public.admin_assign_match_field(uuid, uuid),
    public.admin_bulk_add_teams(uuid, uuid, jsonb),
    public.admin_cancel_match(uuid),
    public.admin_delete_team_completely(uuid),
    public.admin_force_move_team_group(uuid, uuid),
    public.admin_forfeit_match(uuid, uuid),
    public.admin_generate_knockout(uuid),
    public.admin_install_group_schedule(uuid, jsonb),
    public.admin_postpone_match(uuid),
    public.admin_reorder_queue(uuid, uuid[]),
    public.admin_reset_tournament_matches(uuid),
    public.admin_restore_team(uuid),
    public.admin_set_emergency_pause(uuid, boolean),
    public.admin_set_match_result(uuid, integer, integer),
    public.admin_set_team_avatar(uuid, text),
    public.admin_set_team_pin(uuid, text),
    public.admin_start_tournament(uuid),
    public.admin_update_field(uuid, text, boolean),
    public.admin_update_match_result(uuid, integer, integer),
    public.admin_update_tournament_rules(uuid, boolean, integer, boolean, boolean, integer, integer, integer, integer, integer, integer, integer, integer),
    public.admin_withdraw_team(uuid),
    public.can_control_match(uuid),
    public.can_view_tournament(uuid),
    public.claim_team(uuid, text),
    public.end_match_early(uuid),
    public.enqueue_current_notification_for_me(uuid),
    public.get_tournament_snapshot(text),
    public.get_tournament_snapshot_by_id(uuid),
    public.is_admin(),
    public.leave_team(uuid),
    public.mark_timer_expired(uuid),
    public.pause_match(uuid),
    public.resume_match(uuid),
    public.start_match(uuid),
    public.submit_match_result(uuid, integer, integer)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.admin_add_field(uuid, text),
    public.admin_add_team(uuid, uuid, text, text),
    public.admin_apply_group_layout(uuid, jsonb),
    public.admin_assign_match_field(uuid, uuid),
    public.admin_bulk_add_teams(uuid, uuid, jsonb),
    public.admin_cancel_match(uuid),
    public.admin_delete_team_completely(uuid),
    public.admin_force_move_team_group(uuid, uuid),
    public.admin_forfeit_match(uuid, uuid),
    public.admin_generate_knockout(uuid),
    public.admin_install_group_schedule(uuid, jsonb),
    public.admin_postpone_match(uuid),
    public.admin_reorder_queue(uuid, uuid[]),
    public.admin_reset_tournament_matches(uuid),
    public.admin_restore_team(uuid),
    public.admin_set_emergency_pause(uuid, boolean),
    public.admin_set_match_result(uuid, integer, integer),
    public.admin_set_team_avatar(uuid, text),
    public.admin_set_team_pin(uuid, text),
    public.admin_start_tournament(uuid),
    public.admin_update_field(uuid, text, boolean),
    public.admin_update_match_result(uuid, integer, integer),
    public.admin_update_tournament_rules(uuid, boolean, integer, boolean, boolean, integer, integer, integer, integer, integer, integer, integer, integer),
    public.admin_withdraw_team(uuid),
    public.can_control_match(uuid),
    public.can_view_tournament(uuid),
    public.claim_team(uuid, text),
    public.end_match_early(uuid),
    public.enqueue_current_notification_for_me(uuid),
    public.get_tournament_snapshot(text),
    public.get_tournament_snapshot_by_id(uuid),
    public.is_admin(),
    public.leave_team(uuid),
    public.mark_timer_expired(uuid),
    public.pause_match(uuid),
    public.resume_match(uuid),
    public.start_match(uuid),
    public.submit_match_result(uuid, integer, integer),
    public.claim_push_jobs(integer),
    public.complete_push_job(bigint, boolean, text),
    public.audit_row_change(),
    public.engine_advance_knockout(uuid),
    public.engine_after_match_closed(uuid),
    public.engine_create_knockout(uuid),
    public.engine_enqueue_match_notification(uuid, text),
    public.engine_enqueue_prepare_for_next(uuid),
    public.engine_fill_free_fields(uuid),
    public.engine_group_ranking(uuid, uuid),
    public.engine_groups_complete(uuid),
    public.engine_maybe_advance_after_structure_edit(uuid),
    public.engine_normalize_queue(uuid),
    public.engine_round_name(integer),
    public.engine_seed_order(integer),
    public.initialize_tournament_defaults(),
    public.lock_tournament(uuid),
    public.require_admin(),
    public.require_group_structure_editable(uuid),
    public.set_updated_at()
TO service_role;

-- Abort the transaction if the effective permissions do not match the audit.
-- The denominator is 1 on success, 0 on mismatch (transaction aborts).
WITH audit AS (
    SELECT count(*) AS function_count,
           count(*) FILTER (WHERE has_function_privilege('anon', p.oid, 'EXECUTE')) AS anon_callable,
           count(*) FILTER (WHERE has_function_privilege('authenticated', p.oid, 'EXECUTE')) AS authenticated_callable,
           count(*) FILTER (WHERE has_function_privilege('service_role', p.oid, 'EXECUTE')) AS service_role_callable
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind = 'f'
)
SELECT 1 / CASE WHEN function_count = 58 AND anon_callable = 0
                  AND authenticated_callable = 38 AND service_role_callable = 58
                THEN 1 ELSE 0 END AS permission_check
FROM audit;

NOTIFY pgrst, 'reload schema';
COMMIT;

-- Read-only verification.
SELECT count(*) AS function_count,
       count(*) FILTER (WHERE has_function_privilege('anon', p.oid, 'EXECUTE')) AS anon_callable,
       count(*) FILTER (WHERE has_function_privilege('authenticated', p.oid, 'EXECUTE')) AS authenticated_callable,
       count(*) FILTER (WHERE has_function_privilege('service_role', p.oid, 'EXECUTE')) AS service_role_callable
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prokind = 'f';
