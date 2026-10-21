begin;

create type public.booking_status as enum (
    'pending', 'confirmed', 'cancellation_pending_return',
    'cancelled_before_pickup', 'cancelled_after_return', 'completed', 'refunded'
);
create type public.payment_status as enum (
    'pending', 'method_verified', 'paid', 'failed', 'cancelled', 'refunded'
);
create type public.shipment_status as enum (
    'awaiting_drop_off', 'photos_required', 'received_by_traveler',
    'in_transit', 'arrived', 'ready_for_pickup', 'delivered', 'disputed', 'returned'
);
create type public.recipient_type as enum ('buyer', 'third_party');
create type public.invitation_status as enum (
    'not_required', 'invited', 'accepted', 'declined', 'replaced'
);
create type public.evidence_stage as enum (
    'before_pickup', 'pickup', 'before_delivery', 'delivery', 'return'
);
create type public.dispute_type as enum (
    'damaged_parcel', 'missing_parcel', 'wrong_content',
    'delivery_issue', 'payment_issue', 'other'
);
create type public.dispute_status as enum (
    'open', 'under_review', 'resolved', 'rejected', 'closed'
);
create type public.delivery_token_purpose as enum (
    'pickup', 'delivery', 'cancellation'
);

create table public.bookings (
    id uuid primary key default gen_random_uuid(),
    listing_id uuid not null references public.listings(id) on delete restrict,
    buyer_user_id uuid not null references public.users(id) on delete restrict,
    reserved_kg numeric(8, 2) not null,
    price_per_kg numeric(18, 2) not null,
    subtotal numeric(18, 2) not null,
    platform_fee numeric(18, 2) not null default 0,
    total_amount numeric(18, 2) not null,
    currency char(3) not null,
    payment_status public.payment_status not null default 'pending',
    status public.booking_status not null default 'pending',
    expires_at timestamptz not null,
    confirmed_at timestamptz,
    completed_at timestamptz,
    cancelled_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint bookings_reserved_kg_check check (reserved_kg > 0),
    constraint bookings_price_per_kg_check check (price_per_kg > 0),
    constraint bookings_amounts_check check (
        subtotal >= 0 and platform_fee >= 0 and total_amount >= 0
        and total_amount = subtotal + platform_fee
        and subtotal = round(reserved_kg * price_per_kg, 2)
    ),
    constraint bookings_currency_format_check check (currency ~ '^[A-Z]{3}$'),
    constraint bookings_expiration_check check (expires_at > created_at)
);

create table public.shipments (
    id uuid primary key default gen_random_uuid(),
    booking_id uuid not null unique references public.bookings(id) on delete cascade,
    description text,
    declared_contents text not null,
    declared_value numeric(18, 2),
    actual_weight_kg numeric(8, 2),
    status public.shipment_status not null default 'awaiting_drop_off',
    pickup_confirmed_at timestamptz,
    returned_at timestamptz,
    delivered_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint shipments_declared_value_check check (
        declared_value is null or declared_value >= 0
    ),
    constraint shipments_actual_weight_check check (
        actual_weight_kg is null or actual_weight_kg > 0
    )
);

create table public.shipment_recipients (
    id uuid primary key default gen_random_uuid(),
    shipment_id uuid not null unique references public.shipments(id) on delete cascade,
    recipient_user_id uuid not null references public.users(id) on delete restrict,
    recipient_type public.recipient_type not null,
    invitation_status public.invitation_status not null,
    invited_at timestamptz,
    accepted_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint shipment_recipients_invitation_check check (
        (recipient_type = 'buyer' and invitation_status = 'not_required')
        or recipient_type = 'third_party'
    ),
    constraint shipment_recipients_accepted_at_check check (
        invitation_status <> 'accepted' or accepted_at is not null
    ),
    constraint shipment_recipients_invited_at_check check (
        invitation_status = 'not_required' or invited_at is not null
    )
);

create table public.parcels (
    id uuid primary key default gen_random_uuid(),
    shipment_id uuid not null references public.shipments(id) on delete cascade,
    parcel_type public.parcel_type not null,
    description text not null,
    weight_kg numeric(8, 2) not null,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint parcels_weight_check check (weight_kg > 0)
);

create table public.parcel_evidence (
    id uuid primary key default gen_random_uuid(),
    parcel_id uuid not null references public.parcels(id) on delete cascade,
    added_by_user_id uuid not null references public.users(id) on delete restrict,
    stage public.evidence_stage not null,
    storage_path text not null unique,
    mime_type varchar(150) not null,
    captured_at timestamptz not null default now(),
    created_at timestamptz not null default now()
);

create table public.disputes (
    id uuid primary key default gen_random_uuid(),
    booking_id uuid not null references public.bookings(id) on delete cascade,
    opened_by_user_id uuid not null references public.users(id) on delete restrict,
    type public.dispute_type not null,
    description text not null,
    status public.dispute_status not null default 'open',
    resolution text,
    resolved_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint disputes_resolution_check check (
        status not in ('resolved', 'rejected', 'closed') or resolution is not null
    ),
    constraint disputes_resolved_at_check check (
        status not in ('resolved', 'rejected', 'closed') or resolved_at is not null
    )
);

create table public.reviews (
    id uuid primary key default gen_random_uuid(),
    booking_id uuid not null unique references public.bookings(id) on delete restrict,
    reviewer_user_id uuid not null references public.users(id) on delete restrict,
    reviewed_user_id uuid not null references public.users(id) on delete restrict,
    rating smallint not null,
    comment text,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint reviews_rating_check check (rating between 1 and 5),
    constraint reviews_comment_check check (
        comment is null or char_length(trim(comment)) between 1 and 1000
    ),
    constraint reviews_distinct_users_check check (
        reviewer_user_id <> reviewed_user_id
    )
);

create table public.delivery_tokens (
    id uuid primary key default gen_random_uuid(),
    booking_id uuid not null references public.bookings(id) on delete cascade,
    purpose public.delivery_token_purpose not null,
    issued_for_user_id uuid references public.users(id) on delete restrict,
    token_hash text not null,
    expires_at timestamptz not null,
    used_at timestamptz,
    invalidated_at timestamptz,
    failed_attempts integer not null default 0,
    created_at timestamptz not null default now(),
    constraint delivery_tokens_expiration_check check (expires_at > created_at),
    constraint delivery_tokens_failed_attempts_check check (failed_attempts >= 0),
    constraint delivery_tokens_terminal_check check (
        used_at is null or invalidated_at is null
    )
);

create table public.delivery_token_attempts (
    id uuid primary key default gen_random_uuid(),
    token_id uuid not null references public.delivery_tokens(id) on delete restrict,
    attempted_by_user_id uuid references public.users(id) on delete set null,
    succeeded boolean not null,
    failure_reason varchar(80),
    attempted_at timestamptz not null default now(),
    constraint delivery_token_attempts_reason_check check (
        succeeded or failure_reason is not null
    )
);

create table public.booking_conversations (
    booking_id uuid primary key references public.bookings(id) on delete cascade,
    conversation_id uuid not null unique references public.conversations(id) on delete cascade,
    created_at timestamptz not null default now()
);

create index bookings_listing_id_idx on public.bookings(listing_id);
create index bookings_buyer_user_id_idx on public.bookings(buyer_user_id, created_at desc);
create index shipments_status_idx on public.shipments(status);
create index shipment_recipients_user_id_idx on public.shipment_recipients(recipient_user_id);
create index parcels_shipment_id_idx on public.parcels(shipment_id);
create index parcel_evidence_parcel_id_idx on public.parcel_evidence(parcel_id, captured_at);
create index disputes_booking_id_idx on public.disputes(booking_id, created_at desc);
create index reviews_reviewed_user_idx
on public.reviews(reviewed_user_id, created_at desc, id desc);
create index reviews_reviewer_user_idx
on public.reviews(reviewer_user_id, created_at desc);
create unique index delivery_tokens_one_active_idx
on public.delivery_tokens(booking_id, purpose)
where used_at is null and invalidated_at is null;
create index delivery_token_attempts_token_idx
on public.delivery_token_attempts(token_id, attempted_at desc);

create trigger bookings_set_updated_at before update on public.bookings
for each row execute function public.set_updated_at();
create trigger shipments_set_updated_at before update on public.shipments
for each row execute function public.set_updated_at();
create trigger shipment_recipients_set_updated_at before update on public.shipment_recipients
for each row execute function public.set_updated_at();
create trigger parcels_set_updated_at before update on public.parcels
for each row execute function public.set_updated_at();
create trigger disputes_set_updated_at before update on public.disputes
for each row execute function public.set_updated_at();
create trigger reviews_set_updated_at before update on public.reviews
for each row execute function public.set_updated_at();

create trigger bookings_record_status_history
after insert or update of status on public.bookings
for each row execute function public.record_status_history('status');
create trigger bookings_record_payment_status_history
after insert or update of payment_status on public.bookings
for each row execute function public.record_status_history('payment_status');
create trigger shipments_record_status_history
after insert or update of status on public.shipments
for each row execute function public.record_status_history('status');
create trigger recipients_record_invitation_history
after insert or update of invitation_status on public.shipment_recipients
for each row execute function public.record_status_history('invitation_status');
create trigger disputes_record_status_history
after insert or update of status on public.disputes
for each row execute function public.record_status_history('status');

create or replace function public.is_booking_participant(
    target_booking_id uuid, target_user_id uuid
) returns boolean
language sql stable security definer set search_path = ''
as $$
    select exists (
        select 1
        from public.bookings booking
        join public.listings listing on listing.id = booking.listing_id
        join public.trips trip on trip.id = listing.trip_id
        left join public.shipments shipment on shipment.booking_id = booking.id
        left join public.shipment_recipients recipient
          on recipient.shipment_id = shipment.id
         and recipient.invitation_status in ('not_required', 'accepted')
        where booking.id = target_booking_id
          and target_user_id in (
              booking.buyer_user_id, trip.traveler_user_id, recipient.recipient_user_id
          )
    );
$$;

revoke all on function public.is_booking_participant(uuid, uuid) from public;
grant execute on function public.is_booking_participant(uuid, uuid) to authenticated;

create or replace function public.validate_booking_parties()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if not exists (
        select 1
        from public.listings listing
        where listing.id = new.listing_id
          and listing.status in ('open', 'closed')
          and listing.price_per_kg = new.price_per_kg
          and listing.currency = new.currency
    ) then
        raise exception 'The booking price and currency must match its listing';
    end if;
    if exists (
        select 1 from public.listings listing
        join public.trips trip on trip.id = listing.trip_id
        where listing.id = new.listing_id
          and trip.traveler_user_id = new.buyer_user_id
    ) then
        raise exception 'A traveler cannot book their own listing';
    end if;
    return new;
end;
$$;

create trigger bookings_validate_parties
before insert on public.bookings
for each row execute function public.validate_booking_parties();

create or replace function public.protect_booking_commercial_data()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.listing_id <> new.listing_id
       or old.buyer_user_id <> new.buyer_user_id
       or old.reserved_kg <> new.reserved_kg
       or old.price_per_kg <> new.price_per_kg
       or old.subtotal <> new.subtotal
       or old.platform_fee <> new.platform_fee
       or old.total_amount <> new.total_amount
       or old.currency <> new.currency
       or old.expires_at <> new.expires_at then
        raise exception 'Booking commercial data is immutable';
    end if;
    return new;
end;
$$;

create trigger bookings_protect_commercial_data
before update on public.bookings
for each row execute function public.protect_booking_commercial_data();

create or replace function public.protect_booking_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.status <> new.status and not (
        (old.status = 'pending' and new.status in ('confirmed', 'cancelled_before_pickup'))
        or (old.status = 'confirmed' and new.status in (
            'cancellation_pending_return', 'cancelled_before_pickup', 'completed', 'refunded'
        ))
        or (old.status = 'cancellation_pending_return'
            and new.status in ('cancelled_after_return', 'refunded'))
        or (old.status in ('completed', 'cancelled_after_return') and new.status = 'refunded')
    ) then
        raise exception 'Invalid booking status transition';
    end if;
    return new;
end;
$$;

create trigger bookings_protect_status_transition
before update of status on public.bookings
for each row execute function public.protect_booking_status_transition();

create or replace function public.protect_payment_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.payment_status <> new.payment_status and not (
        (old.payment_status = 'pending'
            and new.payment_status in ('method_verified', 'failed', 'cancelled'))
        or (old.payment_status = 'method_verified'
            and new.payment_status in ('paid', 'failed', 'cancelled'))
        or (old.payment_status = 'failed' and new.payment_status = 'pending')
        or (old.payment_status = 'paid' and new.payment_status = 'refunded')
    ) then
        raise exception 'Invalid payment status transition';
    end if;
    return new;
end;
$$;

create trigger bookings_protect_payment_status_transition
before update of payment_status on public.bookings
for each row execute function public.protect_payment_status_transition();

create or replace function public.create_booking_atomic(
    target_listing_id uuid,
    target_buyer_user_id uuid,
    requested_kg numeric,
    calculated_platform_fee numeric,
    payment_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    listing_record record;
    booking_uuid uuid;
    calculated_subtotal numeric(18, 2);
begin
    if requested_kg <= 0 or calculated_platform_fee < 0
       or payment_expires_at <= now() then
        raise exception 'Booking weight and platform fee are invalid';
    end if;

    select listing.*, trip.traveler_user_id
    into listing_record
    from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where listing.id = target_listing_id
    for update of listing;

    if not found or listing_record.status <> 'open' then
        raise exception 'The listing is not available';
    end if;
    if listing_record.traveler_user_id = target_buyer_user_id then
        raise exception 'A traveler cannot book their own listing';
    end if;
    if listing_record.remaining_kg < requested_kg then
        raise exception 'The listing does not have enough remaining capacity';
    end if;

    calculated_subtotal := round(requested_kg * listing_record.price_per_kg, 2);

    update public.listings
    set remaining_kg = remaining_kg - requested_kg
    where id = target_listing_id;

    insert into public.bookings (
        listing_id, buyer_user_id, reserved_kg, price_per_kg,
        subtotal, platform_fee, total_amount, currency, expires_at
    ) values (
        target_listing_id, target_buyer_user_id, requested_kg,
        listing_record.price_per_kg, calculated_subtotal,
        calculated_platform_fee, calculated_subtotal + calculated_platform_fee,
        listing_record.currency, payment_expires_at
    ) returning id into booking_uuid;

    return booking_uuid;
end;
$$;

revoke all on function public.create_booking_atomic(uuid, uuid, numeric, numeric, timestamptz)
from public, authenticated;
grant execute on function public.create_booking_atomic(uuid, uuid, numeric, numeric, timestamptz)
to service_role;

create or replace function public.cancel_booking_before_pickup_atomic(
    target_booking_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare booking_record record;
begin
    select booking.*, listing.trip_id
    into booking_record
    from public.bookings booking
    join public.listings listing on listing.id = booking.listing_id
    where booking.id = target_booking_id
    for update of booking, listing;

    if not found or booking_record.status not in ('pending', 'confirmed')
       or booking_record.payment_status not in ('pending', 'method_verified', 'failed') then
        raise exception 'The booking cannot be cancelled before pickup';
    end if;
    if exists (
        select 1 from public.shipments shipment
        where shipment.booking_id = target_booking_id
          and shipment.status not in ('awaiting_drop_off', 'photos_required')
    ) then
        raise exception 'The parcel has already been picked up';
    end if;

    update public.bookings
    set status = 'cancelled_before_pickup',
        payment_status = case
            when payment_status in ('pending', 'method_verified')
                then 'cancelled'::public.payment_status
            else payment_status
        end,
        cancelled_at = now()
    where id = target_booking_id;

    update public.listings listing
    set remaining_kg = least(
            listing.total_available_kg,
            listing.remaining_kg + booking_record.reserved_kg
        ),
        status = case
            when listing.status = 'closed'
             and listing.closed_reason = 'capacity_reached'
             and trip.status in ('draft', 'scheduled')
                then 'open'::public.listing_status
            else listing.status
        end
    from public.trips trip
    where listing.id = booking_record.listing_id
      and trip.id = listing.trip_id;
end;
$$;

revoke all on function public.cancel_booking_before_pickup_atomic(uuid)
from public, authenticated;
grant execute on function public.cancel_booking_before_pickup_atomic(uuid)
to service_role;

create or replace function public.validate_shipment_recipient()
returns trigger language plpgsql set search_path = ''
as $$
declare booking_buyer_id uuid;
begin
    select booking.buyer_user_id into booking_buyer_id
    from public.shipments shipment
    join public.bookings booking on booking.id = shipment.booking_id
    where shipment.id = new.shipment_id;

    if new.recipient_type = 'buyer' and new.recipient_user_id <> booking_buyer_id then
        raise exception 'A buyer recipient must be the booking buyer';
    end if;
    if new.recipient_type = 'third_party' and new.recipient_user_id = booking_buyer_id then
        raise exception 'A third-party recipient must differ from the booking buyer';
    end if;
    return new;
end;
$$;

create trigger shipment_recipients_validate
before insert or update of shipment_id, recipient_user_id, recipient_type
on public.shipment_recipients
for each row execute function public.validate_shipment_recipient();

create or replace function public.validate_shipment_weight()
returns trigger language plpgsql set search_path = ''
as $$
declare reserved_weight numeric(8, 2);
begin
    select booking.reserved_kg into reserved_weight
    from public.bookings booking where booking.id = new.booking_id;
    if new.actual_weight_kg is not null and new.actual_weight_kg > reserved_weight then
        raise exception 'Shipment weight exceeds the reserved weight';
    end if;
    return new;
end;
$$;

create trigger shipments_validate_weight
before insert or update of booking_id, actual_weight_kg on public.shipments
for each row execute function public.validate_shipment_weight();

create or replace function public.validate_parcel_type_for_listing()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if not exists (
        select 1
        from public.shipments shipment
        join public.bookings booking on booking.id = shipment.booking_id
        join public.listing_accepted_parcel_types accepted
          on accepted.listing_id = booking.listing_id
        where shipment.id = new.shipment_id
          and accepted.parcel_type = new.parcel_type
    ) then
        raise exception 'Parcel type is not accepted by the listing';
    end if;
    return new;
end;
$$;

create trigger parcels_validate_listing_type
before insert or update of shipment_id, parcel_type on public.parcels
for each row execute function public.validate_parcel_type_for_listing();

create or replace function public.validate_parcel_total_weight()
returns trigger language plpgsql set search_path = ''
as $$
declare
    target_shipment_id uuid := coalesce(new.shipment_id, old.shipment_id);
    total_weight numeric(8, 2);
    reserved_weight numeric(8, 2);
    current_shipment_status public.shipment_status;
begin
    select coalesce(sum(parcel.weight_kg), 0)
    into total_weight from public.parcels parcel
    where parcel.shipment_id = target_shipment_id;

    select booking.reserved_kg, shipment.status
    into reserved_weight, current_shipment_status
    from public.shipments shipment
    join public.bookings booking on booking.id = shipment.booking_id
    where shipment.id = target_shipment_id;

    if total_weight > reserved_weight then
        raise exception 'Total parcel weight exceeds the reserved weight';
    end if;
    if current_shipment_status not in ('awaiting_drop_off', 'photos_required')
       and total_weight = 0 then
        raise exception 'An active shipment must retain at least one parcel';
    end if;
    return null;
end;
$$;

create constraint trigger parcels_validate_total_weight
after insert or update or delete on public.parcels
deferrable initially immediate
for each row execute function public.validate_parcel_total_weight();

create or replace function public.validate_shipment_progress()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if new.status not in ('awaiting_drop_off', 'photos_required') then
        if not exists (select 1 from public.parcels where shipment_id = new.id) then
            raise exception 'A shipment requires at least one parcel before pickup';
        end if;
        if not exists (
            select 1 from public.shipment_recipients
            where shipment_id = new.id
              and invitation_status in ('not_required', 'accepted')
        ) then
            raise exception 'The shipment requires an accepted recipient before pickup';
        end if;
        if new.status = 'received_by_traveler' and exists (
            select 1
            from public.parcels parcel
            where parcel.shipment_id = new.id
              and not exists (
                  select 1 from public.parcel_evidence evidence
                  where evidence.parcel_id = parcel.id
                    and evidence.stage = 'before_pickup'
              )
        ) then
            raise exception 'Every parcel requires before-pickup evidence';
        end if;
    end if;
    return new;
end;
$$;

create trigger shipments_validate_progress
before update of status on public.shipments
for each row execute function public.validate_shipment_progress();

create or replace function public.protect_shipment_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.status <> new.status and not (
        (old.status = 'awaiting_drop_off' and new.status = 'photos_required')
        or (old.status = 'photos_required' and new.status = 'received_by_traveler')
        or (old.status = 'received_by_traveler'
            and new.status in ('in_transit', 'returned', 'disputed'))
        or (old.status = 'in_transit' and new.status in ('arrived', 'disputed'))
        or (old.status = 'arrived' and new.status in ('ready_for_pickup', 'disputed'))
        or (old.status = 'ready_for_pickup' and new.status in ('delivered', 'disputed'))
        or (old.status = 'disputed' and new.status in ('delivered', 'returned'))
    ) then
        raise exception 'Invalid shipment status transition';
    end if;
    return new;
end;
$$;

create trigger shipments_protect_status_transition
before update of status on public.shipments
for each row execute function public.protect_shipment_status_transition();

create or replace function public.validate_booking_actor()
returns trigger language plpgsql set search_path = ''
as $$
declare
    target_booking_id uuid;
    target_user_id uuid;
begin
    if tg_table_name = 'disputes' then
        target_booking_id := new.booking_id;
        target_user_id := new.opened_by_user_id;
    else
        select shipment.booking_id into target_booking_id
        from public.parcels parcel
        join public.shipments shipment on shipment.id = parcel.shipment_id
        where parcel.id = new.parcel_id;
        target_user_id := new.added_by_user_id;
    end if;
    if not public.is_booking_participant(target_booking_id, target_user_id) then
        raise exception 'The user is not a booking participant';
    end if;
    return new;
end;
$$;

create trigger disputes_validate_actor
before insert or update of booking_id, opened_by_user_id on public.disputes
for each row execute function public.validate_booking_actor();
create trigger parcel_evidence_validate_actor
before insert or update of parcel_id, added_by_user_id on public.parcel_evidence
for each row execute function public.validate_booking_actor();

create or replace function public.protect_trip_with_active_bookings()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if (
        old.type is distinct from new.type
        or old.departure_location_id is distinct from new.departure_location_id
        or old.arrival_location_id is distinct from new.arrival_location_id
        or old.departure_at is distinct from new.departure_at
        or old.arrival_at is distinct from new.arrival_at
        or (old.status is distinct from new.status and new.status = 'cancelled')
    ) and exists (
        select 1
        from public.listings listing
        join public.bookings booking on booking.listing_id = listing.id
        where listing.trip_id = old.id
          and booking.status in ('pending', 'confirmed', 'cancellation_pending_return')
    ) then
        raise exception 'A trip with active bookings cannot be materially changed';
    end if;
    return new;
end;
$$;

create trigger trips_protect_active_bookings
before update of type, departure_location_id, arrival_location_id,
    departure_at, arrival_at, status
on public.trips
for each row execute function public.protect_trip_with_active_bookings();

create or replace function public.protect_dispute_status_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.status <> new.status and not (
        (old.status = 'open' and new.status in ('under_review', 'closed'))
        or (old.status = 'under_review' and new.status in ('resolved', 'rejected', 'closed'))
    ) then
        raise exception 'Invalid dispute status transition';
    end if;
    return new;
end;
$$;

create trigger disputes_protect_status_transition
before update of status on public.disputes
for each row execute function public.protect_dispute_status_transition();

create or replace function public.issue_delivery_token(
    target_booking_id uuid,
    target_purpose public.delivery_token_purpose,
    target_user_id uuid,
    plain_token text,
    token_expires_at timestamptz
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare token_uuid uuid;
begin
    if length(plain_token) < 16 or token_expires_at <= now() then
        raise exception 'Token value or expiration is invalid';
    end if;
    if not public.is_booking_participant(target_booking_id, target_user_id) then
        raise exception 'Token recipient is not a booking participant';
    end if;
    update public.delivery_tokens
    set invalidated_at = now()
    where booking_id = target_booking_id
      and purpose = target_purpose
      and used_at is null and invalidated_at is null;
    insert into public.delivery_tokens (
        booking_id, purpose, issued_for_user_id, token_hash, expires_at
    ) values (
        target_booking_id, target_purpose, target_user_id,
        public.crypt(plain_token, public.gen_salt('bf', 10)), token_expires_at
    ) returning id into token_uuid;
    return token_uuid;
end;
$$;

create or replace function public.consume_delivery_token(
    target_booking_id uuid,
    target_purpose public.delivery_token_purpose,
    target_user_id uuid,
    plain_token text
)
returns boolean language plpgsql security definer set search_path = ''
as $$
declare token_record record; token_matches boolean;
begin
    select * into token_record
    from public.delivery_tokens
    where booking_id = target_booking_id and purpose = target_purpose
      and used_at is null and invalidated_at is null
    for update;
    if not found then return false; end if;

    if token_record.expires_at <= now() then
        update public.delivery_tokens set invalidated_at = now()
        where id = token_record.id;
        insert into public.delivery_token_attempts (
            token_id, attempted_by_user_id, succeeded, failure_reason
        ) values (token_record.id, target_user_id, false, 'expired');
        return false;
    end if;
    if token_record.issued_for_user_id is distinct from target_user_id then
        insert into public.delivery_token_attempts (
            token_id, attempted_by_user_id, succeeded, failure_reason
        ) values (token_record.id, target_user_id, false, 'wrong_user');
        return false;
    end if;

    token_matches := token_record.token_hash = public.crypt(
        plain_token, token_record.token_hash
    );
    insert into public.delivery_token_attempts (
        token_id, attempted_by_user_id, succeeded, failure_reason
    ) values (
        token_record.id, target_user_id, token_matches,
        case when token_matches then null else 'invalid_token' end
    );
    if token_matches then
        update public.delivery_tokens set used_at = now()
        where id = token_record.id;
        return true;
    end if;

    update public.delivery_tokens
    set failed_attempts = failed_attempts + 1,
        invalidated_at = case
            when failed_attempts + 1 >= 5 then now() else invalidated_at
        end
    where id = token_record.id;
    return false;
end;
$$;

create trigger delivery_token_attempts_immutable
before update or delete on public.delivery_token_attempts
for each row execute function public.prevent_audit_mutation();

revoke all on function public.issue_delivery_token(
    uuid, public.delivery_token_purpose, uuid, text, timestamptz
) from public, authenticated;
revoke all on function public.consume_delivery_token(
    uuid, public.delivery_token_purpose, uuid, text
) from public, authenticated;
grant execute on function public.issue_delivery_token(
    uuid, public.delivery_token_purpose, uuid, text, timestamptz
) to service_role;
grant execute on function public.consume_delivery_token(
    uuid, public.delivery_token_purpose, uuid, text
) to service_role;

create or replace function public.ensure_booking_delivery_conversation()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
    booking_uuid uuid;
    buyer_uuid uuid;
    traveler_uuid uuid;
    conversation_uuid uuid;
    existing_conversation_uuid uuid;
    existing_recipient_uuid uuid;
begin
    if new.recipient_type <> 'third_party' or new.invitation_status <> 'accepted' then
        return new;
    end if;
    select booking.id, booking.buyer_user_id, trip.traveler_user_id
    into booking_uuid, buyer_uuid, traveler_uuid
    from public.shipments shipment
    join public.bookings booking on booking.id = shipment.booking_id
    join public.listings listing on listing.id = booking.listing_id
    join public.trips trip on trip.id = listing.trip_id
    where shipment.id = new.shipment_id;
    if new.recipient_user_id = buyer_uuid then return new; end if;
    perform 1 from public.bookings where id = booking_uuid for update;
    select link.conversation_id into existing_conversation_uuid
    from public.booking_conversations link where link.booking_id = booking_uuid;
    if existing_conversation_uuid is not null then
        select participant.user_id into existing_recipient_uuid
        from public.conversation_participants participant
        where participant.conversation_id = existing_conversation_uuid
          and participant.role = 'recipient' and participant.left_at is null;
        if existing_recipient_uuid = new.recipient_user_id then return new; end if;
        update public.conversations set status = 'closed', closed_at = now()
        where id = existing_conversation_uuid and status = 'active';
        delete from public.booking_conversations where booking_id = booking_uuid;
    end if;

    conversation_uuid := public.create_conversation_with_participants(
        'delivery_group', buyer_uuid,
        jsonb_build_array(
            jsonb_build_object('user_id', buyer_uuid, 'role', 'buyer'),
            jsonb_build_object('user_id', traveler_uuid, 'role', 'traveler'),
            jsonb_build_object('user_id', new.recipient_user_id, 'role', 'recipient')
        )
    );
    insert into public.booking_conversations (booking_id, conversation_id)
    values (booking_uuid, conversation_uuid)
    on conflict (booking_id) do nothing;
    return new;
end;
$$;

create trigger shipment_recipients_ensure_conversation
after insert or update of invitation_status, recipient_user_id
on public.shipment_recipients
for each row execute function public.ensure_booking_delivery_conversation();

create or replace function public.close_booking_delivery_conversation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
    if new.status in ('delivered', 'returned')
       and old.status is distinct from new.status then
        update public.conversations conversation
        set status = 'closed', closed_at = coalesce(closed_at, now())
        from public.booking_conversations link
        where link.booking_id = new.booking_id
          and conversation.id = link.conversation_id
          and conversation.status = 'active';
    end if;
    return new;
end;
$$;

create trigger shipments_close_delivery_conversation
after update of status on public.shipments
for each row execute function public.close_booking_delivery_conversation();

create or replace function public.refresh_user_completed_delivery_count(
    target_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.users
    set completed_delivery_count = (
        select count(*)::integer
        from public.bookings booking
        join public.shipments shipment on shipment.booking_id = booking.id
        join public.listings listing on listing.id = booking.listing_id
        join public.trips trip on trip.id = listing.trip_id
        where trip.traveler_user_id = target_user_id
          and booking.status = 'completed'
          and shipment.status = 'delivered'
    )
    where id = target_user_id;
end;
$$;

create or replace function public.refresh_booking_traveler_delivery_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    traveler_uuid uuid;
begin
    select trip.traveler_user_id
    into traveler_uuid
    from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where listing.id = new.listing_id;

    if traveler_uuid is not null then
        perform 1 from public.users where id = traveler_uuid for update;
        perform public.refresh_user_completed_delivery_count(traveler_uuid);
    end if;
    return new;
end;
$$;

create trigger bookings_refresh_completed_delivery_count
after update of status on public.bookings
for each row
when (old.status is distinct from new.status)
execute function public.refresh_booking_traveler_delivery_count();

create or replace function public.refresh_shipment_traveler_delivery_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
    traveler_uuid uuid;
begin
    select trip.traveler_user_id
    into traveler_uuid
    from public.bookings booking
    join public.listings listing on listing.id = booking.listing_id
    join public.trips trip on trip.id = listing.trip_id
    where booking.id = new.booking_id;

    if traveler_uuid is not null then
        perform 1 from public.users where id = traveler_uuid for update;
        perform public.refresh_user_completed_delivery_count(traveler_uuid);
    end if;
    return new;
end;
$$;

create trigger shipments_refresh_completed_delivery_count
after update of status on public.shipments
for each row
when (old.status is distinct from new.status)
execute function public.refresh_shipment_traveler_delivery_count();

revoke all on function public.refresh_user_completed_delivery_count(uuid)
from public, authenticated;

create or replace function public.protect_review_relationships()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.booking_id <> new.booking_id
       or old.reviewer_user_id <> new.reviewer_user_id
       or old.reviewed_user_id <> new.reviewed_user_id then
        raise exception 'Review relationships are immutable';
    end if;
    return new;
end;
$$;

create trigger reviews_protect_relationships
before update on public.reviews
for each row execute function public.protect_review_relationships();

create or replace function public.refresh_user_rating(target_user_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
    update public.users
    set average_rating = coalesce((
            select round(avg(review.rating)::numeric, 2)
            from public.reviews review
            where review.reviewed_user_id = target_user_id
        ), 0),
        review_count = (
            select count(*)
            from public.reviews review
            where review.reviewed_user_id = target_user_id
        )
    where id = target_user_id;
end;
$$;

create or replace function public.refresh_reviewed_user_rating()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
    if tg_op = 'DELETE' then
        perform public.refresh_user_rating(old.reviewed_user_id);
        return old;
    end if;

    perform public.refresh_user_rating(new.reviewed_user_id);
    if tg_op = 'UPDATE'
       and old.reviewed_user_id is distinct from new.reviewed_user_id then
        perform public.refresh_user_rating(old.reviewed_user_id);
    end if;
    return new;
end;
$$;

create trigger reviews_refresh_user_rating
after insert or update of rating or delete on public.reviews
for each row execute function public.refresh_reviewed_user_rating();

create or replace function public.submit_delivery_review(
    target_booking_id uuid,
    target_reviewer_user_id uuid,
    target_rating smallint,
    target_comment text
)
returns public.reviews
language plpgsql
security definer
set search_path = ''
as $$
declare
    booking_record record;
    review_record public.reviews%rowtype;
begin
    if target_rating < 1 or target_rating > 5 then
        raise exception 'Rating must be between 1 and 5';
    end if;

    select booking.id, booking.buyer_user_id, booking.status,
           shipment.status as shipment_status, trip.traveler_user_id
    into booking_record
    from public.bookings booking
    join public.shipments shipment on shipment.booking_id = booking.id
    join public.listings listing on listing.id = booking.listing_id
    join public.trips trip on trip.id = listing.trip_id
    where booking.id = target_booking_id;

    if not found then raise exception 'Booking not found'; end if;
    if booking_record.buyer_user_id <> target_reviewer_user_id then
        raise exception 'Only the booking buyer can review this delivery';
    end if;
    if booking_record.status <> 'completed'
       or booking_record.shipment_status <> 'delivered' then
        raise exception 'The delivery must be completed before review';
    end if;

    -- Serialize reviews targeting the same traveler so the cached aggregate
    -- cannot lose a concurrently committed rating.
    perform 1
    from public.users
    where id = booking_record.traveler_user_id
    for update;

    insert into public.reviews (
        booking_id, reviewer_user_id, reviewed_user_id, rating, comment
    ) values (
        target_booking_id,
        target_reviewer_user_id,
        booking_record.traveler_user_id,
        target_rating,
        nullif(trim(target_comment), '')
    )
    returning * into review_record;

    return review_record;
exception
    when unique_violation then
        raise exception 'This delivery has already been reviewed';
end;
$$;

revoke all on function public.refresh_user_rating(uuid)
from public, authenticated;
revoke all on function public.submit_delivery_review(uuid, uuid, smallint, text)
from public, authenticated;
grant execute on function public.submit_delivery_review(uuid, uuid, smallint, text)
to service_role;

alter table public.bookings enable row level security;
alter table public.shipments enable row level security;
alter table public.shipment_recipients enable row level security;
alter table public.parcels enable row level security;
alter table public.parcel_evidence enable row level security;
alter table public.disputes enable row level security;
alter table public.delivery_tokens enable row level security;
alter table public.delivery_token_attempts enable row level security;
alter table public.booking_conversations enable row level security;
alter table public.reviews enable row level security;

create policy bookings_read_participants on public.bookings for select to authenticated
using (public.is_booking_participant(id, (select auth.uid())));
create policy shipments_read_participants on public.shipments for select to authenticated
using (public.is_booking_participant(booking_id, (select auth.uid())));
create policy recipients_read_participants on public.shipment_recipients for select to authenticated
using (exists (select 1 from public.shipments shipment where shipment.id = shipment_id
and public.is_booking_participant(shipment.booking_id, (select auth.uid()))));
create policy parcels_read_participants on public.parcels for select to authenticated
using (exists (select 1 from public.shipments shipment where shipment.id = shipment_id
and public.is_booking_participant(shipment.booking_id, (select auth.uid()))));
create policy evidence_read_participants on public.parcel_evidence for select to authenticated
using (exists (select 1 from public.parcels parcel join public.shipments shipment
on shipment.id = parcel.shipment_id where parcel.id = parcel_id
and public.is_booking_participant(shipment.booking_id, (select auth.uid()))));
create policy disputes_read_participants on public.disputes for select to authenticated
using (public.is_booking_participant(booking_id, (select auth.uid())));
create policy reviews_read_authenticated
on public.reviews for select to authenticated using (true);

create policy booking_conversations_read_participants
on public.booking_conversations for select to authenticated
using (public.is_booking_participant(booking_id, (select auth.uid())));

insert into storage.buckets (
    id, name, public, file_size_limit, allowed_mime_types
) values (
    'parcel-evidence', 'parcel-evidence', false, 20971520,
    array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
    public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create policy parcel_evidence_storage_read
on storage.objects for select to authenticated
using (
    bucket_id = 'parcel-evidence'
    and exists (
        select 1
        from public.parcel_evidence evidence
        join public.parcels parcel on parcel.id = evidence.parcel_id
        join public.shipments shipment on shipment.id = parcel.shipment_id
        where evidence.storage_path = name
          and public.is_booking_participant(
              shipment.booking_id, (select auth.uid())
          )
    )
);

commit;
