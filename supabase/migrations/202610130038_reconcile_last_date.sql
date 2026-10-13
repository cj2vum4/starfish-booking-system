-- 0038：對帳時「最後遊玩日」以日期比對（2026-10-13）。
-- Apps Script 的點數總覽把試算表日期格輸出成 String(date)，例如 'Sat Oct 10 2026 00:00:00 GMT+0800 (台湾標準時)'，
-- 預約系統是 '2026/10/10'；店家第一次對帳 62 位玩家其他欄位全部一致，只有 59 位的這一欄因寫法不同被列為差異。
begin;

create or replace function public.admin_records_reconcile(p_actor uuid) returns jsonb
language plpgsql stable set search_path='' as $$
declare gas jsonb; mine jsonb; diffs jsonb; only_gas jsonb; only_mine jsonb; snap public.play_record_snapshot;
begin
  if not public._sf_is_admin(p_actor) then raise exception 'NOT_ADMIN' using errcode='P0001'; end if;
  select * into snap from public.play_record_snapshot where id=1;
  gas := coalesce(snap.payload->'summary','[]');
  mine := public._sf_records_summary();
  with g as (select x->>'name' n, x from jsonb_array_elements(gas) x where coalesce(x->>'name','')<>''),
       s as (select x->>'name' n, x from jsonb_array_elements(mine) x),
       f(field) as (values ('earned'),('redeemed'),('balance'),('plays'),('last'),('agent'))
  select coalesce(jsonb_agg(jsonb_build_object('name',g.n,'field',f.field,'gas',g.x->f.field,'supabase',s.x->f.field)
           order by g.n, f.field),'[]')
    into diffs from g join s on s.n=g.n cross join f
    where case when f.field in ('earned','redeemed','balance','plays')
      then coalesce((g.x->>f.field)::numeric,0) <> coalesce((s.x->>f.field)::numeric,0)
      -- 最後遊玩日：Apps Script 的總覽是試算表日期格的 String(date)（'Sat Oct 10 2026 00:00:00 GMT+0800 (…)'），這裡是 Y/M/D。
      when f.field = 'last' then
        case when g.x->>'last' ~ '^[A-Z][a-z]{2} [A-Z][a-z]{2} \d{2} \d{4} '
          then to_char(to_date(substring(g.x->>'last' from 5 for 11), 'Mon DD YYYY'), 'YYYY/FMMM/FMDD')
          else public._sf_date_text(coalesce(g.x->>'last','')) end <> coalesce(s.x->>'last','')
      else coalesce(g.x->>f.field,'') <> coalesce(s.x->>f.field,'') end;
  select coalesce(jsonb_agg(x->>'name' order by x->>'name'),'[]') into only_gas from jsonb_array_elements(gas) x
    where coalesce(x->>'name','')<>'' and not exists(select 1 from jsonb_array_elements(mine) y where y->>'name'=x->>'name');
  select coalesce(jsonb_agg(x->>'name' order by x->>'name'),'[]') into only_mine from jsonb_array_elements(mine) x
    where not exists(select 1 from jsonb_array_elements(gas) y where y->>'name'=x->>'name');
  return jsonb_build_object('snapshotAt',snap.fetched_at,'gasPlayers',jsonb_array_length(gas),'supabasePlayers',jsonb_array_length(mine),
    'differences',diffs,'onlyGas',only_gas,'onlySupabase',only_mine,
    'matched',jsonb_array_length(diffs)=0 and jsonb_array_length(only_gas)=0 and jsonb_array_length(only_mine)=0
      and jsonb_array_length(gas)>0);
end $$;

commit;
