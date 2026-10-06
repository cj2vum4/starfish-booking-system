begin;

-- 店家決定：從 LINE 填玩後問卷時，已綁定的玩家自動帶名字；第一次填的新玩家取一個全新的名字，
-- 直接綁到他的 LINE（不用審核）。已有玩本記錄的名字由 API 先擋下，改走老玩家綁定由店家審核。
create function public.claim_record_name(p_actor uuid, p_name text)
returns jsonb language plpgsql set search_path='' as $$
declare v_name text := btrim(coalesce(p_name,''));
begin
  if char_length(v_name) not between 1 and 30 or v_name ~ '[[:cntrl:]]' then
    raise exception 'INVALID_NAME' using errcode='P0001'; end if;
  if exists(select 1 from public.player_bindings where user_id=p_actor and status='approved')
    or exists(select 1 from public.line_record_accounts where user_id=p_actor) then
    raise exception 'ALREADY_BOUND' using errcode='P0001'; end if;
  if exists(select 1 from public.player_bindings where user_id=p_actor and status='pending') then
    raise exception 'BINDING_PENDING' using errcode='P0001'; end if;
  if exists(select 1 from public.player_bindings where lower(record_name)=lower(v_name) and status in ('pending','approved'))
    or exists(select 1 from public.line_record_accounts where lower(record_name)=lower(v_name)) then
    raise exception 'NAME_TAKEN' using errcode='P0001'; end if;
  insert into public.line_record_accounts(user_id,record_name) values(p_actor,v_name);
  perform public._sf_audit(p_actor,'record_name.claim','user',p_actor,jsonb_build_object('name',v_name));
  return jsonb_build_object('record_name',v_name);
exception when unique_violation then
  raise exception 'NAME_TAKEN' using errcode='P0001';
end $$;
revoke all on function public.claim_record_name(uuid,text) from public,anon,authenticated;
grant execute on function public.claim_record_name(uuid,text) to service_role;

commit;
