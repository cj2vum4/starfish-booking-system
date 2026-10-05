begin;

-- Last good copy of the website's 玩本記錄 summary (public data: names, agent numbers, points,
-- rewards). The Apps Script often takes 5-25 s and sometimes fails, so pages read this copy
-- and refresh it when it is older than they need.
create table public.play_record_snapshot (
  id integer primary key default 1 check (id = 1),
  payload jsonb not null check (jsonb_typeof(payload) = 'object'),
  fetched_at timestamptz not null default now()
);
alter table public.play_record_snapshot enable row level security;
revoke all on public.play_record_snapshot from public,anon,authenticated;
grant select,insert,update,delete on public.play_record_snapshot to service_role;

create function public.get_record_snapshot() returns jsonb
language sql stable set search_path='' as $$
  select jsonb_build_object('payload',payload,'fetched_at',fetched_at) from public.play_record_snapshot where id=1
$$;

create function public.put_record_snapshot(p_payload jsonb) returns jsonb
language plpgsql set search_path='' as $$
begin
  if jsonb_typeof(p_payload) is distinct from 'object' or jsonb_typeof(p_payload->'summary') is distinct from 'array' then raise exception 'INVALID_SNAPSHOT'; end if;
  insert into public.play_record_snapshot(id,payload,fetched_at) values (1,p_payload,now())
  on conflict (id) do update set payload=excluded.payload,fetched_at=excluded.fetched_at;
  return jsonb_build_object('ok',true);
end $$;

-- After a 回歸禮 the copy is out of date: mark it old so the next page fetches again.
create function public.expire_record_snapshot() returns jsonb
language sql set search_path='' as $$
  update public.play_record_snapshot set fetched_at='-infinity' where id=1;
  select jsonb_build_object('ok',true)
$$;

do $$ declare f regprocedure;
begin
  for f in select p.oid::regprocedure from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.proname in ('get_record_snapshot','put_record_snapshot','expire_record_snapshot') loop
    execute format('revoke all on function %s from public,anon,authenticated',f);
    execute format('grant execute on function %s to service_role',f);
  end loop;
end $$;

commit;
