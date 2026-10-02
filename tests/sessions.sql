-- Run in Supabase SQL Editor after 202610020004_app_sessions.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare
  a text := 'U0000000000000000000000000000d001';
  h1 text := encode(sha256(convert_to('qa-session-1','UTF8')),'hex');
  h2 text := encode(sha256(convert_to('qa-session-2','UTF8')),'hex');
  r jsonb; uid uuid; msg text;
begin
  -- First LIFF login creates the user; a second login reuses it and keeps the name.
  r := public.login_line_user(a,'QA 玩家',h1,now()+interval '12 hours');
  uid := (r->>'user_id')::uuid;
  if (select count(*) from public.users where line_user_id=a)<>1 then raise exception 'user not created'; end if;
  r := public.login_line_user(a,null,h2,now()+interval '12 hours');
  if (r->>'user_id')::uuid<>uid or r->>'display_name'<>'QA 玩家' then raise exception 'relogin changed identity'; end if;
  if (select count(*) from public.users where line_user_id=a)<>1 then raise exception 'duplicate user'; end if;

  r := public.resolve_session(h1);
  if (r->>'user_id')::uuid<>uid then raise exception 'session not resolved'; end if;
  if r ? 'line_user_id' or r::text like '%'||a||'%' then raise exception 'session leaks LINE userId'; end if;
  if public.resolve_session(encode(sha256(convert_to('forged','UTF8')),'hex')) is not null
    then raise exception 'forged session accepted'; end if;

  -- Expired sessions are rejected even though the row still exists.
  update public.app_sessions set created_at=now()-interval '2 days',expires_at=now()-interval '1 second'
    where token_hash=h2;
  if public.resolve_session(h2) is not null then raise exception 'expired session accepted'; end if;

  r := public.logout_session(h1);
  if not (r->>'logged_out')::boolean or public.resolve_session(h1) is not null then raise exception 'logout failed'; end if;

  begin
    perform public.login_line_user('forged-user','x',h1,now()+interval '1 hour');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_IDENTITY' then raise exception 'invalid identity: %', msg; end if;
  end;
  begin
    perform public.login_line_user(a,'x',h1,now()+interval '30 days');
    raise exception 'MISSING';
  exception when others then get stacked diagnostics msg = message_text;
    if msg<>'INVALID_EXPIRY' then raise exception 'long session: %', msg; end if;
  end;
end $$;
reset role;
do $$
declare r text; f text;
begin
  foreach f in array array['public.login_line_user(text,text,text,timestamptz)',
    'public.resolve_session(text)','public.logout_session(text)'] loop
    foreach r in array array['anon','authenticated'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
  end loop;
end $$;
select 'PASS: login upsert, relogin, resolve, forged, expired, logout, validation, privileges' as result;
rollback;
