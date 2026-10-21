begin;

create type public.listing_status as enum (
    'draft',
    'open',
    'closed',
    'expired',
    'cancelled'
);

create type public.listing_closed_reason as enum (
    'manual',
    'capacity_reached',
    'trip_status',
    'expired'
);

create type public.parcel_type as enum (
    'document', 'clothing', 'electronics', 'food', 'other'
);

create table public.listings (
    id uuid primary key default gen_random_uuid(),
    trip_id uuid not null unique references public.trips(id) on delete cascade,
    total_available_kg numeric(8, 2) not null,
    remaining_kg numeric(8, 2) not null,
    price_per_kg numeric(18, 2) not null,
    currency char(3) not null default 'XOF',
    status public.listing_status not null default 'draft',
    closed_reason public.listing_closed_reason,
    published_at timestamptz,
    closed_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint listings_total_available_kg_check check (
        total_available_kg > 0
    ),
    constraint listings_remaining_kg_check check (
        remaining_kg >= 0
        and remaining_kg <= total_available_kg
    ),
    constraint listings_price_per_kg_check check (price_per_kg > 0),
    constraint listings_currency_format_check check (
        currency ~ '^[A-Z]{3}$'
    ),
    constraint listings_open_capacity_check check (
        status <> 'open' or remaining_kg > 0
    ),
    constraint listings_published_at_check check (
        status in ('draft', 'cancelled') or published_at is not null
    ),
    constraint listings_closed_at_check check (
        status not in ('closed', 'expired', 'cancelled') or closed_at is not null
    ),
    constraint listings_closed_reason_check check (
        (status in ('closed', 'expired', 'cancelled') and closed_reason is not null)
        or (status not in ('closed', 'expired', 'cancelled') and closed_reason is null)
    ),
    constraint listings_dates_check check (
        (published_at is null or published_at >= created_at)
        and (closed_at is null or closed_at >= created_at)
    )
);

create table public.listing_accepted_parcel_types (
    listing_id uuid not null references public.listings(id) on delete cascade,
    parcel_type public.parcel_type not null,
    created_at timestamptz not null default now(),
    primary key (listing_id, parcel_type)
);

comment on table public.listings is
'Available baggage capacity and price published for a single trip.';

comment on column public.listings.remaining_kg is
'Capacity still available. Its reservation and release must be performed atomically.';

create index listings_status_created_at_idx
on public.listings(status, created_at desc);

create index listings_open_price_idx
on public.listings(price_per_kg)
where status = 'open';

create index listings_open_capacity_published_idx
on public.listings(remaining_kg, published_at desc, id desc)
where status = 'open';

create index listing_accepted_parcel_types_search_idx
on public.listing_accepted_parcel_types(parcel_type, listing_id);

create trigger listings_set_updated_at
before update on public.listings
for each row execute function public.set_updated_at();

create or replace function public.apply_listing_lifecycle()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.status = 'open' and not exists (
        select 1 from public.listing_accepted_parcel_types accepted
        where accepted.listing_id = new.id
    ) then
        raise exception 'An open listing requires at least one accepted parcel type';
    end if;

    if new.status = 'open'
       and (tg_op = 'INSERT' or old.status <> 'open')
       and new.published_at is null then
        new.published_at = now();
    end if;

    if new.status = 'open' and new.remaining_kg = 0 then
        new.status = 'closed';
        new.closed_reason = 'capacity_reached';
    end if;

    if new.status in ('closed', 'expired', 'cancelled')
       and new.closed_at is null then
        new.closed_at = now();
    end if;

    if new.status = 'closed' and new.closed_reason is null then
        new.closed_reason = 'manual';
    elsif new.status = 'expired' and new.closed_reason is null then
        new.closed_reason = 'expired';
    elsif new.status = 'cancelled' and new.closed_reason is null then
        new.closed_reason = 'trip_status';
    elsif new.status in ('draft', 'open') then
        new.closed_at = null;
        new.closed_reason = null;
    end if;

    return new;
end;
$$;

create trigger listings_apply_lifecycle
before insert or update of status, remaining_kg on public.listings
for each row execute function public.apply_listing_lifecycle();

create trigger listings_record_status_history
after insert or update of status on public.listings
for each row execute function public.record_status_history('status');

create or replace function public.validate_listing_trip()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.status in ('draft', 'open') and not exists (
        select 1
        from public.trips trip
        where trip.id = new.trip_id
          and trip.status in ('draft', 'scheduled')
    ) then
        raise exception 'A listing requires a draft or scheduled trip';
    end if;

    return new;
end;
$$;

create trigger listings_validate_trip
before insert or update of trip_id, status on public.listings
for each row execute function public.validate_listing_trip();

create or replace function public.close_listing_after_trip_status()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    if new.status in ('in_progress', 'completed', 'cancelled')
       and old.status is distinct from new.status then
        update public.listings
        set status = case
                when status = 'draft' or new.status = 'cancelled'
                    then 'cancelled'::public.listing_status
                else 'closed'::public.listing_status
            end,
            closed_at = coalesce(closed_at, now()),
            closed_reason = 'trip_status'
        where trip_id = new.id
          and status in ('draft', 'open');
    end if;
    return new;
end;
$$;

create trigger trips_close_listing_after_status
after update of status on public.trips
for each row execute function public.close_listing_after_trip_status();

create or replace function public.create_listing_with_trip(
    target_traveler_user_id uuid,
    target_trip_type public.trip_type,
    target_departure_location_id uuid,
    target_arrival_location_id uuid,
    target_departure_at timestamptz,
    target_arrival_at timestamptz,
    target_transport_reference varchar,
    target_total_available_kg numeric,
    target_price_per_kg numeric,
    target_currency char(3),
    target_accepted_parcel_types public.parcel_type[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
    trip_record public.trips%rowtype;
    listing_record public.listings%rowtype;
begin
    if target_traveler_user_id is null then
        raise exception 'A traveler is required';
    end if;
    if target_accepted_parcel_types is null
       or cardinality(target_accepted_parcel_types) = 0 then
        raise exception 'At least one accepted parcel type is required';
    end if;

    insert into public.trips (
        traveler_user_id, type, departure_location_id, arrival_location_id,
        departure_at, arrival_at, transport_reference, status
    ) values (
        target_traveler_user_id, target_trip_type,
        target_departure_location_id, target_arrival_location_id,
        target_departure_at, target_arrival_at,
        nullif(trim(target_transport_reference), ''), 'scheduled'
    ) returning * into trip_record;

    -- The listing starts as draft because its accepted types must exist before
    -- the lifecycle trigger permits publication.
    insert into public.listings (
        trip_id, total_available_kg, remaining_kg,
        price_per_kg, currency, status
    ) values (
        trip_record.id, target_total_available_kg, target_total_available_kg,
        target_price_per_kg, upper(target_currency), 'draft'
    ) returning * into listing_record;

    insert into public.listing_accepted_parcel_types (listing_id, parcel_type)
    select listing_record.id, parcel_type
    from unnest(target_accepted_parcel_types) parcel_type
    on conflict do nothing;

    update public.listings
    set status = 'open'
    where id = listing_record.id
    returning * into listing_record;

    return jsonb_build_object(
        'trip', to_jsonb(trip_record),
        'listing', to_jsonb(listing_record) || jsonb_build_object(
            'accepted_parcel_types', to_jsonb(target_accepted_parcel_types)
        ),
        'cancelled_bookings_count', 0
    );
end;
$$;

revoke all on function public.create_listing_with_trip(
    uuid, public.trip_type, uuid, uuid, timestamptz, timestamptz,
    varchar, numeric, numeric, char(3), public.parcel_type[]
) from public, authenticated;
grant execute on function public.create_listing_with_trip(
    uuid, public.trip_type, uuid, uuid, timestamptz, timestamptz,
    varchar, numeric, numeric, char(3), public.parcel_type[]
) to service_role;

create or replace function public.search_available_listings(
    filter_parcel_type public.parcel_type,
    filter_departure_location_id uuid,
    filter_arrival_location_id uuid,
    filter_minimum_kg numeric,
    filter_maximum_price_per_kg numeric,
    filter_currency char(3),
    cursor_published_at timestamptz,
    cursor_listing_id uuid,
    result_limit integer
)
returns table (
    id uuid,
    trip_id uuid,
    traveler_user_id uuid,
    trip_type public.trip_type,
    departure_location_id uuid,
    arrival_location_id uuid,
    departure_at timestamptz,
    arrival_at timestamptz,
    transport_reference varchar,
    total_available_kg numeric,
    remaining_kg numeric,
    price_per_kg numeric,
    currency char(3),
    accepted_parcel_types public.parcel_type[],
    published_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
    select
        listing.id,
        listing.trip_id,
        trip.traveler_user_id,
        trip.type,
        trip.departure_location_id,
        trip.arrival_location_id,
        trip.departure_at,
        trip.arrival_at,
        trip.transport_reference,
        listing.total_available_kg,
        listing.remaining_kg,
        listing.price_per_kg,
        listing.currency,
        array_agg(accepted.parcel_type order by accepted.parcel_type),
        listing.published_at
    from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    join public.listing_accepted_parcel_types accepted
      on accepted.listing_id = listing.id
    where listing.status = 'open'
      and listing.remaining_kg > 0
      and trip.status = 'scheduled'
      and trip.departure_at > now()
      and (filter_parcel_type is null or exists (
          select 1
          from public.listing_accepted_parcel_types filtered_type
          where filtered_type.listing_id = listing.id
            and filtered_type.parcel_type = filter_parcel_type
      ))
      and (filter_departure_location_id is null
           or trip.departure_location_id = filter_departure_location_id)
      and (filter_arrival_location_id is null
           or trip.arrival_location_id = filter_arrival_location_id)
      and (filter_minimum_kg is null
           or listing.remaining_kg >= filter_minimum_kg)
      and (filter_maximum_price_per_kg is null
           or listing.price_per_kg <= filter_maximum_price_per_kg)
      and (filter_currency is null or listing.currency = upper(filter_currency))
      and (
          cursor_published_at is null
          or (listing.published_at, listing.id)
             < (cursor_published_at, cursor_listing_id)
      )
    group by listing.id, trip.id
    order by listing.published_at desc, listing.id desc
    limit greatest(1, least(result_limit, 51));
$$;

revoke all on function public.search_available_listings(
    public.parcel_type, uuid, uuid, numeric, numeric, char(3),
    timestamptz, uuid, integer
) from public, authenticated;
grant execute on function public.search_available_listings(
    public.parcel_type, uuid, uuid, numeric, numeric, char(3),
    timestamptz, uuid, integer
) to service_role;

create or replace function public.get_listing_details(
    target_listing_id uuid,
    viewer_user_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
    select jsonb_build_object(
        'trip', to_jsonb(trip),
        'listing', to_jsonb(listing) || jsonb_build_object(
            'accepted_parcel_types', coalesce((
                select jsonb_agg(accepted.parcel_type order by accepted.parcel_type)
                from public.listing_accepted_parcel_types accepted
                where accepted.listing_id = listing.id
            ), '[]'::jsonb)
        ),
        'cancelled_bookings_count', 0
    )
    from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where listing.id = target_listing_id
      and (
          trip.traveler_user_id = viewer_user_id
          or (
              listing.status = 'open'
              and listing.remaining_kg > 0
              and trip.status = 'scheduled'
              and trip.departure_at > now()
          )
      );
$$;

revoke all on function public.get_listing_details(uuid, uuid)
from public, authenticated;
grant execute on function public.get_listing_details(uuid, uuid)
to service_role;

create or replace function public.list_user_listings(
    target_user_id uuid,
    filter_status public.listing_status,
    cursor_created_at timestamptz,
    cursor_listing_id uuid,
    result_limit integer
)
returns table (
    result jsonb,
    sort_created_at timestamptz,
    sort_id uuid
)
language sql
stable
security definer
set search_path = ''
as $$
    select
        jsonb_build_object(
            'trip', to_jsonb(trip),
            'listing', to_jsonb(listing) || jsonb_build_object(
                'accepted_parcel_types', coalesce((
                    select jsonb_agg(accepted.parcel_type order by accepted.parcel_type)
                    from public.listing_accepted_parcel_types accepted
                    where accepted.listing_id = listing.id
                ), '[]'::jsonb)
            ),
            'cancelled_bookings_count', 0
        ),
        listing.created_at,
        listing.id
    from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where trip.traveler_user_id = target_user_id
      and (filter_status is null or listing.status = filter_status)
      and (
          cursor_created_at is null
          or (listing.created_at, listing.id)
             < (cursor_created_at, cursor_listing_id)
      )
    order by listing.created_at desc, listing.id desc
    limit greatest(1, least(result_limit, 51));
$$;

revoke all on function public.list_user_listings(
    uuid, public.listing_status, timestamptz, uuid, integer
) from public, authenticated;
grant execute on function public.list_user_listings(
    uuid, public.listing_status, timestamptz, uuid, integer
) to service_role;

alter table public.listings enable row level security;
alter table public.listing_accepted_parcel_types enable row level security;

create policy listings_read_visible
on public.listings for select
to authenticated
using (
    status <> 'draft'
    or exists (
        select 1
        from public.trips trip
        where trip.id = trip_id
          and trip.traveler_user_id = (select auth.uid())
    )
);

create policy listings_insert_own_trip
on public.listings for insert
to authenticated
with check (
    exists (
        select 1
        from public.trips trip
        where trip.id = trip_id
          and trip.traveler_user_id = (select auth.uid())
    )
);

create policy listings_update_own_trip
on public.listings for update
to authenticated
using (
    exists (
        select 1
        from public.trips trip
        where trip.id = trip_id
          and trip.traveler_user_id = (select auth.uid())
    )
)
with check (
    exists (
        select 1
        from public.trips trip
        where trip.id = trip_id
          and trip.traveler_user_id = (select auth.uid())
    )
);

create policy listings_delete_own_draft
on public.listings for delete
to authenticated
using (
    status = 'draft'
    and exists (
        select 1
        from public.trips trip
        where trip.id = trip_id
          and trip.traveler_user_id = (select auth.uid())
    )
);

create policy listing_parcel_types_read_visible
on public.listing_accepted_parcel_types for select to authenticated
using (exists (
    select 1 from public.listings listing
    where listing.id = listing_id
      and (
          listing.status <> 'draft'
          or exists (
              select 1 from public.trips trip
              where trip.id = listing.trip_id
                and trip.traveler_user_id = (select auth.uid())
          )
      )
));

create policy listing_parcel_types_manage_own
on public.listing_accepted_parcel_types for all to authenticated
using (exists (
    select 1 from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where listing.id = listing_id
      and trip.traveler_user_id = (select auth.uid())
      and listing.status = 'draft'
))
with check (exists (
    select 1 from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where listing.id = listing_id
      and trip.traveler_user_id = (select auth.uid())
      and listing.status = 'draft'
));

commit;
