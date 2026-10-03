begin;

-- P11: Supabase's built-in rls_auto_enable() (event trigger ensure_rls, which turns on RLS
-- for new tables) is SECURITY DEFINER and was executable by the API roles. Event triggers
-- run it themselves, so nobody needs EXECUTE; revoking clears both Security Advisor warnings.
do $$
begin
  if exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
            where n.nspname='public' and p.proname='rls_auto_enable') then
    execute 'revoke all on function public.rls_auto_enable() from public, anon, authenticated';
  end if;
end $$;

commit;
