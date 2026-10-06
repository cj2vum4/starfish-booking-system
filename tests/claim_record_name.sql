-- Run in Supabase SQL Editor after 202610060030_claim_record_name.sql. All synthetic records are rolled back.
begin;
set local role service_role;
do $$
declare a uuid; b uuid; c uuid; d uuid; r jsonb; msg text;
begin
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000c1a1','甲') returning id into a;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000c1a2','乙') returning id into b;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000c1a3','丙') returning id into c;
  insert into public.users(line_user_id,display_name) values ('U0000000000000000000000000000c1a4','丁') returning id into d;

  r := public.claim_record_name(a,'  QA新玩家  ');
  if r->>'record_name'<>'QA新玩家' or public.my_record_account(a)<>'QA新玩家' then raise exception 'claim wrong: %', r; end if;
  if not (public.bound_record_names() ? 'QA新玩家') then raise exception 'claimed name still offered to others'; end if;
  if not exists(select 1 from public.audit_logs where actor_user_id=a and action='record_name.claim') then raise exception 'claim not audited'; end if;

  -- 同一個名字（不分大小寫）不能被第二個 LINE 取走；同一個 LINE 不能再取第二個名字。
  begin perform public.claim_record_name(b,'qa新玩家'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'NAME_TAKEN' then raise exception 'name stolen: %', msg; end if; end;
  begin perform public.claim_record_name(a,'QA第二個名字'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'ALREADY_BOUND' then raise exception 'second name: %', msg; end if; end;

  -- 綁定審核中、或名字已被申請綁定時都不能取。
  insert into public.player_bindings(user_id,record_name,status) values(c,'QA老玩家','pending');
  begin perform public.claim_record_name(c,'QA另一個'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'BINDING_PENDING' then raise exception 'pending claim: %', msg; end if; end;
  begin perform public.claim_record_name(d,'QA老玩家'); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'NAME_TAKEN' then raise exception 'pending name taken: %', msg; end if; end;

  begin perform public.claim_record_name(d,''); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'INVALID_NAME' then raise exception 'empty name: %', msg; end if; end;
  begin perform public.claim_record_name(d,repeat('名',31)); raise exception 'MISSING';
  exception when others then get stacked diagnostics msg=message_text; if msg<>'INVALID_NAME' then raise exception 'long name: %', msg; end if; end;
end $$;
reset role;
do $$
declare r text;
begin
  foreach r in array array['anon','authenticated'] loop
    if has_function_privilege(r,'public.claim_record_name(uuid,text)','EXECUTE') then raise exception 'claim exposed to %', r; end if;
  end loop;
end $$;
select 'PASS: new name claimed once per LINE and per name, pending bindings respected, invalid names refused, privileges' as result;
rollback;
