begin;

-- New tables are no longer granted to service_role by default on Supabase; grant explicitly
-- (the api reaches player_bindings only through the RPCs in 0022, which run as service_role).
grant select,insert,update,delete on public.player_bindings to service_role;

commit;
