begin;

create extension if not exists pgcrypto;

create type public.user_status as enum (
    'active', 'restricted', 'suspended', 'deleted'
);

create type public.wallet_status as enum (
    'active', 'restricted', 'suspended'
);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create table if not exists public.users (
    id uuid primary key references auth.users(id) on delete cascade,
    phone text unique,
    email varchar(320),
    email_verified_at timestamptz,
    first_name varchar(80),
    last_name varchar(80),
    profile_picture_path text,
    profile_completed_at timestamptz,
    anonymized_at timestamptz,
    average_rating numeric(3, 2) not null default 0,
    review_count integer not null default 0,
    completed_delivery_count integer not null default 0,
    status public.user_status not null default 'active',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint users_phone_e164_check check (
        phone is null or phone ~ '^\+[1-9][0-9]{7,14}$'
    ),
    constraint users_email_format_check check (
        email is null
        or email ~* '^[A-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
    ),
    constraint users_average_rating_check check (
        average_rating >= 0 and average_rating <= 5
    ),
    constraint users_review_count_check check (review_count >= 0),
    constraint users_completed_delivery_count_check check (
        completed_delivery_count >= 0
    ),
    constraint users_profile_completion_check check (
        profile_completed_at is null
        or (
            first_name is not null
            and last_name is not null
            and profile_picture_path is not null
        )
    )
);

create table if not exists public.wallets (
    id uuid primary key default gen_random_uuid(),
    user_id uuid not null references public.users(id) on delete cascade,
    currency char(3) not null default 'XOF',
    available_balance numeric(18, 2) not null default 0,
    reserved_balance numeric(18, 2) not null default 0,
    pending_balance numeric(18, 2) not null default 0,
    status public.wallet_status not null default 'active',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint wallets_user_currency_unique unique (user_id, currency),
    constraint wallets_currency_format_check check (currency ~ '^[A-Z]{3}$'),
    constraint wallets_available_balance_check check (available_balance >= 0),
    constraint wallets_reserved_balance_check check (reserved_balance >= 0),
    constraint wallets_pending_balance_check check (pending_balance >= 0)
);

create table public.status_history (
    id uuid primary key default gen_random_uuid(),
    entity_table varchar(80) not null,
    entity_id uuid not null,
    status_field varchar(80) not null,
    previous_status text,
    new_status text not null,
    changed_by_user_id uuid references public.users(id) on delete set null,
    reason text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    constraint status_history_metadata_check check (jsonb_typeof(metadata) = 'object')
);

create index status_history_entity_idx
on public.status_history(entity_table, entity_id, status_field, created_at desc);

create or replace function public.record_status_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    old_status text;
    new_status text;
begin
    old_status := case when tg_op = 'INSERT' then null else to_jsonb(old) ->> tg_argv[0] end;
    new_status := to_jsonb(new) ->> tg_argv[0];
    if tg_op = 'INSERT' or old_status is distinct from new_status then
        insert into public.status_history (
            entity_table, entity_id, status_field, previous_status,
            new_status, changed_by_user_id
        ) values (
            tg_table_name, new.id, tg_argv[0], old_status, new_status, auth.uid()
        );
    end if;
    return new;
end;
$$;

create or replace function public.prevent_audit_mutation()
returns trigger language plpgsql set search_path = ''
as $$
begin
    raise exception 'Audit records are immutable';
end;
$$;

create trigger status_history_immutable
before update or delete on public.status_history
for each row execute function public.prevent_audit_mutation();

create index if not exists wallets_user_id_idx on public.wallets(user_id);
create unique index users_email_unique_idx
on public.users(lower(email)) where email is not null;

drop trigger if exists users_set_updated_at on public.users;
create trigger users_set_updated_at
before update on public.users
for each row execute function public.set_updated_at();

drop trigger if exists wallets_set_updated_at on public.wallets;
create trigger wallets_set_updated_at
before update on public.wallets
for each row execute function public.set_updated_at();

create trigger users_record_status_history
after insert or update of status on public.users
for each row execute function public.record_status_history('status');

create trigger wallets_record_status_history
after insert or update of status on public.wallets
for each row execute function public.record_status_history('status');

create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if new.phone is null and new.email is null then
        -- Supabase Auth clears/anonymizes the identifiers during a soft deletion.
        -- The application profile has already been anonymized separately.
        if tg_op = 'UPDATE' then
            return new;
        end if;
        raise exception 'A phone number or email is required to create a Dzokoli user';
    end if;

    insert into public.users (id, phone, email, email_verified_at)
    values (new.id, new.phone, lower(new.email), new.email_confirmed_at)
    on conflict (id) do update
    set phone = excluded.phone,
        email = excluded.email,
        email_verified_at = excluded.email_verified_at
    where public.users.status <> 'deleted';

    insert into public.wallets (user_id, currency)
    values (new.id, 'XOF')
    on conflict (user_id, currency) do nothing;

    return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert or update of phone, email, email_confirmed_at on auth.users
for each row execute function public.handle_new_auth_user();

insert into public.users (id, phone, email, email_verified_at)
select id, phone, lower(email), email_confirmed_at
from auth.users
where phone is not null or email is not null
on conflict (id) do update
set phone = excluded.phone,
    email = excluded.email,
    email_verified_at = excluded.email_verified_at
where public.users.status <> 'deleted';

insert into public.wallets (user_id, currency)
select id, 'XOF'
from public.users
on conflict (user_id, currency) do nothing;

alter table public.users enable row level security;
alter table public.wallets enable row level security;
alter table public.status_history enable row level security;

drop policy if exists users_select_own_profile on public.users;
create policy users_select_own_profile
on public.users for select
to authenticated
using ((select auth.uid()) = id);

drop policy if exists users_update_own_profile on public.users;

drop policy if exists wallets_select_own on public.wallets;
create policy wallets_select_own
on public.wallets for select
to authenticated
using ((select auth.uid()) = user_id);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
    'profile-pictures',
    'profile-pictures',
    true,
    5242880,
    array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists profile_pictures_public_read on storage.objects;
create policy profile_pictures_public_read
on storage.objects for select
to public
using (bucket_id = 'profile-pictures');

drop policy if exists profile_pictures_insert_own on storage.objects;
create policy profile_pictures_insert_own
on storage.objects for insert
to authenticated
with check (
    bucket_id = 'profile-pictures'
    and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists profile_pictures_update_own on storage.objects;
create policy profile_pictures_update_own
on storage.objects for update
to authenticated
using (
    bucket_id = 'profile-pictures'
    and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
    bucket_id = 'profile-pictures'
    and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists profile_pictures_delete_own on storage.objects;
create policy profile_pictures_delete_own
on storage.objects for delete
to authenticated
using (
    bucket_id = 'profile-pictures'
    and (storage.foldername(name))[1] = (select auth.uid())::text
);

commit;
