-- Run in Supabase SQL Editor after 202610030020_friend_gate.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare u uuid; b uuid; r jsonb;
begin
  insert into public.users(line_user_id) values ('U0000000000000000000000000000c7a1') returning id into u;
  insert into public.users(line_user_id,oa_friend_status,blocked_at) values ('U0000000000000000000000000000c7a2','blocked',now()) returning id into b;
  r := public.user_line_identity(u);
  if r->>'line_user_id'<>'U0000000000000000000000000000c7a1' or r->>'oa_friend_status'<>'unknown' then raise exception 'identity wrong: %', r; end if;
  perform public.mark_user_followed(u);
  perform public.mark_user_followed(b);
  if (select oa_friend_status from public.users where id=u)<>'active'
    or (select oa_friend_status||coalesce(blocked_at::text,'') from public.users where id=b)<>'active'
    then raise exception 'follow not recorded'; end if;
  -- A later unfollow webhook still wins over the manual mark.
  perform public.process_line_events(jsonb_build_array(jsonb_build_object('type','unfollow',
    'userId','U0000000000000000000000000000c7a1','timestamp',(extract(epoch from now())*1000)::bigint,'webhookEventId','qa-gate-unfollow')));
  if (select oa_friend_status from public.users where id=u)<>'blocked' then raise exception 'unfollow lost'; end if;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.mark_user_followed(uuid)','EXECUTE')
      or has_function_privilege(r,'public.user_line_identity(uuid)','EXECUTE') then raise exception 'gate RPC exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: identity, follow recorded, later unfollow wins, privileges' as result;
rollback;
