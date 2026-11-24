-- BTPB 023: register the event used by admin_set_match_result.
-- Apply and commit before running the integration smoke test again.
ALTER TYPE public.match_event_type ADD VALUE IF NOT EXISTS 'admin_result_set';
