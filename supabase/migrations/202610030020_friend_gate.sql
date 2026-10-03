begin;

-- Opening, joining or claiming a seat requires being a friend of the 海星劇本殺 OA, so
-- every participant can receive LINE notifications. The api checks the stored status and,
-- when it is not active, confirms with LINE before refusing.

create function public.user_line_identity(p_user_id uuid)
returns jsonb language sql stable set search_path='' as $$
  select jsonb_build_object('line_user_id',line_user_id,'oa_friend_status',oa_friend_status)
  from public.users where id=p_user_id
$$;

-- Called only after LINE confirmed the friendship (profile API returned the user).
-- friendship_event_at is untouched, so a later unfollow webhook still wins.
create function public.mark_user_followed(p_user_id uuid)
returns jsonb language plpgsql set search_path='' as $$
begin
  update public.users set oa_friend_status='active',blocked_at=null,updated_at=now()
    where id=p_user_id and oa_friend_status<>'active';
  return jsonb_build_object('ok',true);
end $$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('user_line_identity','mark_user_followed') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
