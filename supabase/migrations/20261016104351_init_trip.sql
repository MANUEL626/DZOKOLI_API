begin;

create type public.location_type as enum (
    'airport',
    'port'
);

create type public.trip_status as enum (
    'draft',
    'scheduled',
    'in_progress',
    'completed',
    'cancelled'
);

create type public.trip_type as enum (
    'plane',
    'boat'
);

create table public.countries (
    id uuid primary key default gen_random_uuid(),
    name varchar(120) not null,
    iso_code_2 char(2) not null unique,
    iso_code_3 char(3) not null unique,
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint countries_name_unique unique (name),
    constraint countries_iso_code_2_format_check check (
        iso_code_2 ~ '^[A-Z]{2}$'
    ),
    constraint countries_iso_code_3_format_check check (
        iso_code_3 ~ '^[A-Z]{3}$'
    )
);

create table public.locations (
    id uuid primary key default gen_random_uuid(),
    country_id uuid not null references public.countries(id) on delete restrict,
    type public.location_type not null,
    name varchar(180) not null,
    code varchar(10),
    city varchar(120),
    latitude numeric(9, 6),
    longitude numeric(9, 6),
    is_active boolean not null default true,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint locations_identity_unique unique (country_id, type, name),
    constraint locations_code_format_check check (
        code is null or code ~ '^[A-Z0-9]{2,10}$'
    ),
    constraint locations_latitude_check check (
        latitude is null or latitude between -90 and 90
    ),
    constraint locations_longitude_check check (
        longitude is null or longitude between -180 and 180
    ),
    constraint locations_coordinates_check check (
        (latitude is null) = (longitude is null)
    )
);

create table public.trips (
    id uuid primary key default gen_random_uuid(),
    traveler_user_id uuid not null references public.users(id) on delete restrict,
    type public.trip_type not null,
    departure_location_id uuid not null references public.locations(id) on delete restrict,
    arrival_location_id uuid not null references public.locations(id) on delete restrict,
    departure_at timestamptz not null,
    arrival_at timestamptz not null,
    transport_reference varchar(80),
    status public.trip_status not null default 'draft',
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint trips_different_locations_check check (
        departure_location_id <> arrival_location_id
    ),
    constraint trips_dates_check check (arrival_at > departure_at)
);

create index locations_country_id_type_idx
on public.locations(country_id, type)
where is_active;

create unique index locations_type_code_unique_idx
on public.locations(type, code)
where code is not null;

create index trips_traveler_user_id_idx
on public.trips(traveler_user_id, departure_at desc);

create index trips_route_departure_idx
on public.trips(departure_location_id, arrival_location_id, departure_at)
where status = 'scheduled';

create trigger countries_set_updated_at
before update on public.countries
for each row execute function public.set_updated_at();

create trigger locations_set_updated_at
before update on public.locations
for each row execute function public.set_updated_at();

create trigger trips_set_updated_at
before update on public.trips
for each row execute function public.set_updated_at();

create trigger trips_record_status_history
after insert or update of status on public.trips
for each row execute function public.record_status_history('status');

create or replace function public.validate_trip_locations()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    expected_location_type public.location_type;
    departure_type public.location_type;
    arrival_type public.location_type;
begin
    expected_location_type := case new.type
        when 'plane' then 'airport'::public.location_type
        when 'boat' then 'port'::public.location_type
    end;

    select location.type
    into departure_type
    from public.locations location
    join public.countries country on country.id = location.country_id
    where location.id = new.departure_location_id
      and location.is_active
      and country.is_active;

    select location.type
    into arrival_type
    from public.locations location
    join public.countries country on country.id = location.country_id
    where location.id = new.arrival_location_id
      and location.is_active
      and country.is_active;

    if departure_type is null or arrival_type is null then
        raise exception 'Departure and arrival locations and their countries must be active';
    end if;

    if departure_type <> expected_location_type
       or arrival_type <> expected_location_type then
        raise exception 'Trip locations are incompatible with the selected trip type';
    end if;

    return new;
end;
$$;

create trigger trips_validate_locations
before insert or update of type, departure_location_id, arrival_location_id
on public.trips
for each row execute function public.validate_trip_locations();

alter table public.countries enable row level security;
alter table public.locations enable row level security;
alter table public.trips enable row level security;

create policy countries_read_active
on public.countries for select
to anon, authenticated
using (is_active);

create policy locations_read_active
on public.locations for select
to anon, authenticated
using (
    is_active
    and exists (
        select 1
        from public.countries country
        where country.id = country_id
          and country.is_active
    )
);

create policy trips_read_visible
on public.trips for select
to authenticated
using (
    traveler_user_id = (select auth.uid())
    or status <> 'draft'
);

create policy trips_insert_own
on public.trips for insert
to authenticated
with check (traveler_user_id = (select auth.uid()));

create policy trips_update_own
on public.trips for update
to authenticated
using (traveler_user_id = (select auth.uid()))
with check (traveler_user_id = (select auth.uid()));

create policy trips_delete_own_draft
on public.trips for delete
to authenticated
using (
    traveler_user_id = (select auth.uid())
    and status = 'draft'
);

commit;
