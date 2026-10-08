begin;
do $$
declare owner_id uuid; second_admin uuid; first_id uuid; batch jsonb; t bigint; n integer;
begin
  insert into public.users(line_user_id,display_name,oa_friend_status)
    values('U'||repeat('d',32),'Alert test owner','active') returning id into owner_id;
  insert into public.admin_users(user_id) values(owner_id);
  update public.oa_message_alert_settings set recipient_user_id=owner_id,enabled=true,cooldown_seconds=300;
  t := floor(extract(epoch from now())*1000)::bigint;
  batch := public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
    'userId','U'||repeat('a',32),'webhookEventId','test-alert-1','timestamp',t,'text','must not persist')));
  if jsonb_array_length(batch->'alerts')<>1 or (batch->>'pending_count')::int<>1 then
    raise exception 'first message did not enqueue'; end if;
  first_id := (batch->'alerts'->0->>'id')::uuid;
  if batch->'alerts'->0->>'line_user_id'<>'U'||repeat('d',32) then raise exception 'wrong recipient'; end if;
  perform public.complete_oa_message_alert(first_id,'failed','NETWORK');
  batch := public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
    'userId','U'||repeat('a',32),'webhookEventId','test-alert-1','timestamp',t)));
  if (batch->'alerts'->0->>'id')::uuid<>first_id then raise exception 'retry identity changed'; end if;
  perform public.complete_oa_message_alert(first_id,'sent');
  perform public.complete_oa_message_alert(first_id,'failed','LATE_FAILURE');
  if (select status from public.oa_message_alerts where id=first_id)<>'sent' then raise exception 'sent overwritten'; end if;
  batch := public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
    'userId','U'||repeat('a',32),'webhookEventId','test-alert-1','timestamp',t),jsonb_build_object(
    'userId','U'||repeat('a',32),'webhookEventId','test-alert-2','timestamp',t)));
  if jsonb_array_length(batch->'alerts')<>0 then raise exception 'dedupe/cooldown failed'; end if;
  update public.oa_message_alert_senders set last_alert_at=now()-interval '301 seconds';
  perform public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
    'userId','U'||repeat('a',32),'webhookEventId','test-alert-3','timestamp',t),jsonb_build_object(
    'userId','U'||repeat('b',32),'webhookEventId','test-alert-4','timestamp',t)));
  if (select count(*) from public.oa_message_alerts)<>3 then raise exception 'sender independence/expiry failed'; end if;
  perform public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
    'userId','U'||repeat('d',32),'webhookEventId','test-alert-self','timestamp',t),jsonb_build_object(
    'userId','U'||repeat('c',32),'webhookEventId','test-alert-old','timestamp',t-90000000)));
  if (select count(*) from public.oa_message_alerts)<>3 then raise exception 'self/stale alerted'; end if;
  insert into public.users(line_user_id,display_name,oa_friend_status)
    values('U'||repeat('e',32),'Second test admin','active') returning id into second_admin;
  insert into public.admin_users(user_id) values(second_admin);
  perform public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
    'userId','U'||repeat('f',32),'webhookEventId','test-alert-5','timestamp',t)));
  if exists(select 1 from public.oa_message_alerts where recipient_user_id<>owner_id) then
    raise exception 'future admin received notification'; end if;
  begin
    perform public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
      'userId','U'||repeat('1',32),'webhookEventId','test-alert-rollback','timestamp',t),jsonb_build_object(
      'userId','invalid','webhookEventId','test-alert-invalid','timestamp',t)));
    raise exception 'invalid batch accepted';
  exception when sqlstate '22023' then null; end;
  if exists(select 1 from public.oa_message_events where webhook_event_id='test-alert-rollback') then
    raise exception 'partial invalid batch'; end if;
  update public.oa_message_alert_settings set cooldown_seconds=0;
  perform public.process_oa_message_alerts(jsonb_build_array(jsonb_build_object(
    'userId','U'||repeat('f',32),'webhookEventId','test-alert-6','timestamp',t)));
  if (select count(*) from public.oa_message_alerts)<>5 then raise exception 'zero cooldown failed'; end if;
  update public.oa_message_alert_settings set enabled=false;
  batch := public.process_oa_message_alerts('[]');
  if (batch->>'pending_count')::int<>0 then raise exception 'disabled queue active'; end if;
  if exists(select 1 from public.oa_message_events e where to_jsonb(e)::text like '%must not persist%') then
    raise exception 'chat text persisted'; end if;
  if has_function_privilege('anon','public.process_oa_message_alerts(jsonb)','execute')
    or has_function_privilege('authenticated','public.complete_oa_message_alert(uuid,text,text)','execute')
    or has_table_privilege('anon','public.oa_message_alerts','select')
    or has_table_privilege('authenticated','public.oa_message_events','select') then raise exception 'public access'; end if;
  if not has_function_privilege('service_role','public.process_oa_message_alerts(jsonb)','execute') then
    raise exception 'missing service role'; end if;
  if exists(select 1 from pg_class where relname in ('oa_message_alert_settings','oa_message_events',
    'oa_message_alert_senders','oa_message_alerts') and not relrowsecurity) then raise exception 'RLS missing'; end if;
end $$;
select 'PASS: OA message alert dedupe, cooldown, retries, sole recipient, privacy and permissions' as result;
rollback;
