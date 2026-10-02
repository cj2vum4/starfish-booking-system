begin;

-- Called only after the server has verified a LINE ID token. The session token itself
-- never reaches the database; only its SHA-256 is stored.
create function public.login_line_user(p_line_user_id text, p_display_name text,
  p_session_hash text, p_expires_at timestamptz)
returns jsonb language plpgsql set search_path='' as $$
declare uid uuid; uname text;
begin
  if coalesce(p_line_user_id,'') !~ '^U[0-9a-f]{32}$' then raise exception 'INVALID_IDENTITY' using errcode='P0001'; end if;
  perform public._sf_valid_hash(p_session_hash);
  if p_expires_at is null or p_expires_at<=now() or p_expires_at>now()+interval '24 hours' then
    raise exception 'INVALID_EXPIRY' using errcode='P0001'; end if;
  uname := nullif(left(trim(coalesce(p_display_name,'')),100),'');

  insert into public.users as u(line_user_id,display_name,last_seen_at)
    values (p_line_user_id,uname,now())
    on conflict (line_user_id) do update set
      display_name=coalesce(excluded.display_name,u.display_name),
      last_seen_at=greatest(u.last_seen_at,excluded.last_seen_at),
      updated_at=now()
    returning id,display_name into uid,uname;
  delete from public.app_sessions where user_id=uid and expires_at<=now();
  insert into public.app_sessions(token_hash,user_id,expires_at) values (p_session_hash,uid,p_expires_at);
  perform public._sf_audit(uid,'session.login','user',uid);
  return jsonb_build_object('user_id',uid,'display_name',uname,'is_admin',public._sf_is_admin(uid));
end $$;

-- Returns null for unknown or expired sessions; never exposes the LINE user ID.
create function public.resolve_session(p_session_hash text)
returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('user_id',u.id,'display_name',u.display_name,'is_admin',public._sf_is_admin(u.id),
    'expires_at',s.expires_at)
  from public.app_sessions s join public.users u on u.id=s.user_id
  where s.token_hash=p_session_hash and s.expires_at>now()
$$;

create function public.logout_session(p_session_hash text)
returns jsonb language plpgsql set search_path='' as $$
declare uid uuid;
begin
  delete from public.app_sessions where token_hash=p_session_hash returning user_id into uid;
  if uid is not null then perform public._sf_audit(uid,'session.logout','user',uid); end if;
  return jsonb_build_object('logged_out',uid is not null);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('login_line_user','resolve_session','logout_session') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
