begin;

-- LINE 玩本心得 are queued here and written to the website's Apps Script in the background:
-- its full points rebuild takes 15-30 s, too long to keep the player waiting on the form.
create table public.record_submissions (
  user_id uuid not null references public.users(id) on delete restrict,
  record_id uuid not null,  -- event id, or a stable digest for a manual backfill
  event_id uuid references public.events(id) on delete restrict,
  title text not null check(char_length(title) between 1 and 200),
  review_key text not null check(char_length(review_key) between 1 and 200),
  played_date date not null,
  character text not null check(char_length(character) between 1 and 100),
  rating smallint not null check(rating between 1 and 5),
  comment text not null check(char_length(comment) <= 50),
  record_name text check(char_length(record_name) between 1 and 60),
  display_name text,
  status text not null default 'pending' check(status in ('pending','sending','saved','failed')),
  attempts integer not null default 0,
  error_code text,
  saved_name text,
  duplicate boolean not null default false,
  locked_until timestamptz,
  next_attempt_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, record_id)
);
create index record_submissions_queue on public.record_submissions(next_attempt_at) where status in ('pending','sending');
alter table public.record_submissions enable row level security;
revoke all on public.record_submissions from public,anon,authenticated;
grant select,insert,update,delete on public.record_submissions to service_role;

-- Queues one submission. A record already queued or saved is kept as is (the sheet holds one
-- review per session); a permanently failed one may be sent again with the new content.
create function public.queue_record_submission(p_actor uuid,p_record_id uuid,p_event_id uuid,p_title text,p_review_key text,
  p_date date,p_character text,p_rating integer,p_comment text,p_record_name text,p_display_name text)
returns jsonb language plpgsql set search_path='' as $$
declare existing public.record_submissions;
begin
  select * into existing from public.record_submissions where user_id=p_actor and record_id=p_record_id for update;
  if found and existing.status<>'failed' then
    return jsonb_build_object('status',existing.status,'duplicate',true);
  end if;
  insert into public.record_submissions as s(user_id,record_id,event_id,title,review_key,played_date,character,rating,comment,
      record_name,display_name)
    values(p_actor,p_record_id,p_event_id,p_title,p_review_key,p_date,trim(p_character),p_rating,p_comment,
      nullif(p_record_name,''),nullif(p_display_name,''))
    on conflict(user_id,record_id) do update set title=excluded.title,review_key=excluded.review_key,played_date=excluded.played_date,
      character=excluded.character,rating=excluded.rating,comment=excluded.comment,record_name=excluded.record_name,
      display_name=excluded.display_name,status='pending',attempts=0,error_code=null,locked_until=null,
      next_attempt_at=now(),updated_at=now();
  return jsonb_build_object('status','pending','duplicate',false);
end $$;

create function public.claim_record_submissions(p_limit integer default 3)
returns jsonb language plpgsql set search_path='' as $$
declare out jsonb;
begin
  with picked as (
    select s.user_id,s.record_id from public.record_submissions s
    where (s.status='pending' and s.next_attempt_at<=now()) or (s.status='sending' and s.locked_until<now())
    order by s.created_at limit least(greatest(coalesce(p_limit,3),1),10)
    for update skip locked
  ), claimed as (
    update public.record_submissions s set status='sending',attempts=s.attempts+1,
      locked_until=now()+interval '2 minutes',updated_at=now()
    from picked where s.user_id=picked.user_id and s.record_id=picked.record_id
    returning s.*
  )
  select coalesce(jsonb_agg(jsonb_build_object('user_id',user_id,'record_id',record_id,'title',title,'review_key',review_key,
    'date',to_char(played_date,'YYYY-MM-DD'),'character',character,'rating',rating,'comment',comment,
    'record_name',record_name,'display_name',display_name,'attempts',attempts) order by created_at),'[]') into out
  from claimed;
  return out;
end $$;

-- p_error null = saved. Temporary errors retry with backoff (up to 6 tries); permanent ones stop.
create function public.complete_record_submission(p_actor uuid,p_record_id uuid,p_name text,p_duplicate boolean,
  p_error text,p_permanent boolean)
returns void language plpgsql set search_path='' as $$
begin
  update public.record_submissions set
    status=case when p_error is null then 'saved' when p_permanent or attempts>=6 then 'failed' else 'pending' end,
    saved_name=case when p_error is null then left(p_name,60) else saved_name end,
    duplicate=coalesce(p_duplicate,false),
    error_code=left(p_error,60),locked_until=null,updated_at=now(),
    next_attempt_at=now()+make_interval(mins => least(power(2,attempts)::int,60))
  where user_id=p_actor and record_id=p_record_id and status='sending';
end $$;

create function public.my_record_submissions(p_actor uuid)
returns jsonb language sql stable set search_path='' as $$
  select coalesce(jsonb_agg(jsonb_build_object('record_id',record_id,'event_id',event_id,'title',title,
      'date',to_char(played_date,'YYYY-MM-DD'),'character',character,'rating',rating,'comment',comment,
      'status',status,'error_code',error_code,'created_at',created_at) order by created_at desc),'[]')
  from (select * from public.record_submissions where user_id=p_actor order by created_at desc limit 50) s
$$;

revoke all on function public.queue_record_submission(uuid,uuid,uuid,text,text,date,text,integer,text,text,text),
  public.claim_record_submissions(integer),public.complete_record_submission(uuid,uuid,text,boolean,text,boolean),
  public.my_record_submissions(uuid) from public,anon,authenticated;
grant execute on function public.queue_record_submission(uuid,uuid,uuid,text,text,date,text,integer,text,text,text),
  public.claim_record_submissions(integer),public.complete_record_submission(uuid,uuid,text,boolean,text,boolean),
  public.my_record_submissions(uuid) to service_role;

commit;
