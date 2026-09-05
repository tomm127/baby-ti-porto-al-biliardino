-- BTPB
-- Migration 014: fix team avatar Storage upsert permissions
-- Apply AFTER 013_team_avatars.sql

begin;

drop policy if exists team_avatars_admin_select on storage.objects;

create policy team_avatars_admin_select
on storage.objects
for select
to authenticated
using (
  bucket_id = 'team-avatars'
  and public.is_admin()
);

commit;
