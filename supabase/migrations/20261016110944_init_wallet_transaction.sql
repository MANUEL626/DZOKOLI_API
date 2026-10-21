begin;

create type public.wallet_transaction_type as enum (
    'top_up', 'reservation', 'release', 'payment', 'earning',
    'commission', 'refund', 'withdrawal', 'adjustment'
);
create type public.transaction_direction as enum ('credit', 'debit');
create type public.wallet_balance_type as enum ('available', 'reserved', 'pending');
create type public.wallet_transaction_status as enum (
    'pending', 'completed', 'failed', 'cancelled'
);
create type public.wallet_hold_status as enum (
    'active', 'captured', 'released', 'expired', 'cancelled'
);
create type public.escrow_status as enum (
    'funded', 'held', 'released', 'partially_refunded', 'refunded', 'disputed'
);
create type public.wallet_payout_status as enum (
    'pending', 'released', 'cancelled'
);

create table public.wallet_transactions (
    id uuid primary key default gen_random_uuid(),
    wallet_id uuid not null references public.wallets(id) on delete restrict,
    booking_id uuid references public.bookings(id) on delete restrict,
    related_transaction_id uuid references public.wallet_transactions(id) on delete restrict,
    type public.wallet_transaction_type not null,
    direction public.transaction_direction not null,
    balance_type public.wallet_balance_type not null,
    amount numeric(18, 2) not null,
    currency char(3) not null,
    status public.wallet_transaction_status not null default 'pending',
    reference varchar(120) not null unique,
    description text,
    metadata jsonb not null default '{}'::jsonb,
    created_at timestamptz not null default now(),
    completed_at timestamptz,
    constraint wallet_transactions_amount_check check (amount > 0),
    constraint wallet_transactions_currency_check check (currency ~ '^[A-Z]{3}$'),
    constraint wallet_transactions_metadata_check check (
        jsonb_typeof(metadata) = 'object'
    ),
    constraint wallet_transactions_completed_at_check check (
        (status = 'completed' and completed_at is not null)
        or (status <> 'completed' and completed_at is null)
    ),
    constraint wallet_transactions_not_self_related_check check (
        related_transaction_id is null or related_transaction_id <> id
    ),
    constraint wallet_transactions_semantics_check check (
        type = 'adjustment'
        or (type = 'top_up' and direction = 'credit' and balance_type = 'available')
        or (type = 'reservation' and (
            (direction = 'debit' and balance_type = 'available')
            or (direction = 'credit' and balance_type = 'reserved')
        ))
        or (type = 'release' and (
            (direction = 'debit' and balance_type = 'reserved')
            or (direction = 'credit' and balance_type = 'available')
        ))
        or (type = 'payment' and direction = 'debit' and balance_type = 'reserved')
        or (type = 'earning' and (
            (direction = 'credit' and balance_type in ('pending', 'available'))
            or (direction = 'debit' and balance_type = 'pending')
        ))
        or (type = 'commission' and direction = 'debit')
        or (type = 'refund' and direction = 'credit' and balance_type = 'available')
        or (type = 'withdrawal' and direction = 'debit' and balance_type = 'available')
    )
);

create table public.wallet_holds (
    id uuid primary key default gen_random_uuid(),
    wallet_id uuid not null references public.wallets(id) on delete restrict,
    booking_id uuid not null references public.bookings(id) on delete restrict,
    amount numeric(18, 2) not null,
    currency char(3) not null,
    status public.wallet_hold_status not null default 'active',
    expires_at timestamptz not null,
    captured_at timestamptz,
    released_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint wallet_holds_amount_check check (amount > 0),
    constraint wallet_holds_currency_check check (currency ~ '^[A-Z]{3}$'),
    constraint wallet_holds_expiration_check check (expires_at > created_at),
    constraint wallet_holds_capture_check check (
        (status = 'captured' and captured_at is not null)
        or (status <> 'captured' and captured_at is null)
    ),
    constraint wallet_holds_release_check check (
        (status in ('released', 'expired', 'cancelled') and released_at is not null)
        or (status not in ('released', 'expired', 'cancelled') and released_at is null)
    )
);

create table public.escrows (
    id uuid primary key default gen_random_uuid(),
    booking_id uuid not null unique references public.bookings(id) on delete restrict,
    wallet_hold_id uuid unique references public.wallet_holds(id) on delete restrict,
    payer_wallet_id uuid not null references public.wallets(id) on delete restrict,
    beneficiary_wallet_id uuid not null references public.wallets(id) on delete restrict,
    gross_amount numeric(18, 2) not null,
    commission_amount numeric(18, 2) not null default 0,
    beneficiary_amount numeric(18, 2) not null,
    beneficiary_released_amount numeric(18, 2) not null default 0,
    commission_released_amount numeric(18, 2) not null default 0,
    refunded_amount numeric(18, 2) not null default 0,
    currency char(3) not null,
    status public.escrow_status not null default 'funded',
    funded_at timestamptz not null default now(),
    released_at timestamptz,
    refunded_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint escrows_different_wallets_check check (
        payer_wallet_id <> beneficiary_wallet_id
    ),
    constraint escrows_amounts_check check (
        gross_amount > 0
        and commission_amount >= 0
        and beneficiary_amount >= 0
        and gross_amount = commission_amount + beneficiary_amount
        and beneficiary_released_amount between 0 and beneficiary_amount
        and commission_released_amount between 0 and commission_amount
        and refunded_amount >= 0
        and beneficiary_released_amount + commission_released_amount
            + refunded_amount <= gross_amount
    ),
    constraint escrows_currency_check check (currency ~ '^[A-Z]{3}$'),
    constraint escrows_release_check check (
        (status in ('released', 'partially_refunded') and released_at is not null)
        or (status not in ('released', 'partially_refunded') and released_at is null)
    ),
    constraint escrows_refund_check check (
        (status in ('partially_refunded', 'refunded') and refunded_at is not null)
        or (status not in ('partially_refunded', 'refunded') and refunded_at is null)
    )
);

create table public.wallet_payouts (
    id uuid primary key default gen_random_uuid(),
    escrow_id uuid not null unique references public.escrows(id) on delete restrict,
    wallet_id uuid not null references public.wallets(id) on delete restrict,
    booking_id uuid not null references public.bookings(id) on delete restrict,
    amount numeric(18, 2) not null,
    currency char(3) not null,
    status public.wallet_payout_status not null default 'pending',
    available_at timestamptz not null,
    released_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint wallet_payouts_amount_check check (amount > 0),
    constraint wallet_payouts_currency_check check (currency ~ '^[A-Z]{3}$'),
    constraint wallet_payouts_release_check check (
        (status = 'released' and released_at is not null)
        or (status <> 'released' and released_at is null)
    )
);

create table public.platform_accounts (
    id uuid primary key default gen_random_uuid(),
    currency char(3) not null unique,
    available_balance numeric(18, 2) not null default 0,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint platform_accounts_currency_check check (currency ~ '^[A-Z]{3}$'),
    constraint platform_accounts_balance_check check (available_balance >= 0)
);

create table public.platform_transactions (
    id uuid primary key default gen_random_uuid(),
    platform_account_id uuid not null references public.platform_accounts(id) on delete restrict,
    escrow_id uuid not null references public.escrows(id) on delete restrict,
    booking_id uuid not null references public.bookings(id) on delete restrict,
    amount numeric(18, 2) not null,
    currency char(3) not null,
    reference varchar(120) not null unique,
    created_at timestamptz not null default now(),
    constraint platform_transactions_amount_check check (amount > 0),
    constraint platform_transactions_currency_check check (currency ~ '^[A-Z]{3}$')
);

create index wallet_transactions_wallet_created_idx
on public.wallet_transactions(wallet_id, created_at desc);
create index wallet_transactions_booking_idx
on public.wallet_transactions(booking_id) where booking_id is not null;
create index wallet_transactions_status_idx
on public.wallet_transactions(status) where status = 'pending';
create index wallet_holds_wallet_idx on public.wallet_holds(wallet_id, created_at desc);
create index wallet_holds_booking_idx on public.wallet_holds(booking_id);
create unique index wallet_holds_one_active_per_booking_idx
on public.wallet_holds(booking_id) where status = 'active';
create index wallet_holds_active_expiration_idx
on public.wallet_holds(expires_at) where status = 'active';
create index escrows_status_idx on public.escrows(status);
create index wallet_payouts_due_idx on public.wallet_payouts(available_at)
where status = 'pending';
create index platform_transactions_booking_idx
on public.platform_transactions(booking_id, created_at desc);

create trigger wallet_holds_set_updated_at before update on public.wallet_holds
for each row execute function public.set_updated_at();
create trigger escrows_set_updated_at before update on public.escrows
for each row execute function public.set_updated_at();
create trigger wallet_payouts_set_updated_at before update on public.wallet_payouts
for each row execute function public.set_updated_at();
create trigger platform_accounts_set_updated_at before update on public.platform_accounts
for each row execute function public.set_updated_at();

create trigger wallet_holds_record_status_history
after insert or update of status on public.wallet_holds
for each row execute function public.record_status_history('status');
create trigger escrows_record_status_history
after insert or update of status on public.escrows
for each row execute function public.record_status_history('status');
create trigger wallet_payouts_record_status_history
after insert or update of status on public.wallet_payouts
for each row execute function public.record_status_history('status');
create trigger platform_transactions_immutable
before update or delete on public.platform_transactions
for each row execute function public.prevent_audit_mutation();

create or replace function public.validate_wallet_financial_currency()
returns trigger language plpgsql set search_path = ''
as $$
declare wallet_currency char(3);
begin
    select currency into wallet_currency
    from public.wallets where id = new.wallet_id;
    if wallet_currency is distinct from new.currency then
        raise exception 'The operation currency must match the wallet currency';
    end if;
    return new;
end;
$$;

create trigger wallet_transactions_validate_currency
before insert or update of wallet_id, currency on public.wallet_transactions
for each row execute function public.validate_wallet_financial_currency();
create trigger wallet_holds_validate_currency
before insert or update of wallet_id, currency on public.wallet_holds
for each row execute function public.validate_wallet_financial_currency();

create or replace function public.validate_wallet_hold_booking()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if not exists (
        select 1
        from public.bookings booking
        join public.wallets wallet on wallet.id = new.wallet_id
        where booking.id = new.booking_id
          and booking.buyer_user_id = wallet.user_id
          and booking.currency = new.currency
          and booking.total_amount = new.amount
          and booking.expires_at = new.expires_at
    ) then
        raise exception 'The wallet hold must match the booking buyer, currency, and total';
    end if;
    return new;
end;
$$;

create trigger wallet_holds_validate_booking
before insert or update of wallet_id, booking_id, amount, currency
on public.wallet_holds for each row execute function public.validate_wallet_hold_booking();

create or replace function public.validate_escrow_wallets()
returns trigger language plpgsql set search_path = ''
as $$
declare
    payer_currency char(3);
    beneficiary_currency char(3);
begin
    select currency into payer_currency from public.wallets where id = new.payer_wallet_id;
    select currency into beneficiary_currency from public.wallets where id = new.beneficiary_wallet_id;
    if payer_currency is distinct from new.currency
       or beneficiary_currency is distinct from new.currency then
        raise exception 'Escrow and wallet currencies must match';
    end if;
    if not exists (
        select 1
        from public.bookings booking
        join public.listings listing on listing.id = booking.listing_id
        join public.trips trip on trip.id = listing.trip_id
        join public.wallets payer on payer.id = new.payer_wallet_id
        join public.wallets beneficiary on beneficiary.id = new.beneficiary_wallet_id
        where booking.id = new.booking_id
          and payer.user_id = booking.buyer_user_id
          and beneficiary.user_id = trip.traveler_user_id
          and booking.currency = new.currency
          and booking.total_amount = new.gross_amount
          and booking.platform_fee = new.commission_amount
          and booking.subtotal = new.beneficiary_amount
    ) then
        raise exception 'The escrow must match the booking payer, beneficiary, and amounts';
    end if;
    if new.wallet_hold_id is not null and not exists (
        select 1
        from public.wallet_holds hold
        where hold.id = new.wallet_hold_id
          and hold.booking_id = new.booking_id
          and hold.wallet_id = new.payer_wallet_id
          and hold.amount = new.gross_amount
          and hold.currency = new.currency
    ) then
        raise exception 'The escrow wallet hold does not match the booking';
    end if;
    return new;
end;
$$;

create trigger escrows_validate_wallets
before insert or update of booking_id, wallet_hold_id, payer_wallet_id,
    beneficiary_wallet_id, gross_amount, commission_amount, beneficiary_amount, currency
on public.escrows for each row execute function public.validate_escrow_wallets();

create or replace function public.protect_wallet_transaction()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if tg_op = 'DELETE' then
        raise exception 'Wallet transactions cannot be deleted';
    end if;
    if old.wallet_id <> new.wallet_id
       or old.booking_id is distinct from new.booking_id
       or old.related_transaction_id is distinct from new.related_transaction_id
       or old.type <> new.type
       or old.direction <> new.direction
       or old.balance_type <> new.balance_type
       or old.amount <> new.amount
       or old.currency <> new.currency
       or old.reference <> new.reference
       or old.description is distinct from new.description
       or old.metadata is distinct from new.metadata
       or old.created_at <> new.created_at then
        raise exception 'Wallet transaction accounting data is immutable';
    end if;
    if old.status <> 'pending' then
        raise exception 'A finalized wallet transaction is immutable';
    end if;
    return new;
end;
$$;

create trigger wallet_transactions_protect
before update or delete on public.wallet_transactions
for each row execute function public.protect_wallet_transaction();

create or replace function public.protect_wallet_hold_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.status <> 'active' then
        raise exception 'A finalized wallet hold is immutable';
    end if;
    if old.wallet_id <> new.wallet_id or old.booking_id <> new.booking_id
       or old.amount <> new.amount or old.currency <> new.currency
       or old.created_at <> new.created_at then
        raise exception 'Wallet hold accounting data is immutable';
    end if;
    if old.status <> new.status and not (
        old.status = 'active'
        and new.status in ('captured', 'released', 'expired', 'cancelled')
    ) then
        raise exception 'Invalid wallet hold status transition';
    end if;
    return new;
end;
$$;

create trigger wallet_holds_protect_transition
before update on public.wallet_holds
for each row execute function public.protect_wallet_hold_transition();

create or replace function public.protect_escrow_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.status in ('released', 'partially_refunded', 'refunded') then
        raise exception 'A finalized escrow is immutable';
    end if;
    if old.booking_id <> new.booking_id
       or old.wallet_hold_id is distinct from new.wallet_hold_id
       or old.payer_wallet_id <> new.payer_wallet_id
       or old.beneficiary_wallet_id <> new.beneficiary_wallet_id
       or old.gross_amount <> new.gross_amount
       or old.commission_amount <> new.commission_amount
       or old.beneficiary_amount <> new.beneficiary_amount
       or old.currency <> new.currency
       or old.funded_at <> new.funded_at
       or old.created_at <> new.created_at then
        raise exception 'Escrow accounting data is immutable';
    end if;
    if old.status <> new.status and not (
        (old.status in ('funded', 'held')
            and new.status in ('held', 'released', 'partially_refunded', 'refunded', 'disputed'))
        or (old.status = 'disputed'
            and new.status in ('released', 'partially_refunded', 'refunded'))
    ) then
        raise exception 'Invalid escrow status transition';
    end if;
    return new;
end;
$$;

create trigger escrows_protect_transition
before update on public.escrows
for each row execute function public.protect_escrow_transition();

create or replace function public.protect_wallet_payout_transition()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if old.status <> 'pending' then
        raise exception 'A finalized wallet payout is immutable';
    end if;
    if old.escrow_id <> new.escrow_id or old.wallet_id <> new.wallet_id
       or old.booking_id <> new.booking_id or old.amount <> new.amount
       or old.currency <> new.currency or old.available_at <> new.available_at
       or old.created_at <> new.created_at then
        raise exception 'Wallet payout accounting data is immutable';
    end if;
    if old.status <> new.status and not (
        old.status = 'pending' and new.status in ('released', 'cancelled')
    ) then
        raise exception 'Invalid wallet payout status transition';
    end if;
    return new;
end;
$$;

create trigger wallet_payouts_protect_transition
before update on public.wallet_payouts
for each row execute function public.protect_wallet_payout_transition();

create or replace function public.validate_wallet_payout()
returns trigger language plpgsql set search_path = ''
as $$
begin
    if not exists (
        select 1 from public.escrows escrow
        where escrow.id = new.escrow_id
          and escrow.booking_id = new.booking_id
          and escrow.beneficiary_wallet_id = new.wallet_id
          and escrow.currency = new.currency
          and new.amount <= escrow.beneficiary_amount
    ) then
        raise exception 'Wallet payout does not match its escrow';
    end if;
    return new;
end;
$$;

create trigger wallet_payouts_validate
before insert or update of escrow_id, wallet_id, booking_id, amount, currency
on public.wallet_payouts
for each row execute function public.validate_wallet_payout();

create trigger wallet_transactions_record_status_history
after insert or update of status on public.wallet_transactions
for each row execute function public.record_status_history('status');

create or replace function public.simulate_wallet_top_up(
    target_wallet_id uuid, top_up_amount numeric, transaction_reference text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare wallet_record record; transaction_uuid uuid;
begin
    if top_up_amount <= 0 then raise exception 'Top-up amount must be positive'; end if;
    select * into wallet_record from public.wallets
    where id = target_wallet_id and status = 'active' for update;
    if not found then raise exception 'Active wallet not found'; end if;

    update public.wallets set available_balance = available_balance + top_up_amount
    where id = target_wallet_id;
    insert into public.wallet_transactions (
        wallet_id, type, direction, balance_type, amount, currency,
        status, reference, completed_at
    ) values (
        target_wallet_id, 'top_up', 'credit', 'available', top_up_amount,
        wallet_record.currency, 'completed', transaction_reference, now()
    ) returning id into transaction_uuid;
    return transaction_uuid;
end;
$$;

create or replace function public.place_booking_wallet_hold(
    target_booking_id uuid, operation_reference text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare booking_record record; wallet_record record; hold_uuid uuid;
begin
    select * into booking_record from public.bookings
    where id = target_booking_id and status = 'pending' and expires_at > now()
    for update;
    if not found then raise exception 'Pending booking not found'; end if;

    select * into wallet_record from public.wallets
    where user_id = booking_record.buyer_user_id
      and currency = booking_record.currency and status = 'active' for update;
    if not found then raise exception 'Active buyer wallet not found'; end if;
    if wallet_record.available_balance < booking_record.total_amount then
        raise exception 'Insufficient available wallet balance';
    end if;

    update public.wallets
    set available_balance = available_balance - booking_record.total_amount,
        reserved_balance = reserved_balance + booking_record.total_amount
    where id = wallet_record.id;
    insert into public.wallet_holds (wallet_id, booking_id, amount, currency, expires_at)
    values (wallet_record.id, target_booking_id, booking_record.total_amount,
            booking_record.currency, booking_record.expires_at)
    returning id into hold_uuid;
    insert into public.wallet_transactions
        (wallet_id, booking_id, type, direction, balance_type, amount,
         currency, status, reference, completed_at)
    values
        (wallet_record.id, target_booking_id, 'reservation', 'debit', 'available',
         booking_record.total_amount, booking_record.currency, 'completed',
         operation_reference || ':available', now()),
        (wallet_record.id, target_booking_id, 'reservation', 'credit', 'reserved',
         booking_record.total_amount, booking_record.currency, 'completed',
         operation_reference || ':reserved', now());
    update public.bookings set payment_status = 'method_verified', status = 'confirmed',
        confirmed_at = coalesce(confirmed_at, now()) where id = target_booking_id;
    return hold_uuid;
end;
$$;

create or replace function public.release_booking_wallet_hold(
    target_hold_id uuid, operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare hold_record record;
begin
    select * into hold_record from public.wallet_holds
    where id = target_hold_id and status = 'active' for update;
    if not found then raise exception 'Active wallet hold not found'; end if;
    perform 1 from public.wallets where id = hold_record.wallet_id for update;

    update public.wallets
    set reserved_balance = reserved_balance - hold_record.amount,
        available_balance = available_balance + hold_record.amount
    where id = hold_record.wallet_id and reserved_balance >= hold_record.amount;
    if not found then raise exception 'Reserved wallet balance is inconsistent'; end if;
    update public.wallet_holds set status = 'released', released_at = now()
    where id = target_hold_id;
    insert into public.wallet_transactions
        (wallet_id, booking_id, type, direction, balance_type, amount,
         currency, status, reference, completed_at)
    values
        (hold_record.wallet_id, hold_record.booking_id, 'release', 'debit', 'reserved',
         hold_record.amount, hold_record.currency, 'completed',
         operation_reference || ':reserved', now()),
        (hold_record.wallet_id, hold_record.booking_id, 'release', 'credit', 'available',
         hold_record.amount, hold_record.currency, 'completed',
         operation_reference || ':available', now());
end;
$$;

create or replace function public.capture_hold_to_escrow(
    target_hold_id uuid, operation_reference text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare hold_record record; beneficiary_wallet uuid; booking_record record; escrow_uuid uuid;
begin
    select * into hold_record from public.wallet_holds
    where id = target_hold_id and status = 'active' for update;
    if not found then raise exception 'Active wallet hold not found'; end if;
    select booking.*, trip.traveler_user_id into booking_record
    from public.bookings booking
    join public.listings listing on listing.id = booking.listing_id
    join public.trips trip on trip.id = listing.trip_id
    where booking.id = hold_record.booking_id
      and exists (
          select 1 from public.shipments shipment
          where shipment.booking_id = booking.id
            and shipment.status = 'received_by_traveler'
      )
    for update of booking;
    if not found then
        raise exception 'The shipment pickup must be confirmed before payment capture';
    end if;
    select id into beneficiary_wallet from public.wallets
    where user_id = booking_record.traveler_user_id
      and currency = hold_record.currency and status = 'active';
    if beneficiary_wallet is null then raise exception 'Active traveler wallet not found'; end if;
    perform 1 from public.wallets where id = hold_record.wallet_id for update;

    update public.wallets set reserved_balance = reserved_balance - hold_record.amount
    where id = hold_record.wallet_id and reserved_balance >= hold_record.amount;
    if not found then raise exception 'Reserved wallet balance is inconsistent'; end if;
    update public.wallet_holds set status = 'captured', captured_at = now()
    where id = target_hold_id;
    insert into public.escrows (
        booking_id, wallet_hold_id, payer_wallet_id, beneficiary_wallet_id,
        gross_amount, commission_amount, beneficiary_amount, currency, status
    ) values (
        booking_record.id, target_hold_id, hold_record.wallet_id, beneficiary_wallet,
        booking_record.total_amount, booking_record.platform_fee,
        booking_record.subtotal, booking_record.currency, 'held'
    ) returning id into escrow_uuid;
    insert into public.wallet_transactions
        (wallet_id, booking_id, type, direction, balance_type, amount,
         currency, status, reference, completed_at)
    values (hold_record.wallet_id, booking_record.id, 'payment', 'debit', 'reserved',
        hold_record.amount, hold_record.currency, 'completed', operation_reference, now());
    update public.bookings set payment_status = 'paid' where id = booking_record.id;
    return escrow_uuid;
end;
$$;

create or replace function public.credit_platform_commission(
    target_escrow_id uuid, commission_value numeric, operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare escrow_record record; account_uuid uuid;
begin
    if commission_value = 0 then return; end if;
    select * into escrow_record from public.escrows where id = target_escrow_id;
    if not found or commission_value < 0 then
        raise exception 'Invalid platform commission';
    end if;
    insert into public.platform_accounts (currency)
    values (escrow_record.currency) on conflict (currency) do nothing;
    select id into account_uuid from public.platform_accounts
    where currency = escrow_record.currency for update;
    update public.platform_accounts
    set available_balance = available_balance + commission_value
    where id = account_uuid;
    insert into public.platform_transactions (
        platform_account_id, escrow_id, booking_id, amount, currency, reference
    ) values (
        account_uuid, target_escrow_id, escrow_record.booking_id,
        commission_value, escrow_record.currency, operation_reference
    );
end;
$$;

create or replace function public.release_escrow_to_pending(
    target_escrow_id uuid, payout_available_at timestamptz, operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare escrow_record record;
begin
    select * into escrow_record from public.escrows
    where id = target_escrow_id and status in ('funded', 'held') for update;
    if not found then raise exception 'Held escrow not found'; end if;
    if not exists (
        select 1 from public.shipments shipment
        where shipment.booking_id = escrow_record.booking_id
          and shipment.status = 'delivered'
    ) then
        raise exception 'Delivery must be confirmed before escrow release';
    end if;
    perform 1 from public.wallets where id = escrow_record.beneficiary_wallet_id for update;
    update public.wallets set pending_balance = pending_balance + escrow_record.beneficiary_amount
    where id = escrow_record.beneficiary_wallet_id;
    perform public.credit_platform_commission(
        target_escrow_id, escrow_record.commission_amount,
        operation_reference || ':commission'
    );
    update public.escrows
    set status = 'released', released_at = now(),
        beneficiary_released_amount = beneficiary_amount,
        commission_released_amount = commission_amount
    where id = target_escrow_id;
    insert into public.wallet_payouts (
        escrow_id, wallet_id, booking_id, amount, currency, available_at
    ) values (
        target_escrow_id, escrow_record.beneficiary_wallet_id,
        escrow_record.booking_id, escrow_record.beneficiary_amount,
        escrow_record.currency, payout_available_at
    );
    insert into public.wallet_transactions
        (wallet_id, booking_id, type, direction, balance_type, amount,
         currency, status, reference, completed_at)
    values (escrow_record.beneficiary_wallet_id, escrow_record.booking_id,
        'earning', 'credit', 'pending', escrow_record.beneficiary_amount,
        escrow_record.currency, 'completed', operation_reference || ':earning', now());
    update public.bookings set status = 'completed', completed_at = now()
    where id = escrow_record.booking_id;
end;
$$;

create or replace function public.refund_escrow(
    target_escrow_id uuid, operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare escrow_record record;
begin
    select * into escrow_record from public.escrows
    where id = target_escrow_id and status in ('funded', 'held', 'disputed') for update;
    if not found then raise exception 'Refundable escrow not found'; end if;
    perform 1 from public.wallets where id = escrow_record.payer_wallet_id for update;
    update public.wallets set available_balance = available_balance + escrow_record.gross_amount
    where id = escrow_record.payer_wallet_id;
    update public.escrows
    set status = 'refunded', refunded_at = now(), refunded_amount = gross_amount
    where id = target_escrow_id;
    insert into public.wallet_transactions
        (wallet_id, booking_id, type, direction, balance_type, amount,
         currency, status, reference, completed_at)
    values (escrow_record.payer_wallet_id, escrow_record.booking_id,
        'refund', 'credit', 'available', escrow_record.gross_amount,
        escrow_record.currency, 'completed', operation_reference, now());
    update public.bookings set status = 'refunded', payment_status = 'refunded'
    where id = escrow_record.booking_id;
end;
$$;

create or replace function public.resolve_disputed_escrow(
    target_escrow_id uuid,
    traveler_amount numeric,
    platform_amount numeric,
    buyer_refund_amount numeric,
    payout_available_at timestamptz,
    operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare escrow_record record; resolved_status public.escrow_status;
begin
    select * into escrow_record from public.escrows
    where id = target_escrow_id and status = 'disputed' for update;
    if not found then raise exception 'Disputed escrow not found'; end if;
    if traveler_amount < 0 or platform_amount < 0 or buyer_refund_amount < 0
       or traveler_amount > escrow_record.beneficiary_amount
       or platform_amount > escrow_record.commission_amount
       or traveler_amount + platform_amount + buyer_refund_amount
            <> escrow_record.gross_amount then
        raise exception 'Escrow resolution amounts are invalid';
    end if;

    if traveler_amount > 0 then
        perform 1 from public.wallets
        where id = escrow_record.beneficiary_wallet_id for update;
        update public.wallets set pending_balance = pending_balance + traveler_amount
        where id = escrow_record.beneficiary_wallet_id;
        insert into public.wallet_payouts (
            escrow_id, wallet_id, booking_id, amount, currency, available_at
        ) values (
            target_escrow_id, escrow_record.beneficiary_wallet_id,
            escrow_record.booking_id, traveler_amount,
            escrow_record.currency, payout_available_at
        );
        insert into public.wallet_transactions (
            wallet_id, booking_id, type, direction, balance_type, amount,
            currency, status, reference, completed_at
        ) values (
            escrow_record.beneficiary_wallet_id, escrow_record.booking_id,
            'earning', 'credit', 'pending', traveler_amount,
            escrow_record.currency, 'completed',
            operation_reference || ':traveler', now()
        );
    end if;

    if buyer_refund_amount > 0 then
        perform 1 from public.wallets
        where id = escrow_record.payer_wallet_id for update;
        update public.wallets
        set available_balance = available_balance + buyer_refund_amount
        where id = escrow_record.payer_wallet_id;
        insert into public.wallet_transactions (
            wallet_id, booking_id, type, direction, balance_type, amount,
            currency, status, reference, completed_at
        ) values (
            escrow_record.payer_wallet_id, escrow_record.booking_id,
            'refund', 'credit', 'available', buyer_refund_amount,
            escrow_record.currency, 'completed',
            operation_reference || ':buyer', now()
        );
    end if;

    perform public.credit_platform_commission(
        target_escrow_id, platform_amount, operation_reference || ':commission'
    );
    resolved_status := case
        when buyer_refund_amount = escrow_record.gross_amount then 'refunded'::public.escrow_status
        when buyer_refund_amount > 0 then 'partially_refunded'::public.escrow_status
        else 'released'::public.escrow_status
    end;
    update public.escrows
    set status = resolved_status,
        beneficiary_released_amount = traveler_amount,
        commission_released_amount = platform_amount,
        refunded_amount = buyer_refund_amount,
        released_at = case when traveler_amount + platform_amount > 0 then now() else null end,
        refunded_at = case when buyer_refund_amount > 0 then now() else null end
    where id = target_escrow_id;

    if resolved_status = 'refunded' then
        update public.bookings set status = 'refunded', payment_status = 'refunded'
        where id = escrow_record.booking_id;
    else
        update public.bookings set status = 'completed', completed_at = now()
        where id = escrow_record.booking_id;
    end if;
end;
$$;

create or replace function public.release_pending_wallet_balance(
    target_payout_id uuid, operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare payout_record record;
begin
    select * into payout_record from public.wallet_payouts
    where id = target_payout_id and status = 'pending' and available_at <= now()
    for update;
    if not found then raise exception 'Due pending payout not found'; end if;
    perform 1 from public.wallets
    where id = payout_record.wallet_id and status = 'active' for update;
    update public.wallets
    set pending_balance = pending_balance - payout_record.amount,
        available_balance = available_balance + payout_record.amount
    where id = payout_record.wallet_id and pending_balance >= payout_record.amount;
    if not found then raise exception 'Pending wallet balance is inconsistent'; end if;
    update public.wallet_payouts set status = 'released', released_at = now()
    where id = target_payout_id;
    insert into public.wallet_transactions
        (wallet_id, booking_id, type, direction, balance_type, amount, currency,
         status, reference, completed_at)
    values
        (payout_record.wallet_id, payout_record.booking_id, 'earning', 'debit',
         'pending', payout_record.amount, payout_record.currency, 'completed',
         operation_reference || ':pending', now()),
        (payout_record.wallet_id, payout_record.booking_id, 'earning', 'credit',
         'available', payout_record.amount, payout_record.currency, 'completed',
         operation_reference || ':available', now());
end;
$$;

create or replace function public.cancel_booking_and_release_funds(
    target_booking_id uuid, operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare active_hold_id uuid;
begin
    select id into active_hold_id
    from public.wallet_holds
    where booking_id = target_booking_id and status = 'active'
    for update;

    if active_hold_id is not null then
        perform public.release_booking_wallet_hold(
            active_hold_id, operation_reference || ':funds'
        );
    end if;
    perform public.cancel_booking_before_pickup_atomic(target_booking_id);
end;
$$;

create or replace function public.expire_booking_wallet_hold(
    target_hold_id uuid, operation_reference text
)
returns void language plpgsql security definer set search_path = ''
as $$
declare hold_record record;
begin
    select * into hold_record from public.wallet_holds
    where id = target_hold_id and status = 'active' and expires_at <= now()
    for update;
    if not found then raise exception 'Expired active wallet hold not found'; end if;
    perform 1 from public.wallets where id = hold_record.wallet_id for update;
    update public.wallets
    set reserved_balance = reserved_balance - hold_record.amount,
        available_balance = available_balance + hold_record.amount
    where id = hold_record.wallet_id and reserved_balance >= hold_record.amount;
    if not found then raise exception 'Reserved wallet balance is inconsistent'; end if;
    update public.wallet_holds set status = 'expired', released_at = now()
    where id = target_hold_id;
    insert into public.wallet_transactions
        (wallet_id, booking_id, type, direction, balance_type, amount,
         currency, status, reference, completed_at)
    values
        (hold_record.wallet_id, hold_record.booking_id, 'release', 'debit', 'reserved',
         hold_record.amount, hold_record.currency, 'completed',
         operation_reference || ':reserved', now()),
        (hold_record.wallet_id, hold_record.booking_id, 'release', 'credit', 'available',
         hold_record.amount, hold_record.currency, 'completed',
         operation_reference || ':available', now());
    perform public.cancel_booking_before_pickup_atomic(hold_record.booking_id);
end;
$$;

create or replace function public.expire_unfunded_booking(
    target_booking_id uuid
)
returns void language plpgsql security definer set search_path = ''
as $$
begin
    perform 1 from public.bookings
    where id = target_booking_id and status = 'pending' and expires_at <= now()
    for update;
    if not found then raise exception 'Expired pending booking not found'; end if;
    if exists (
        select 1 from public.wallet_holds
        where booking_id = target_booking_id and status = 'active'
    ) then
        raise exception 'The booking has an active wallet hold';
    end if;
    perform public.cancel_booking_before_pickup_atomic(target_booking_id);
end;
$$;

create or replace function public.process_due_financial_operations(
    batch_size integer default 100
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
    item record;
    expired_holds integer := 0;
    expired_bookings integer := 0;
    released_payouts integer := 0;
begin
    if batch_size < 1 or batch_size > 1000 then
        raise exception 'Batch size must be between 1 and 1000';
    end if;
    for item in
        select id from public.wallet_holds
        where status = 'active' and expires_at <= now()
        order by expires_at limit batch_size
        for update skip locked
    loop
        perform public.expire_booking_wallet_hold(
            item.id, 'hold-expiry:' || item.id::text
        );
        expired_holds := expired_holds + 1;
    end loop;
    for item in
        select booking.id from public.bookings booking
        where booking.status = 'pending' and booking.expires_at <= now()
          and not exists (
              select 1 from public.wallet_holds hold
              where hold.booking_id = booking.id and hold.status = 'active'
          )
        order by booking.expires_at limit batch_size
        for update of booking skip locked
    loop
        perform public.expire_unfunded_booking(item.id);
        expired_bookings := expired_bookings + 1;
    end loop;
    for item in
        select id from public.wallet_payouts
        where status = 'pending' and available_at <= now()
        order by available_at limit batch_size
        for update skip locked
    loop
        perform public.release_pending_wallet_balance(
            item.id, 'payout-release:' || item.id::text
        );
        released_payouts := released_payouts + 1;
    end loop;
    return jsonb_build_object(
        'expiredHolds', expired_holds,
        'expiredBookings', expired_bookings,
        'releasedPayouts', released_payouts
    );
end;
$$;

create or replace function public.anonymize_user_account(target_user_id uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
    if exists (
        select 1 from public.bookings booking
        join public.listings listing on listing.id = booking.listing_id
        join public.trips trip on trip.id = listing.trip_id
        left join public.shipments shipment on shipment.booking_id = booking.id
        left join public.shipment_recipients recipient on recipient.shipment_id = shipment.id
        where booking.status in ('pending', 'confirmed', 'cancellation_pending_return')
          and target_user_id in (
              booking.buyer_user_id, trip.traveler_user_id, recipient.recipient_user_id
          )
    ) or exists (
        select 1 from public.wallets wallet
        join public.wallet_holds hold on hold.wallet_id = wallet.id
        where wallet.user_id = target_user_id and hold.status = 'active'
    ) or exists (
        select 1 from public.wallets wallet
        join public.escrows escrow
          on wallet.id in (escrow.payer_wallet_id, escrow.beneficiary_wallet_id)
        where wallet.user_id = target_user_id
          and escrow.status in ('funded', 'held', 'disputed')
    ) or exists (
        select 1 from public.wallets wallet
        where wallet.user_id = target_user_id
          and (
              wallet.available_balance > 0
              or wallet.reserved_balance > 0
              or wallet.pending_balance > 0
          )
    ) then
        raise exception 'The account has active operational or financial obligations';
    end if;

    update public.trips
    set status = 'cancelled'
    where traveler_user_id = target_user_id
      and status in ('draft', 'scheduled');

    update public.users
    set phone = null,
        email = null,
        email_verified_at = null,
        first_name = null,
        last_name = null,
        profile_picture_path = null,
        profile_completed_at = null,
        status = 'deleted',
        anonymized_at = now()
    where id = target_user_id and status <> 'deleted';
    if not found then raise exception 'Active user account not found'; end if;
end;
$$;

create or replace function public.reconcile_wallet_balance(target_wallet_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
    wallet_record record;
    ledger_available numeric(18, 2);
    ledger_reserved numeric(18, 2);
    ledger_pending numeric(18, 2);
begin
    select * into wallet_record from public.wallets where id = target_wallet_id;
    if not found then raise exception 'Wallet not found'; end if;
    select
        coalesce(sum(case when balance_type = 'available'
            then case direction when 'credit' then amount else -amount end else 0 end), 0),
        coalesce(sum(case when balance_type = 'reserved'
            then case direction when 'credit' then amount else -amount end else 0 end), 0),
        coalesce(sum(case when balance_type = 'pending'
            then case direction when 'credit' then amount else -amount end else 0 end), 0)
    into ledger_available, ledger_reserved, ledger_pending
    from public.wallet_transactions
    where wallet_id = target_wallet_id and status = 'completed';
    return jsonb_build_object(
        'walletId', target_wallet_id,
        'currency', wallet_record.currency,
        'stored', jsonb_build_object(
            'available', wallet_record.available_balance,
            'reserved', wallet_record.reserved_balance,
            'pending', wallet_record.pending_balance
        ),
        'ledger', jsonb_build_object(
            'available', ledger_available,
            'reserved', ledger_reserved,
            'pending', ledger_pending
        ),
        'matches', wallet_record.available_balance = ledger_available
            and wallet_record.reserved_balance = ledger_reserved
            and wallet_record.pending_balance = ledger_pending
    );
end;
$$;

create or replace function public.update_listing_with_trip(
    target_listing_id uuid,
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
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
    current_listing record;
    trip_record public.trips%rowtype;
    listing_record public.listings%rowtype;
    booking_record record;
    active_reserved_kg numeric(8, 2);
    cancel_reservations boolean := false;
    cancelled_count integer := 0;
begin
    select listing.*, trip.traveler_user_id, trip.type as trip_type,
           trip.departure_location_id, trip.arrival_location_id,
           trip.departure_at, trip.arrival_at, trip.transport_reference,
           trip.status as trip_status
    into current_listing
    from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where listing.id = target_listing_id
    for update of listing, trip;

    if not found then raise exception 'Listing not found'; end if;
    if current_listing.traveler_user_id <> target_traveler_user_id then
        raise exception 'The user does not own this listing';
    end if;
    if current_listing.trip_status not in ('draft', 'scheduled')
       or current_listing.status not in ('draft', 'open', 'closed')
       or (current_listing.status = 'closed'
           and current_listing.closed_reason <> 'capacity_reached') then
        raise exception 'The listing cannot be edited';
    end if;
    if target_accepted_parcel_types is null
       or cardinality(target_accepted_parcel_types) = 0 then
        raise exception 'At least one accepted parcel type is required';
    end if;

    -- Once pickup has occurred, neither commercial nor journey information
    -- can change, even if the shipment later reaches a terminal status.
    if exists (
        select 1
        from public.bookings booking
        left join public.shipments shipment on shipment.booking_id = booking.id
        where booking.listing_id = target_listing_id
          and (
              booking.status = 'cancellation_pending_return'
              or shipment.status not in ('awaiting_drop_off', 'photos_required')
          )
    ) then
        raise exception 'The delivery has started';
    end if;

    select coalesce(sum(booking.reserved_kg), 0)
    into active_reserved_kg
    from public.bookings booking
    where booking.listing_id = target_listing_id
      and booking.status in ('pending', 'confirmed');

    -- A materially different journey invalidates every existing acceptance.
    cancel_reservations := (
        current_listing.trip_type is distinct from target_trip_type
        or current_listing.departure_location_id is distinct from target_departure_location_id
        or current_listing.arrival_location_id is distinct from target_arrival_location_id
        or current_listing.departure_at is distinct from target_departure_at
        or current_listing.arrival_at is distinct from target_arrival_at
        or current_listing.transport_reference is distinct from
            nullif(trim(target_transport_reference), '')
        or target_total_available_kg < active_reserved_kg
    );

    -- Removing a parcel type already used by an active reservation also
    -- invalidates those reservations.
    if not cancel_reservations and exists (
        select 1
        from public.bookings booking
        join public.shipments shipment on shipment.booking_id = booking.id
        join public.parcels parcel on parcel.shipment_id = shipment.id
        where booking.listing_id = target_listing_id
          and booking.status in ('pending', 'confirmed')
          and not (parcel.parcel_type = any(target_accepted_parcel_types))
    ) then
        cancel_reservations := true;
    end if;

    if cancel_reservations then
        for booking_record in
            select booking.id
            from public.bookings booking
            where booking.listing_id = target_listing_id
              and booking.status in ('pending', 'confirmed')
            order by booking.created_at
            for update
        loop
            perform public.cancel_booking_and_release_funds(
                booking_record.id,
                'listing-update:' || target_listing_id || ':' || booking_record.id
            );
            cancelled_count := cancelled_count + 1;
        end loop;
        active_reserved_kg := 0;
    end if;

    update public.trips
    set type = target_trip_type,
        departure_location_id = target_departure_location_id,
        arrival_location_id = target_arrival_location_id,
        departure_at = target_departure_at,
        arrival_at = target_arrival_at,
        transport_reference = nullif(trim(target_transport_reference), '')
    where id = current_listing.trip_id
    returning * into trip_record;

    update public.listings
    set total_available_kg = target_total_available_kg,
        remaining_kg = target_total_available_kg - active_reserved_kg,
        price_per_kg = target_price_per_kg,
        currency = upper(target_currency),
        status = 'open'
    where id = target_listing_id
    returning * into listing_record;

    delete from public.listing_accepted_parcel_types
    where listing_id = target_listing_id;
    insert into public.listing_accepted_parcel_types (listing_id, parcel_type)
    select target_listing_id, parcel_type
    from unnest(target_accepted_parcel_types) parcel_type
    on conflict do nothing;

    return jsonb_build_object(
        'trip', to_jsonb(trip_record),
        'listing', to_jsonb(listing_record) || jsonb_build_object(
            'accepted_parcel_types', to_jsonb(target_accepted_parcel_types)
        ),
        'cancelled_bookings_count', cancelled_count
    );
end;
$$;

create or replace function public.cancel_listing_with_trip(
    target_listing_id uuid,
    target_traveler_user_id uuid
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
    current_listing record;
    trip_record public.trips%rowtype;
    listing_record public.listings%rowtype;
    booking_record record;
    accepted_types public.parcel_type[];
    cancelled_count integer := 0;
begin
    select listing.*, trip.traveler_user_id, trip.status as trip_status
    into current_listing
    from public.listings listing
    join public.trips trip on trip.id = listing.trip_id
    where listing.id = target_listing_id
    for update of listing, trip;

    if not found then raise exception 'Listing not found'; end if;
    if current_listing.traveler_user_id <> target_traveler_user_id then
        raise exception 'The user does not own this listing';
    end if;
    if current_listing.status = 'cancelled' then
        raise exception 'The listing is already cancelled';
    end if;
    if current_listing.status not in ('draft', 'open', 'closed')
       or current_listing.trip_status not in ('draft', 'scheduled')
       or (current_listing.status = 'closed'
           and current_listing.closed_reason <> 'capacity_reached') then
        raise exception 'The listing cannot be edited';
    end if;

    if exists (
        select 1
        from public.bookings booking
        left join public.shipments shipment on shipment.booking_id = booking.id
        where booking.listing_id = target_listing_id
          and (
              booking.status = 'cancellation_pending_return'
              or shipment.status not in ('awaiting_drop_off', 'photos_required')
          )
    ) then
        raise exception 'The delivery has started';
    end if;

    for booking_record in
        select booking.id
        from public.bookings booking
        where booking.listing_id = target_listing_id
          and booking.status in ('pending', 'confirmed')
        order by booking.created_at
        for update
    loop
        perform public.cancel_booking_and_release_funds(
            booking_record.id,
            'listing-cancel:' || target_listing_id || ':' || booking_record.id
        );
        cancelled_count := cancelled_count + 1;
    end loop;

    select coalesce(array_agg(accepted.parcel_type order by accepted.parcel_type),
                    array[]::public.parcel_type[])
    into accepted_types
    from public.listing_accepted_parcel_types accepted
    where accepted.listing_id = target_listing_id;

    update public.listings
    set status = 'cancelled',
        closed_reason = 'manual'
    where id = target_listing_id
    returning * into listing_record;

    update public.trips
    set status = 'cancelled'
    where id = current_listing.trip_id
    returning * into trip_record;

    return jsonb_build_object(
        'trip', to_jsonb(trip_record),
        'listing', to_jsonb(listing_record) || jsonb_build_object(
            'accepted_parcel_types', to_jsonb(accepted_types)
        ),
        'cancelled_bookings_count', cancelled_count
    );
end;
$$;

revoke all on function public.simulate_wallet_top_up(uuid, numeric, text) from public, authenticated;
revoke all on function public.place_booking_wallet_hold(uuid, text) from public, authenticated;
revoke all on function public.release_booking_wallet_hold(uuid, text) from public, authenticated;
revoke all on function public.capture_hold_to_escrow(uuid, text) from public, authenticated;
revoke all on function public.credit_platform_commission(uuid, numeric, text) from public, authenticated;
revoke all on function public.release_escrow_to_pending(uuid, timestamptz, text) from public, authenticated;
revoke all on function public.refund_escrow(uuid, text) from public, authenticated;
revoke all on function public.resolve_disputed_escrow(
    uuid, numeric, numeric, numeric, timestamptz, text
) from public, authenticated;
revoke all on function public.release_pending_wallet_balance(uuid, text) from public, authenticated;
revoke all on function public.cancel_booking_and_release_funds(uuid, text) from public, authenticated;
revoke all on function public.expire_booking_wallet_hold(uuid, text) from public, authenticated;
revoke all on function public.expire_unfunded_booking(uuid) from public, authenticated;
revoke all on function public.process_due_financial_operations(integer) from public, authenticated;
revoke all on function public.anonymize_user_account(uuid) from public, authenticated;
revoke all on function public.reconcile_wallet_balance(uuid) from public, authenticated;
revoke all on function public.update_listing_with_trip(
    uuid, uuid, public.trip_type, uuid, uuid, timestamptz, timestamptz,
    varchar, numeric, numeric, char(3), public.parcel_type[]
) from public, authenticated;
revoke all on function public.cancel_listing_with_trip(uuid, uuid)
from public, authenticated;
grant execute on function public.simulate_wallet_top_up(uuid, numeric, text) to service_role;
grant execute on function public.place_booking_wallet_hold(uuid, text) to service_role;
grant execute on function public.release_booking_wallet_hold(uuid, text) to service_role;
grant execute on function public.capture_hold_to_escrow(uuid, text) to service_role;
grant execute on function public.release_escrow_to_pending(uuid, timestamptz, text) to service_role;
grant execute on function public.refund_escrow(uuid, text) to service_role;
grant execute on function public.resolve_disputed_escrow(
    uuid, numeric, numeric, numeric, timestamptz, text
) to service_role;
grant execute on function public.release_pending_wallet_balance(uuid, text) to service_role;
grant execute on function public.cancel_booking_and_release_funds(uuid, text) to service_role;
grant execute on function public.expire_booking_wallet_hold(uuid, text) to service_role;
grant execute on function public.expire_unfunded_booking(uuid) to service_role;
grant execute on function public.process_due_financial_operations(integer) to service_role;
grant execute on function public.anonymize_user_account(uuid) to service_role;
grant execute on function public.reconcile_wallet_balance(uuid) to service_role;
grant execute on function public.update_listing_with_trip(
    uuid, uuid, public.trip_type, uuid, uuid, timestamptz, timestamptz,
    varchar, numeric, numeric, char(3), public.parcel_type[]
) to service_role;
grant execute on function public.cancel_listing_with_trip(uuid, uuid)
to service_role;

alter table public.wallet_transactions enable row level security;
alter table public.wallet_holds enable row level security;
alter table public.escrows enable row level security;
alter table public.wallet_payouts enable row level security;
alter table public.platform_accounts enable row level security;
alter table public.platform_transactions enable row level security;

create policy wallet_transactions_read_own
on public.wallet_transactions for select to authenticated
using (exists (select 1 from public.wallets wallet where wallet.id = wallet_id
and wallet.user_id = (select auth.uid())));

create policy wallet_holds_read_own
on public.wallet_holds for select to authenticated
using (exists (select 1 from public.wallets wallet where wallet.id = wallet_id
and wallet.user_id = (select auth.uid())));

create policy escrows_read_participants
on public.escrows for select to authenticated
using (
    public.is_booking_participant(booking_id, (select auth.uid()))
    or exists (
        select 1 from public.wallets wallet
        where wallet.id in (payer_wallet_id, beneficiary_wallet_id)
          and wallet.user_id = (select auth.uid())
    )
);

create policy wallet_payouts_read_own
on public.wallet_payouts for select to authenticated
using (exists (
    select 1 from public.wallets wallet
    where wallet.id = wallet_id
      and wallet.user_id = (select auth.uid())
));

commit;
