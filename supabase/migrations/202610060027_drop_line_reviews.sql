begin;

-- The store keeps 玩本心得 on the website's form (it lists each script's roles). LINE only
-- reminds players after attendance and links there, so the LINE review flow is removed.
-- line_record_accounts stays: it holds a name already written by that flow and the member card reads it.
drop function public.queue_record_submission(uuid,uuid,uuid,text,text,date,text,integer,text,text,text);
drop function public.claim_record_submissions(integer);
drop function public.complete_record_submission(uuid,uuid,text,boolean,text,boolean);
drop function public.my_record_submissions(uuid);
drop table public.record_submissions;
drop function public.my_review_context(uuid,uuid);
drop function public.my_manual_review_context(uuid,uuid,date);
drop function public.save_record_account(uuid,text);

commit;
