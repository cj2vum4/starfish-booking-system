-- Run in Supabase SQL Editor after 202610050022_player_binding.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare adm uuid; a uuid; b uuid; r jsonb; msg text; n int;
begin
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000e1ad','店長') returning id into adm;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000e1a1','小明') returning id into a;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000e1a2','冒名') returning id into b;
  insert into public.admin_users(user_id) values (adm);

  r := public.request_binding(a,'  阿明  ','以前也用過「明明」');
  if r->>'status'<>'pending' or r->>'record_name'<>'阿明' then raise exception 'request wrong: %', r; end if;
  select count(*) into n from public.notification_logs where notification_type='binding_requested' and user_id=adm;
  if n<>1 then raise exception 'store not notified: %', n; end if;
  if public.member_menu_line_ids() ? 'U0000000000000000000000000000e1a1' then raise exception 'member before approval'; end if;

  -- Not the store: cannot list or decide.
  begin perform public.admin_decide_binding(a,a,true); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'NOT_ADMIN' then raise exception 'self-approve: %', msg; end if; end;
  begin perform public.admin_list_bindings(a); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'NOT_ADMIN' then raise exception 'list: %', msg; end if; end;

  -- Someone else claims the same name; both are pending, only one can be approved.
  perform public.request_binding(b,'阿明','');
  if jsonb_array_length(public.admin_list_bindings(adm))<2 then raise exception 'pending list incomplete'; end if;
  r := public.admin_decide_binding(adm,a,true);
  if r->>'status'<>'approved' then raise exception 'approve wrong: %', r; end if;
  begin perform public.admin_decide_binding(adm,b,true); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'NAME_TAKEN' then raise exception 'double owner: %', msg; end if; end;
  begin perform public.request_binding(b,'阿明',''); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'NAME_TAKEN' then raise exception 'claim taken: %', msg; end if; end;
  begin perform public.admin_decide_binding(adm,a,false); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'BINDING_DECIDED' then raise exception 'redecide: %', msg; end if; end;
  begin perform public.request_binding(a,'別的名字',''); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'ALREADY_BOUND' then raise exception 'rebind: %', msg; end if; end;

  if not public.member_menu_line_ids() ? 'U0000000000000000000000000000e1a1' then raise exception 'approved player not on member menu'; end if;
  if not public.bound_record_names() ? '阿明' then raise exception 'bound names missing'; end if;
  if not exists(select 1 from public.notification_logs where user_id=a and notification_type='binding_approved') then raise exception 'player not notified'; end if;

  -- Bonus result is recorded only for approved bindings.
  r := public.mark_binding_bonus(a,'granted');
  if r->>'bonus_status'<>'granted' then raise exception 'bonus not recorded'; end if;
  perform public.admin_decide_binding(adm,b,false);
  begin perform public.mark_binding_bonus(b,'granted'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'BINDING_NOT_FOUND' then raise exception 'bonus on rejected: %', msg; end if; end;
  -- A rejected player may ask again with another name.
  r := public.request_binding(b,'阿華','');
  if r->>'status'<>'pending' then raise exception 'retry after reject: %', r; end if;
  if (public.my_binding(b))->>'record_name'<>'阿華' then raise exception 'my_binding wrong'; end if;
  begin perform public.request_binding(b,repeat('名',61),''); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'INVALID_NAME' then raise exception 'long name: %', msg; end if; end;
end $$;
reset role;
do $$
declare r text; f text;
begin
  foreach r in array array['anon','authenticated'] loop
    foreach f in array array['public.request_binding(uuid,text,text)','public.admin_decide_binding(uuid,uuid,boolean)',
      'public.mark_binding_bonus(uuid,text)','public.my_binding(uuid)','public.admin_list_bindings(uuid)','public.bound_record_names()'] loop
      if has_function_privilege(r,f,'EXECUTE') then raise exception '% exposed to %', f, r; end if;
    end loop;
    if has_table_privilege(r,'public.player_bindings','SELECT') then raise exception 'table exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: request, store-only decisions, one owner per name, member menu, notifications, bonus record, retry, privileges' as result;
rollback;
