begin;

-- GitHub pushes to cj2vum4/starfishlarp trigger a catalog sync with no LINE user behind
-- it. The shared body runs for both the store admin button and the GitHub hook.

create function public._sf_apply_catalog(p_actor uuid, p_games jsonb, p_source text)
returns jsonb language plpgsql set search_path='' as $$
declare g jsonb; n integer := 0; off integer;
begin
  if jsonb_typeof(p_games) is distinct from 'array' or jsonb_array_length(p_games) not between 1 and 500 then
    raise exception 'INVALID_CATALOG' using errcode='P0001'; end if;
  for g in select value from jsonb_array_elements(p_games) loop
    if coalesce(g->>'slug','') !~ '^[a-z0-9][a-z0-9-]*$' or coalesce(length(trim(g->>'title')),0) not between 1 and 200
      or (g->>'min_players')::int not between 1 and 50 or (g->>'max_players')::int not between (g->>'min_players')::int and 50
      or (g->>'duration_minutes')::int not between 30 and 720 then
      raise exception 'INVALID_CATALOG' using errcode='P0001';
    end if;
    insert into public.games as x(slug,title,min_players,max_players,duration_minutes,genres,difficulty,
        players_label,image_url,source_url,active,synced_at)
      values (g->>'slug',trim(g->>'title'),(g->>'min_players')::int,(g->>'max_players')::int,
        (g->>'duration_minutes')::int,
        coalesce((select array_agg(left(t,40)) from jsonb_array_elements_text(g->'genres') t),'{}'),
        left(g->>'difficulty',20),left(g->>'players_label',100),
        nullif(g->>'image_url',''),nullif(g->>'source_url',''),true,now())
      on conflict (slug) do update set title=excluded.title,min_players=excluded.min_players,
        max_players=excluded.max_players,duration_minutes=excluded.duration_minutes,genres=excluded.genres,
        difficulty=excluded.difficulty,players_label=excluded.players_label,image_url=excluded.image_url,
        source_url=excluded.source_url,active=true,synced_at=excluded.synced_at;
    n := n+1;
  end loop;
  update public.games set active=false
    where active and synced_at is not null and slug not in (select value->>'slug' from jsonb_array_elements(p_games));
  get diagnostics off = row_count;
  perform public._sf_audit(p_actor,'games.sync','game',null,
    jsonb_build_object('synced',n,'deactivated',off,'source',left(p_source,80)));
  return jsonb_build_object('synced',n,'deactivated',off);
end $$;

create or replace function public.admin_sync_games(p_actor uuid, p_games jsonb)
returns jsonb language plpgsql set search_path='' as $$
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  return public._sf_apply_catalog(p_actor,p_games,'admin');
end $$;

-- Called only by the api function after it has checked the shared GitHub hook secret.
create function public.system_sync_games(p_games jsonb, p_commit text)
returns jsonb language plpgsql set search_path='' as $$
begin
  if coalesce(p_commit,'') !~ '^[0-9a-f]{40}$' then raise exception 'INVALID_COMMIT' using errcode='P0001'; end if;
  return public._sf_apply_catalog(null,p_games,'github:'||p_commit);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('_sf_apply_catalog','admin_sync_games','system_sync_games') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
