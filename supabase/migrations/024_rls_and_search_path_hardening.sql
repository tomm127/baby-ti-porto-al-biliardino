-- BTPB 024: preserve the existing RLS authorization rules while evaluating
-- row-independent authentication helpers once per statement.
-- Policy names and predicates verified against the live policy export.
BEGIN;

ALTER FUNCTION public.set_updated_at() SET search_path TO pg_catalog;
ALTER FUNCTION public.engine_round_name(integer) SET search_path TO pg_catalog;

ALTER POLICY player_assignment_select_own_or_admin
ON public.player_team_assignments
USING (user_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

ALTER POLICY push_subscriptions_select_own_or_admin
ON public.push_subscriptions
USING (user_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

ALTER POLICY push_subscriptions_insert_own
ON public.push_subscriptions
WITH CHECK (user_id = (SELECT auth.uid()));

ALTER POLICY push_subscriptions_update_own
ON public.push_subscriptions
USING (user_id = (SELECT auth.uid()))
WITH CHECK (user_id = (SELECT auth.uid()));

ALTER POLICY push_subscriptions_delete_own
ON public.push_subscriptions
USING (user_id = (SELECT auth.uid()) OR (SELECT public.is_admin()));

COMMIT;
