begin;

create type public.conversation_status as enum (
    'active',
    'closed',
    'archived'
);

create type public.conversation_type as enum (
    'direct',
    'delivery_group',
    'support'
);

create type public.conversation_participant_role as enum (
	'member',
	'buyer',
	'traveler',
	'recipient',
	'support_agent'
);

create type public.message_type as enum (
    'text',
    'voice',
    'attachment',
    'system'
);

create type public.message_attachment_type as enum (
    'image',
    'video',
    'audio',
    'file'
);

create table public.conversations (
	id uuid primary key default gen_random_uuid(),
	type public.conversation_type not null,
	direct_key text unique,
	created_by_user_id uuid references public.users(id) on delete set null,
	status public.conversation_status not null default 'active',
	last_message_at timestamptz,
	closed_at timestamptz,
	created_at timestamptz not null default now(),
	updated_at timestamptz not null default now(),
	constraint conversations_direct_key_check check (
		(type = 'direct' and direct_key is not null)
		or (type <> 'direct' and direct_key is null)
	),
	constraint conversations_closed_at_check check (
		closed_at is null or closed_at >= created_at
	)
);

create type public.inbox_event_type as enum (
    'conversation.created',
    'message.created',
    'conversation.read',
    'conversation.closed'
);

create table public.conversation_participants (
    conversation_id uuid not null references public.conversations(id) on delete cascade,
    user_id uuid not null references public.users(id) on delete restrict,
    role public.conversation_participant_role not null,
    joined_at timestamptz not null default now(),
    left_at timestamptz,
    last_read_at timestamptz,
    primary key (conversation_id, user_id),
    constraint conversation_participants_dates_check check (
        left_at is null or left_at >= joined_at
    )
);

create table public.messages (
    id uuid primary key default gen_random_uuid(),
	conversation_id uuid not null references public.conversations(id) on delete cascade,
	sender_user_id uuid references public.users(id) on delete set null,
	reply_to_message_id uuid references public.messages(id) on delete set null,
	client_message_id uuid,
    type public.message_type not null,
    content text,
    created_at timestamptz not null default now(),
    edited_at timestamptz,
    deleted_at timestamptz,
    constraint messages_text_content_check check (
        type <> 'text' or nullif(btrim(content), '') is not null
    ),
    constraint messages_system_sender_check check (
        type <> 'system' or sender_user_id is null
    ),
    constraint messages_sender_required_check check (
        type = 'system' or sender_user_id is not null
    ),
    constraint messages_edit_date_check check (
        edited_at is null or edited_at >= created_at
    ),
	constraint messages_delete_date_check check (
		deleted_at is null or deleted_at >= created_at
	),
	constraint messages_sender_client_id_unique unique (
		sender_user_id,
		client_message_id
	),
	constraint messages_client_id_required_check check (
		type = 'system' or client_message_id is not null
	)
);

comment on column public.messages.content is
'Required text for text messages; optional caption for voice and attachment messages.';

create table public.message_attachments (
    id uuid primary key default gen_random_uuid(),
    message_id uuid not null references public.messages(id) on delete cascade,
    uploaded_by_user_id uuid not null references public.users(id) on delete restrict,
    type public.message_attachment_type not null,
    storage_path text not null unique,
    original_file_name text,
    mime_type varchar(150) not null,
    size_bytes bigint not null,
    duration_seconds numeric(10, 3),
    width integer,
    height integer,
    created_at timestamptz not null default now(),
    constraint message_attachments_size_check check (
        size_bytes > 0 and size_bytes <= 52428800
    ),
    constraint message_attachments_duration_check check (
        duration_seconds is null or duration_seconds >= 0
    ),
    constraint message_attachments_width_check check (width is null or width > 0),
    constraint message_attachments_height_check check (height is null or height > 0)
);

create table public.user_inbox_events (
    sequence_id bigint generated always as identity primary key,
    user_id uuid not null references public.users(id) on delete cascade,
    conversation_id uuid not null references public.conversations(id) on delete cascade,
    event_type public.inbox_event_type not null,
    actor_user_id uuid references public.users(id) on delete set null,
    message_id uuid references public.messages(id) on delete cascade,
    payload jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    acknowledged_at timestamptz,
    constraint user_inbox_events_payload_check check (jsonb_typeof(payload) = 'object'),
    constraint user_inbox_events_ack_check check (
        acknowledged_at is null or acknowledged_at >= created_at
    )
);

create index conversations_created_by_user_id_idx
on public.conversations(created_by_user_id);

create index conversations_last_message_at_idx
on public.conversations(last_message_at desc nulls last);

create index conversation_participants_user_id_idx
on public.conversation_participants(user_id, conversation_id);

create index messages_conversation_created_at_idx
on public.messages(conversation_id, created_at desc);

create index messages_sender_user_id_idx
on public.messages(sender_user_id)
where sender_user_id is not null;

create index messages_reply_to_message_id_idx
on public.messages(reply_to_message_id)
where reply_to_message_id is not null;

create index message_attachments_message_id_idx
on public.message_attachments(message_id);

create index user_inbox_events_user_sequence_idx
on public.user_inbox_events(user_id, sequence_id);

create index user_inbox_events_unacknowledged_idx
on public.user_inbox_events(user_id, sequence_id)
where acknowledged_at is null;

create unique index user_inbox_events_message_once_idx
on public.user_inbox_events(user_id, message_id, event_type)
where message_id is not null and event_type = 'message.created';

create trigger conversations_set_updated_at
before update on public.conversations
for each row execute function public.set_updated_at();

create trigger conversations_record_status_history
after insert or update of status on public.conversations
for each row execute function public.record_status_history('status');

create or replace function public.touch_conversation_after_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if tg_op = 'INSERT' then
        update public.conversations
        set last_message_at = new.created_at,
            updated_at = now()
        where id = new.conversation_id;
        return new;
    end if;

    update public.conversations
    set last_message_at = (
            select max(message.created_at)
            from public.messages message
            where message.conversation_id = old.conversation_id
        ),
        updated_at = now()
    where id = old.conversation_id;
    return old;
end;
$$;

create trigger messages_touch_conversation
after insert or delete on public.messages
for each row execute function public.touch_conversation_after_message();

create or replace function public.validate_message_reply()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.reply_to_message_id is not null and not exists (
        select 1
        from public.messages parent_message
        where parent_message.id = new.reply_to_message_id
          and parent_message.conversation_id = new.conversation_id
    ) then
        raise exception 'The replied-to message must belong to the same conversation';
    end if;
    return new;
end;
$$;

create trigger messages_validate_reply
before insert or update of reply_to_message_id, conversation_id on public.messages
for each row execute function public.validate_message_reply();

create or replace function public.validate_message_conversation_active()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if not exists (
        select 1
        from public.conversations conversation
        where conversation.id = new.conversation_id
          and conversation.status = 'active'
    ) then
        raise exception 'Messages can only be sent to an active conversation';
    end if;
    return new;
end;
$$;

create trigger messages_validate_conversation_active
before insert on public.messages
for each row execute function public.validate_message_conversation_active();

create or replace function public.validate_message_attachment()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    message_record record;
    expected_prefix text;
begin
    select message.type, message.sender_user_id, message.conversation_id
    into message_record
    from public.messages message
    where message.id = new.message_id;

    if not found then raise exception 'Attachment message not found'; end if;
    if message_record.type = 'text' or message_record.type = 'system' then
        raise exception 'This message type cannot contain attachments';
    end if;
    if new.uploaded_by_user_id <> message_record.sender_user_id then
        raise exception 'An attachment must be uploaded by the message sender';
    end if;

    expected_prefix := message_record.conversation_id::text || '/'
        || message_record.sender_user_id::text || '/';
    if left(new.storage_path, length(expected_prefix)) <> expected_prefix
       or position('..' in new.storage_path) > 0 then
        raise exception 'Attachment storage path is invalid';
    end if;

    if not (
        (new.type = 'image' and new.mime_type in (
            'image/jpeg', 'image/png', 'image/webp', 'image/gif'
        ))
        or (new.type = 'video' and new.mime_type in ('video/mp4', 'video/webm'))
        or (new.type = 'audio' and new.mime_type in (
            'audio/mpeg', 'audio/mp4', 'audio/ogg', 'audio/webm'
        ))
        or (new.type = 'file' and new.mime_type = 'application/pdf')
    ) then
        raise exception 'Attachment type and MIME type are incompatible';
    end if;

    if message_record.type = 'voice' then
        if new.type <> 'audio' or exists (
            select 1 from public.message_attachments attachment
            where attachment.message_id = new.message_id
              and attachment.id <> new.id
        ) then
            raise exception 'A voice message accepts exactly one audio attachment';
        end if;
    end if;
    return new;
end;
$$;

create trigger message_attachments_validate
before insert or update on public.message_attachments
for each row execute function public.validate_message_attachment();

create or replace function public.is_conversation_participant(
    target_conversation_id uuid,
    target_user_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
    select exists (
        select 1
        from public.conversation_participants participant
        where participant.conversation_id = target_conversation_id
          and participant.user_id = target_user_id
          and participant.left_at is null
    );
$$;

revoke all on function public.is_conversation_participant(uuid, uuid) from public;
grant execute on function public.is_conversation_participant(uuid, uuid) to authenticated;

create or replace function public.mark_conversation_read(target_conversation_id uuid)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
    read_timestamp timestamptz := now();
begin
    update public.conversation_participants
    set last_read_at = read_timestamp
    where conversation_id = target_conversation_id
      and user_id = auth.uid()
      and left_at is null;

    if not found then
        raise exception 'The authenticated user is not an active conversation participant';
    end if;

    return read_timestamp;
end;
$$;

revoke all on function public.mark_conversation_read(uuid) from public;
grant execute on function public.mark_conversation_read(uuid) to authenticated;

create or replace function public.create_conversation_with_participants(
	target_type public.conversation_type,
	creator_user_id uuid,
	participants jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
	conversation_uuid uuid;
	generated_direct_key text;
begin
	if jsonb_typeof(participants) <> 'array'
	   or jsonb_array_length(participants) < 2 then
		raise exception 'A conversation requires at least two participants';
	end if;

	if not exists (
		select 1
		from jsonb_array_elements(participants) participant
		where (participant ->> 'user_id')::uuid = creator_user_id
	) then
		 raise exception 'The creator must be one of the conversation participants';
	end if;

	if exists (
		select 1
		from jsonb_array_elements(participants) participant
		left join public.users app_user
		  on app_user.id = (participant ->> 'user_id')::uuid
		where app_user.id is null or app_user.status <> 'active'
	) then
		raise exception 'Every conversation participant must be an active user';
	end if;

	if target_type = 'direct' then
		if jsonb_array_length(participants) <> 2 then
			raise exception 'A direct conversation requires exactly two participants';
		end if;

		select string_agg(user_id, ':' order by user_id)
		into generated_direct_key
		from (
			select distinct participant ->> 'user_id' as user_id
			from jsonb_array_elements(participants) participant
		) participant_ids;
	elsif target_type = 'delivery_group'
	      and jsonb_array_length(participants) <> 3 then
		raise exception 'A delivery group requires exactly three participants';
	end if;

	insert into public.conversations (type, direct_key, created_by_user_id)
	values (target_type, generated_direct_key, creator_user_id)
	on conflict (direct_key) do nothing
	returning id into conversation_uuid;

	if conversation_uuid is null then
		select conversation.id
		into conversation_uuid
		from public.conversations conversation
		where conversation.direct_key = generated_direct_key;
		return conversation_uuid;
	end if;

	insert into public.conversation_participants (conversation_id, user_id, role)
	select
		conversation_uuid,
		(participant ->> 'user_id')::uuid,
		(participant ->> 'role')::public.conversation_participant_role
	from jsonb_array_elements(participants) participant;

	return conversation_uuid;
end;
$$;

create or replace function public.create_conversation_inbox_event()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
    insert into public.user_inbox_events (
        user_id, conversation_id, event_type, actor_user_id, payload
    ) values (
        new.user_id, new.conversation_id, 'conversation.created',
        (select conversation.created_by_user_id from public.conversations conversation
         where conversation.id = new.conversation_id),
        jsonb_build_object('conversationId', new.conversation_id)
    );
    return new;
end;
$$;

create trigger conversation_participants_create_inbox_event
after insert on public.conversation_participants
for each row execute function public.create_conversation_inbox_event();

create or replace function public.create_message_with_attachments(
    target_conversation_id uuid,
    target_sender_user_id uuid,
    target_client_message_id uuid,
    target_type public.message_type,
    target_content text,
    target_reply_to_message_id uuid,
    target_attachments jsonb
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
    message_uuid uuid;
begin
    if target_type = 'system' then
        raise exception 'System messages cannot be created by users';
    end if;
    if jsonb_typeof(target_attachments) <> 'array' then
        raise exception 'Attachments must be a JSON array';
    end if;
    if not exists (
        select 1
        from public.conversations conversation
        join public.conversation_participants participant
          on participant.conversation_id = conversation.id
        where conversation.id = target_conversation_id
          and conversation.status = 'active'
          and participant.user_id = target_sender_user_id
          and participant.left_at is null
    ) then
        raise exception 'The sender is not an active conversation participant';
    end if;

    insert into public.messages (
        conversation_id, sender_user_id, reply_to_message_id,
        client_message_id, type, content
    ) values (
        target_conversation_id, target_sender_user_id,
        target_reply_to_message_id, target_client_message_id,
        target_type, target_content
    )
    on conflict (sender_user_id, client_message_id) do nothing
    returning id into message_uuid;

    if message_uuid is null then
        select message.id into message_uuid
        from public.messages message
        where message.sender_user_id = target_sender_user_id
          and message.client_message_id = target_client_message_id
          and message.conversation_id = target_conversation_id;
        if message_uuid is null then
            raise exception 'Client message identifier conflict';
        end if;
        return message_uuid;
    end if;

    insert into public.message_attachments (
        message_id, uploaded_by_user_id, type, storage_path,
        original_file_name, mime_type, size_bytes,
        duration_seconds, width, height
    )
    select
        message_uuid, target_sender_user_id, attachment.type,
        attachment.storage_path, attachment.original_file_name,
        attachment.mime_type, attachment.size_bytes,
        attachment.duration_seconds, attachment.width, attachment.height
    from jsonb_to_recordset(target_attachments) as attachment(
        type public.message_attachment_type,
        storage_path text,
        original_file_name text,
        mime_type varchar,
        size_bytes bigint,
        duration_seconds numeric,
        width integer,
        height integer
    );

    insert into public.user_inbox_events (
        user_id, conversation_id, event_type,
        actor_user_id, message_id, payload
    )
    select participant.user_id, target_conversation_id, 'message.created',
           target_sender_user_id, message_uuid,
           jsonb_build_object('messageId', message_uuid)
    from public.conversation_participants participant
    where participant.conversation_id = target_conversation_id
      and participant.left_at is null
    on conflict do nothing;

    return message_uuid;
end;
$$;

create or replace function public.mark_conversation_read_for_user(
    target_conversation_id uuid,
    target_user_id uuid
)
returns timestamptz language plpgsql security definer set search_path = ''
as $$
declare
    read_timestamp timestamptz := now();
    previous_read_at timestamptz;
begin
    select participant.last_read_at into previous_read_at
    from public.conversation_participants participant
    where participant.conversation_id = target_conversation_id
      and participant.user_id = target_user_id
      and participant.left_at is null
    for update;
    if not found then raise exception 'The user is not an active participant'; end if;

    if not exists (
        select 1 from public.messages message
        where message.conversation_id = target_conversation_id
          and message.sender_user_id is distinct from target_user_id
          and message.deleted_at is null
          and (previous_read_at is null or message.created_at > previous_read_at)
    ) then
        return coalesce(previous_read_at, read_timestamp);
    end if;

    update public.conversation_participants
    set last_read_at = read_timestamp
    where conversation_id = target_conversation_id
      and user_id = target_user_id;

    insert into public.user_inbox_events (
        user_id, conversation_id, event_type, actor_user_id, payload
    )
    select participant.user_id, target_conversation_id, 'conversation.read',
           target_user_id,
           jsonb_build_object(
               'conversationId', target_conversation_id,
               'userId', target_user_id,
               'readAt', read_timestamp
           )
    from public.conversation_participants participant
    where participant.conversation_id = target_conversation_id
      and participant.left_at is null;
    return read_timestamp;
end;
$$;

create or replace function public.create_conversation_closed_events()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
    if old.status <> 'closed' and new.status = 'closed' then
        insert into public.user_inbox_events (
            user_id, conversation_id, event_type, actor_user_id, payload
        )
        select participant.user_id, new.id, 'conversation.closed',
               auth.uid(),
               jsonb_build_object(
                   'conversationId', new.id,
                   'closedAt', new.closed_at
               )
        from public.conversation_participants participant
        where participant.conversation_id = new.id
          and participant.left_at is null;
    end if;
    return new;
end;
$$;

create trigger conversations_create_closed_events
after update of status on public.conversations
for each row execute function public.create_conversation_closed_events();

create or replace function public.acknowledge_inbox_events(
    target_user_id uuid,
    through_sequence_id bigint
)
returns bigint language plpgsql security definer set search_path = ''
as $$
declare acknowledged_count bigint;
begin
    update public.user_inbox_events
    set acknowledged_at = coalesce(acknowledged_at, now())
    where user_id = target_user_id
      and sequence_id <= through_sequence_id
      and acknowledged_at is null;
    get diagnostics acknowledged_count = row_count;
    return acknowledged_count;
end;
$$;

revoke all on function public.create_conversation_with_participants(
	public.conversation_type, uuid, jsonb
)
from public, authenticated;
grant execute on function public.create_conversation_with_participants(
	public.conversation_type, uuid, jsonb
)
to service_role;

revoke all on function public.create_message_with_attachments(
    uuid, uuid, uuid, public.message_type, text, uuid, jsonb
) from public, authenticated;
grant execute on function public.create_message_with_attachments(
    uuid, uuid, uuid, public.message_type, text, uuid, jsonb
) to service_role;
revoke all on function public.mark_conversation_read_for_user(uuid, uuid)
from public, authenticated;
grant execute on function public.mark_conversation_read_for_user(uuid, uuid)
to service_role;
revoke all on function public.acknowledge_inbox_events(uuid, bigint)
from public, authenticated;
grant execute on function public.acknowledge_inbox_events(uuid, bigint)
to service_role;

alter table public.conversations enable row level security;
alter table public.conversation_participants enable row level security;
alter table public.messages enable row level security;
alter table public.message_attachments enable row level security;
alter table public.user_inbox_events enable row level security;

create policy conversations_select_for_participants
on public.conversations for select
to authenticated
using (public.is_conversation_participant(id, (select auth.uid())));

create policy conversation_participants_select_for_participants
on public.conversation_participants for select
to authenticated
using (
    public.is_conversation_participant(conversation_id, (select auth.uid()))
);

create policy messages_select_for_participants
on public.messages for select
to authenticated
using (
    public.is_conversation_participant(conversation_id, (select auth.uid()))
);

create policy messages_insert_by_participants
on public.messages for insert
to authenticated
with check (
    sender_user_id = (select auth.uid())
    and type <> 'system'
    and public.is_conversation_participant(conversation_id, (select auth.uid()))
);

create policy message_attachments_select_for_participants
on public.message_attachments for select
to authenticated
using (
    exists (
        select 1
        from public.messages message
        where message.id = message_id
          and public.is_conversation_participant(
              message.conversation_id,
              (select auth.uid())
          )
    )
);

create policy message_attachments_insert_by_sender
on public.message_attachments for insert
to authenticated
with check (
    uploaded_by_user_id = (select auth.uid())
    and exists (
        select 1
        from public.messages message
        where message.id = message_id
          and message.sender_user_id = (select auth.uid())
          and public.is_conversation_participant(
              message.conversation_id,
              (select auth.uid())
          )
    )
);

create policy user_inbox_events_select_own
on public.user_inbox_events for select to authenticated
using (user_id = (select auth.uid()));

create policy user_inbox_events_ack_own
on public.user_inbox_events for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

insert into storage.buckets (
    id,
    name,
    public,
    file_size_limit,
    allowed_mime_types
)
values (
    'conversation-media',
    'conversation-media',
    false,
    52428800,
    array[
        'image/jpeg',
        'image/png',
        'image/webp',
        'image/gif',
        'video/mp4',
        'video/webm',
        'audio/mpeg',
        'audio/mp4',
        'audio/ogg',
        'audio/webm',
        'application/pdf'
    ]
)
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy conversation_media_select_for_participants
on storage.objects for select
to authenticated
using (
    bucket_id = 'conversation-media'
    and exists (
        select 1
        from public.conversation_participants participant
        where participant.conversation_id::text = (storage.foldername(name))[1]
          and participant.user_id = (select auth.uid())
          and participant.left_at is null
    )
);

create policy conversation_media_insert_own
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'conversation-media'
    and (storage.foldername(name))[2] = (select auth.uid())::text
    and exists (
        select 1
        from public.conversation_participants participant
        where participant.conversation_id::text = (storage.foldername(name))[1]
          and participant.user_id = (select auth.uid())
          and participant.left_at is null
    )
);

create policy conversation_media_delete_own
on storage.objects for delete
to authenticated
using (
    bucket_id = 'conversation-media'
    and (storage.foldername(name))[2] = (select auth.uid())::text
);

commit;
