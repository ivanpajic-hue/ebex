-- =====================================================================
-- eBex · Faza 1 (vertikalni presek) · Supabase / PostgreSQL šema
-- Verzija 1.0 · 9. 11. 2026.
--
-- KAKO SE KORISTI: ceo fajl nalepi u Supabase → SQL Editor → Run.
-- Bezbedno je pokrenuti ponovo (ne briše podatke).
--
-- SANDBOX: BEX API, SMS i KYC su simulirani i jasno označeni.
-- Nijedan simulirani tok nije produkciona integracija.
-- =====================================================================
begin;

create schema if not exists extensions;
create extension if not exists pg_trgm with schema extensions;
create extension if not exists unaccent with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Pomoćne funkcije bez zavisnosti
-- ---------------------------------------------------------------------
create or replace function public.f_norm(t text) returns text
language sql immutable parallel safe set search_path = '' as
$$ select lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(t, ''))) $$;

create or replace function public.f_name(t text) returns text
language sql immutable parallel safe set search_path = '' as
$$ select public.f_norm(regexp_replace(trim(coalesce(t, '')), '\s+', ' ', 'g')) $$;

create or replace function public.trg_touch() returns trigger language plpgsql as
$$ begin new.updated_at := now(); return new; end $$;

create or replace function public.trg_immutable() returns trigger language plpgsql as
$$ begin raise exception 'Zapis u tabeli % se ne sme menjati ni brisati (nepromenljiva evidencija).', tg_table_name; end $$;

-- ---------------------------------------------------------------------
-- 2. Konfiguracija (sve poslovne vrednosti su ovde, ne u kodu)
-- ---------------------------------------------------------------------
create table if not exists public.app_config (
  key text primary key,
  value jsonb not null,
  description text not null default '',
  is_public boolean not null default false,
  locked boolean not null default false,
  decision_status text not null default 'SANDBOX_PRETPOSTAVKA'
    check (decision_status in ('ZAKLJUCANO','SANDBOX_PRETPOSTAVKA','POTVRDJENO')),
  updated_at timestamptz not null default now()
);

insert into public.app_config (key, value, description, is_public, locked, decision_status) values
 ('market_country',            '"RS"',      'Tržište', true, true, 'ZAKLJUCANO'),
 ('currency',                  '"RSD"',     'Valuta', true, true, 'ZAKLJUCANO'),
 ('business_model',            '"C2C"',     'Početni model', true, true, 'ZAKLJUCANO'),
 ('personal_pickup_enabled',   'false',     'Lično preuzimanje', true, true, 'ZAKLJUCANO'),
 ('allowed_delivery_providers','["BEX"]',   'Dozvoljeni dostavljači', true, true, 'ZAKLJUCANO'),
 ('online_payment_enabled',    'false',     'Online/kartično plaćanje', true, true, 'ZAKLJUCANO'),
 ('payment_method',            '"BEX_COD"', 'Način plaćanja: pouzeće preko BEX-a', true, true, 'ZAKLJUCANO'),
 ('external_contact_sharing_enabled','false','Razmena kontakata van platforme', true, true, 'ZAKLJUCANO'),
 ('payout_hold_on_complaint_or_fraud','true','Reklamacija/prevara zaustavlja isplatu', false, true, 'ZAKLJUCANO'),
 ('transaction_fee_enabled',   'false',     'Transakciona provizija (isključena u MVP)', true, true, 'ZAKLJUCANO'),
 ('cars_enabled',              'false',     'Automobili (van prvog obima)', true, true, 'ZAKLJUCANO'),
 ('real_estate_enabled',       'false',     'Nekretnine (van prvog obima)', true, true, 'ZAKLJUCANO'),
 ('b2c_enabled',               'false',     'B2C prodavci', true, true, 'ZAKLJUCANO'),
 ('b2b_enabled',               'false',     'B2B prodavci', true, true, 'ZAKLJUCANO'),
 ('payout_requires_verified_identity','true','Isplata samo uz verifikovan identitet', false, true, 'ZAKLJUCANO'),
 ('sandbox_mode',              'true',      'SANDBOX: SMS kod se prikazuje na ekranu, BEX je simuliran', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('min_age',                   '18',        'Minimalna starost korisnika — čeka pravnu potvrdu', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('policy_versions',           '{"terms":"0.1-nacrt","privacy":"0.1-nacrt"}', 'Važeće verzije uslova i politike privatnosti', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('shipping_payer',            '"buyer"',   'Ko plaća BEX dostavu: buyer ili seller', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('shipping_price_table',      '[{"max_kg":2,"price_rsd":450},{"max_kg":5,"price_rsd":550},{"max_kg":10,"price_rsd":700},{"max_kg":20,"price_rsd":950},{"max_kg":30,"price_rsd":1250}]',
                               'SANDBOX cene dostave po masi — NISU BEX cenovnik', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('max_weight_kg',             '30',        'Maksimalna masa pošiljke (čeka BEX potvrdu)', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('max_side_cm',               '120',       'Maksimalna najduža stranica paketa u cm (čeka BEX potvrdu)', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('max_price_rsd',             '3000000',   'Najviša dozvoljena cena oglasa', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('max_listing_photos',        '8',         'Najviše fotografija po oglasu', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('evidence_value_threshold_rsd','20000',   'Od ove vrednosti obavezan foto dokaz pakovanja', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('evidence_min_photos',       '4',         'Broj obaveznih fotografija pakovanja', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('seller_handover_days',      '3',         'Rok prodavca za predaju pošiljke (dana)', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('payout_delay_days',         '1',         'Isplata prodavcu: broj dana posle naplate pouzeća', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('payout_skip_weekends',      'true',      'Isplata se pomera sa vikenda (čeka BEX pravilo)', false, false, 'SANDBOX_PRETPOSTAVKA'),
 ('payout_non_working_days',   '["2026-11-11","2027-01-01","2027-01-02","2027-01-07","2027-02-15","2027-02-16"]', 'Neradni dani za isplatu (dopuniti po BEX-u)', false, false, 'SANDBOX_PRETPOSTAVKA'),
 ('complaint_window_days',     '7',         'Rok za reklamaciju posle uručenja (dana)', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('complaint_reasons',         '[{"code":"NOT_RECEIVED","label":"Predmet nije primljen iako piše da je uručen"},{"code":"DAMAGED","label":"Predmet je oštećen"},{"code":"WRONG_ITEM","label":"Stigao je pogrešan predmet"},{"code":"MISSING_PARTS","label":"Nedostaju delovi"},{"code":"NOT_AS_DESCRIBED","label":"Stanje bitno odstupa od opisa"},{"code":"COUNTERFEIT","label":"Sumnja na falsifikat ili prevaru"}]',
                               'Dozvoljeni razlozi reklamacije', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('offer_ttl_hours',           '48',        'Važenje formalne ponude (sati)', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('publish_requires_payout_account','true', 'Za objavu oglasa potreban je unet račun za isplatu', true, false, 'SANDBOX_PRETPOSTAVKA'),
 ('admin_mfa_required',        'true',      'Administratori moraju koristiti dvofaktorsku prijavu', false, false, 'POTVRDJENO'),
 ('four_eyes_payout_release',  'false',     'Deblokada isplate zahteva dva različita administratora', false, false, 'SANDBOX_PRETPOSTAVKA'),
 ('contact_keywords',          '["viber","whatsapp","whats app","wa.me","telegram","signal app","instagram","insta","facebook","messenger","gmail","mejl","imejl","e-mail","pozovi","pozovite","zovi","zovite","moj broj","broj telefona","kontakt telefon","nula sest","licno preuzimanje","preuzimanje licno","licno preuzeti","licno predati","licna dostava","uplata na racun","uplatite na","post express","postexpress","aks kurir","city express","d express","dexpress","daily express","kurirska sluzba po izboru"]',
                               'Fraze koje ukazuju na dogovor van platforme', false, false, 'SANDBOX_PRETPOSTAVKA'),
 ('prohibited_keywords',       '["oruzje","pistolj","puska","municija","eksploziv","droga","marihuana","kokain","falsifikat","replika","lekovi na recept","duvan","cigarete","alkohol"]',
                               'Reči koje šalju oglas na ručni pregled', false, false, 'SANDBOX_PRETPOSTAVKA'),
 ('rate_limits',               '{"otp":{"max":3,"window_min":15},"message":{"max":30,"window_min":1},"offer":{"max":10,"window_min":60},"publish":{"max":20,"window_min":1440},"order":{"max":10,"window_min":1440},"complaint":{"max":5,"window_min":1440}}',
                               'Ograničenja broja radnji', false, false, 'SANDBOX_PRETPOSTAVKA')
on conflict (key) do nothing;

create or replace function public.cfg(p_key text) returns jsonb
language sql stable security definer set search_path = public as
$$ select value from public.app_config where key = p_key $$;

create or replace function public.cfg_bool(p_key text) returns boolean
language sql stable security definer set search_path = public as
$$ select coalesce((select (value)::boolean from public.app_config where key = p_key and jsonb_typeof(value) = 'boolean'), false) $$;

create or replace function public.cfg_num(p_key text) returns numeric
language sql stable security definer set search_path = public as
$$ select (value)::numeric from public.app_config where key = p_key and jsonb_typeof(value) = 'number' $$;

-- ---------------------------------------------------------------------
-- 3. Administratori, uloge i ovlašćenja (RBAC po radnjama)
-- ---------------------------------------------------------------------
create table if not exists public.role_permissions (
  role text not null,
  permission text not null,
  primary key (role, permission)
);

insert into public.role_permissions (role, permission)
select r, p from (values
 ('super_admin', array['view_dashboard','view_orders','view_delivery','moderate_listings','view_listings_all','moderate_chat','bex_simulate','place_hold','release_hold','resolve_complaints','view_evidence','view_users','verify_accounts','verify_identity','suspend_users','view_finance','reconcile','manage_config','manage_admins','view_audit','run_jobs','view_risk','view_data_requests']),
 ('support',            array['view_dashboard','view_orders','view_delivery','view_listings_all','view_users','view_data_requests']),
 ('moderator',          array['view_dashboard','moderate_listings','view_listings_all','moderate_chat']),
 ('dispute_admin',      array['view_dashboard','view_orders','view_delivery','moderate_chat','place_hold','release_hold','resolve_complaints','view_evidence']),
 ('dispute_supervisor', array['view_dashboard','view_orders','view_delivery','moderate_chat','place_hold','release_hold','resolve_complaints','view_evidence']),
 ('finance',            array['view_dashboard','view_orders','place_hold','release_hold','view_users','verify_accounts','view_finance','reconcile','run_jobs']),
 ('risk',               array['view_dashboard','view_orders','view_listings_all','moderate_chat','place_hold','view_evidence','view_users','verify_accounts','verify_identity','suspend_users','view_risk']),
 ('bex_support',        array['view_dashboard','view_orders','view_delivery','bex_simulate','run_jobs']),
 ('marketing',          array['view_dashboard','view_listings_all']),
 ('analyst',            array['view_dashboard']),
 ('legal',              array['view_dashboard','view_orders','view_listings_all','view_users','view_finance','view_audit','view_data_requests']),
 ('auditor',            array['view_dashboard','view_orders','view_users','view_finance','view_audit','view_risk'])
) as t(r, perms), unnest(perms) as p
on conflict do nothing;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('super_admin','support','moderator','dispute_admin','dispute_supervisor','finance','risk','bex_support','marketing','analyst','legal','auditor')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create or replace function public.admin_role() returns text
language sql stable security definer set search_path = public as
$$ select a.role from public.admin_users a where a.user_id = auth.uid() and a.active $$;

create or replace function public.admin_mfa_ok() returns boolean
language sql stable security definer set search_path = public as
$$ select (not public.cfg_bool('admin_mfa_required')) or coalesce(auth.jwt() ->> 'aal', '') = 'aal2' $$;

create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as
$$ select exists (select 1 from public.admin_users a join public.role_permissions rp on rp.role = a.role
                  where a.user_id = auth.uid() and a.active and rp.permission = p)
          and public.admin_mfa_ok() $$;

create or replace function public.require_perm(p text) returns void
language plpgsql stable security definer set search_path = public as
$$ begin
  if not public.has_perm(p) then
    raise exception 'Nemate ovlašćenje za ovu radnju ili niste potvrdili dvofaktorsku prijavu (%).', p using errcode = '42501';
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 4. Revizijski trag (nepromenljiv)
-- ---------------------------------------------------------------------
create table if not exists public.audit_events (
  id bigserial primary key,
  at timestamptz not null default now(),
  actor_id uuid,
  actor_role text,
  action text not null,
  entity text not null,
  entity_id text,
  old_data jsonb,
  new_data jsonb,
  reason text
);
create index if not exists audit_entity_idx on public.audit_events (entity, entity_id);
create index if not exists audit_actor_idx on public.audit_events (actor_id, at desc);
drop trigger if exists audit_immutable on public.audit_events;
create trigger audit_immutable before update or delete on public.audit_events for each row execute function public.trg_immutable();

create or replace function public.trg_audit() returns trigger
language plpgsql security definer set search_path = public as
$$ declare v_row jsonb := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
begin
  insert into public.audit_events (actor_id, actor_role, action, entity, entity_id, old_data, new_data, reason)
  values (auth.uid(),
          coalesce(public.admin_role(), case when auth.uid() is null then 'system' else 'user' end),
          lower(tg_op), tg_table_name,
          coalesce(v_row ->> 'id', v_row ->> 'key', v_row ->> 'user_id'),
          case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
          case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end,
          nullif(current_setting('ebex.reason', true), ''));
  return coalesce(new, old);
end $$;

drop trigger if exists audit_app_config on public.app_config;
create trigger audit_app_config after insert or update or delete on public.app_config for each row execute function public.trg_audit();
drop trigger if exists audit_admin_users on public.admin_users;
create trigger audit_admin_users after insert or update or delete on public.admin_users for each row execute function public.trg_audit();
drop trigger if exists touch_app_config on public.app_config;
create trigger touch_app_config before update on public.app_config for each row execute function public.trg_touch();

-- ---------------------------------------------------------------------
-- 5. Korisnici: javni profil i privatni podaci
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Korisnik',
  city text,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','SUSPENDED')),
  completed_sales integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.profile_private (
  id uuid primary key references public.profiles(id) on delete cascade,
  full_name text,
  phone text,
  phone_verified_at timestamptz,
  identity_status text not null default 'NONE' check (identity_status in ('NONE','PENDING','VERIFIED','REJECTED')),
  terms_version text,
  terms_accepted_at timestamptz,
  privacy_version text,
  marketing_consent boolean not null default false,
  delivery_name text, delivery_phone text, delivery_street text, delivery_city text, delivery_postal text,
  pickup_street text, pickup_city text, pickup_postal text,
  updated_at timestamptz not null default now()
);
create unique index if not exists profile_private_phone_verified_uq on public.profile_private (phone) where phone_verified_at is not null;
drop trigger if exists touch_profile_private on public.profile_private;
create trigger touch_profile_private before update on public.profile_private for each row execute function public.trg_touch();

create table if not exists public.consents (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  doc_type text not null,
  doc_version text not null,
  accepted boolean not null,
  at timestamptz not null default now()
);
drop trigger if exists consents_immutable on public.consents;
create trigger consents_immutable before update on public.consents for each row execute function public.trg_immutable();

create table if not exists public.phone_otps (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  phone text not null,
  code_hash text not null,
  salt text not null,
  attempts integer not null default 0,
  expires_at timestamptz not null,
  consumed_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.payout_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  account_number text not null,
  holder_name text not null,
  status text not null default 'PENDING' check (status in ('PENDING','REVIEW','VERIFIED','REJECTED')),
  flags text[] not null default '{}',
  is_current boolean not null default true,
  review_note text,
  verified_by uuid,
  verified_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists payout_accounts_user_idx on public.payout_accounts (user_id, is_current);
drop trigger if exists audit_payout_accounts on public.payout_accounts;
create trigger audit_payout_accounts after insert or update or delete on public.payout_accounts for each row execute function public.trg_audit();

create table if not exists public.rate_events (
  id bigserial primary key,
  user_id uuid not null,
  kind text not null,
  at timestamptz not null default now()
);
create index if not exists rate_events_idx on public.rate_events (user_id, kind, at desc);

create table if not exists public.risk_signals (
  id bigserial primary key,
  user_id uuid,
  kind text not null,
  ref_type text,
  ref_id text,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists risk_signals_user_idx on public.risk_signals (user_id, created_at desc);

create table if not exists public.notifications (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  body text,
  link text,
  read_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists notifications_user_idx on public.notifications (user_id, created_at desc);

create table if not exists public.data_requests (
  id bigserial primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('EXPORT','CORRECTION','DELETE')),
  note text,
  status text not null default 'OPEN' check (status in ('OPEN','DONE','REJECTED')),
  created_at timestamptz not null default now()
);

-- Novi korisnik iz Supabase Auth → profil
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as
$$ declare v_name text := left(trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')), 40);
begin
  if length(v_name) < 2 or v_name ~ '[0-9]{5,}' or v_name ~ '@' then v_name := 'Korisnik'; end if;
  insert into public.profiles (id, display_name) values (new.id, v_name) on conflict (id) do nothing;
  insert into public.profile_private (id) values (new.id) on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created_ebex on auth.users;
create trigger on_auth_user_created_ebex after insert on auth.users for each row execute function public.handle_new_user();

insert into public.profiles (id) select id from auth.users on conflict (id) do nothing;
insert into public.profile_private (id) select id from auth.users on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 6. Kategorije i oglasi
-- ---------------------------------------------------------------------
create table if not exists public.categories (
  id text primary key,
  name text not null,
  parent_id text references public.categories(id),
  sort integer not null default 100,
  is_active boolean not null default true,
  requires_review boolean not null default false,
  feature_flag text,
  blocked_reason text
);

insert into public.categories (id, name, sort, is_active, requires_review, feature_flag, blocked_reason) values
 ('mobilni',        'Mobilni telefoni',          10, true,  false, null, null),
 ('racunari',       'Računari i oprema',         20, true,  false, null, null),
 ('elektronika',    'TV, audio i foto',          30, true,  false, null, null),
 ('aparati',        'Kućni aparati',             40, true,  false, null, null),
 ('dom',            'Dom i nameštaj',            50, true,  false, null, null),
 ('odeca',          'Odeća i obuća',             60, true,  false, null, null),
 ('nakit',          'Satovi i nakit',            65, true,  true,  null, null),
 ('deca',           'Za decu i bebe',            70, true,  false, null, null),
 ('sport',          'Sport i rekreacija',        80, true,  false, null, null),
 ('alati',          'Alati i bašta',             90, true,  false, null, null),
 ('auto-delovi',    'Auto delovi i oprema',     100, true,  false, null, null),
 ('knjige',         'Knjige i muzika',          110, true,  false, null, null),
 ('igre',           'Video igre i konzole',     120, true,  false, null, null),
 ('kolekcionarstvo','Kolekcionarstvo',          130, true,  true,  null, null),
 ('lepota',         'Lepota i nega',            140, true,  false, null, null),
 ('ostalo',         'Ostalo',                   900, true,  true,  null, null),
 ('automobili',     'Automobili',               990, false, true, 'cars_enabled',        'Automobili nisu u prvom obimu platforme.'),
 ('nekretnine',     'Nekretnine',               991, false, true, 'real_estate_enabled', 'Nekretnine nisu u prvom obimu platforme.')
on conflict (id) do nothing;

create table if not exists public.listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.profiles(id) on delete cascade,
  category_id text not null references public.categories(id),
  title text not null,
  description text not null default '',
  condition text not null check (condition in ('NOVO','KAO_NOVO','POLOVNO','ZA_DELOVE')),
  price_para bigint not null check (price_para > 0),
  price_negotiable boolean not null default false,
  sale_mode text not null check (sale_mode in ('BUY','CONTACT')),
  city text not null,
  weight_g integer not null check (weight_g > 0),
  length_cm integer not null check (length_cm > 0),
  width_cm integer not null check (width_cm > 0),
  height_cm integer not null check (height_cm > 0),
  declared_value_para bigint not null check (declared_value_para > 0),
  quantity integer not null default 1 check (quantity = 1),
  status text not null default 'DRAFT' check (status in ('DRAFT','PENDING_REVIEW','ACTIVE','RESERVED','SOLD','PAUSED','REJECTED','REMOVED')),
  moderation_note text,
  rights_confirmed_at timestamptz,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  search_doc text generated always as (public.f_norm(title || ' ' || description)) stored
);
create index if not exists listings_status_pub_idx on public.listings (status, published_at desc);
create index if not exists listings_seller_idx on public.listings (seller_id, status);
create index if not exists listings_category_idx on public.listings (category_id, status);
create index if not exists listings_search_trgm on public.listings using gin (search_doc extensions.gin_trgm_ops);
drop trigger if exists touch_listings on public.listings;
create trigger touch_listings before update on public.listings for each row execute function public.trg_touch();
drop trigger if exists audit_listings_status on public.listings;
create trigger audit_listings_status after update on public.listings for each row
  when (old.status is distinct from new.status) execute function public.trg_audit();

-- Zaštita na nivou baze: zabranjene kategorije (automobili, nekretnine)
create or replace function public.trg_listing_category_guard() returns trigger
language plpgsql security definer set search_path = public as
$$ declare v_cat public.categories;
begin
  select * into v_cat from public.categories where id = new.category_id;
  if not v_cat.is_active or (v_cat.feature_flag is not null and not public.cfg_bool(v_cat.feature_flag)) then
    raise exception '%', coalesce(v_cat.blocked_reason, 'Ova kategorija trenutno nije dostupna.');
  end if;
  return new;
end $$;
drop trigger if exists listing_category_guard on public.listings;
create trigger listing_category_guard before insert or update of category_id on public.listings
  for each row execute function public.trg_listing_category_guard();

create table if not exists public.listing_media (
  id bigserial primary key,
  listing_id uuid not null references public.listings(id) on delete cascade,
  path text not null,
  sort integer not null default 0
);
create index if not exists listing_media_listing_idx on public.listing_media (listing_id, sort);

create table if not exists public.listing_moderation (
  id bigserial primary key,
  listing_id uuid not null references public.listings(id) on delete cascade,
  decision text not null,
  reasons text[] not null default '{}',
  auto boolean not null default true,
  admin_id uuid,
  note text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7. Razgovori, poruke i ponude
-- ---------------------------------------------------------------------
create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings(id) on delete cascade,
  buyer_id uuid not null references public.profiles(id) on delete cascade,
  seller_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  unique (listing_id, buyer_id)
);
create index if not exists conversations_buyer_idx on public.conversations (buyer_id, last_message_at desc);
create index if not exists conversations_seller_idx on public.conversations (seller_id, last_message_at desc);

create table if not exists public.offers (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  listing_id uuid not null references public.listings(id) on delete cascade,
  from_user uuid not null references public.profiles(id),
  to_user uuid not null references public.profiles(id),
  price_para bigint not null check (price_para > 0),
  status text not null default 'PENDING' check (status in ('PENDING','ACCEPTED','REJECTED','EXPIRED','WITHDRAWN')),
  expires_at timestamptz not null,
  order_id uuid,
  created_at timestamptz not null default now(),
  responded_at timestamptz
);

create table if not exists public.messages (
  id bigserial primary key,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid references public.profiles(id),
  kind text not null default 'TEXT' check (kind in ('TEXT','SYSTEM','OFFER')),
  body text not null,
  offer_id uuid references public.offers(id),
  blocked boolean not null default false,
  blocked_reason text,
  created_at timestamptz not null default now()
);
create index if not exists messages_conv_idx on public.messages (conversation_id, id);

-- ---------------------------------------------------------------------
-- 8. Narudžbine, dostava, BEX događaji (novac i logistika su odvojeni)
-- ---------------------------------------------------------------------
create sequence if not exists public.order_no_seq;
create sequence if not exists public.tracking_seq;

create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  order_no text not null unique,
  listing_id uuid not null references public.listings(id),
  buyer_id uuid not null references public.profiles(id),
  seller_id uuid not null references public.profiles(id),
  offer_id uuid references public.offers(id),
  source text not null check (source in ('BUY','OFFER')),
  item_price_para bigint not null check (item_price_para > 0),
  shipping_para bigint not null check (shipping_para >= 0),
  shipping_payer text not null check (shipping_payer in ('buyer','seller')),
  cod_amount_para bigint not null check (cod_amount_para > 0),
  seller_net_para bigint not null,
  status text not null default 'AWAITING_SHIPMENT' check (status in
    ('AWAITING_SHIPMENT','IN_TRANSIT','DELIVERED','COMPLETED','CANCELLED','SHIPMENT_EXPIRED','COD_COLLECTION_FAILED','DISPUTED','RETURN_REQUIRED','MANUAL_REVIEW')),
  cod_status text not null default 'PENDING' check (cod_status in ('PENDING','COLLECTED','FAILED','CANCELLED')),
  payout_status text not null default 'NOT_DUE' check (payout_status in ('NOT_DUE','REMITTANCE_PENDING','PAYOUT_HOLD','PAID','PAYOUT_FAILED')),
  evidence_required boolean not null default false,
  handover_deadline timestamptz not null,
  buyer_city text,
  listing_snapshot jsonb not null,
  delivered_at timestamptz,
  cod_collected_at timestamptz,
  expected_payout_date date,
  paid_out_at timestamptz,
  payout_ref text,
  cancel_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (cod_amount_para = seller_net_para + shipping_para)
);
create unique index if not exists orders_one_active_per_listing on public.orders (listing_id)
  where status not in ('CANCELLED','SHIPMENT_EXPIRED','COD_COLLECTION_FAILED');
create index if not exists orders_buyer_idx on public.orders (buyer_id, created_at desc);
create index if not exists orders_seller_idx on public.orders (seller_id, created_at desc);
create index if not exists orders_payout_idx on public.orders (payout_status, expected_payout_date);
drop trigger if exists touch_orders on public.orders;
create trigger touch_orders before update on public.orders for each row execute function public.trg_touch();
drop trigger if exists audit_orders on public.orders;
create trigger audit_orders after insert or update on public.orders for each row execute function public.trg_audit();

create table if not exists public.order_delivery (
  order_id uuid primary key references public.orders(id) on delete cascade,
  recipient_name text not null,
  recipient_phone text not null,
  street text not null,
  city text not null,
  postal_code text not null,
  note text
);

create table if not exists public.shipments (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  direction text not null default 'OUTBOUND' check (direction in ('OUTBOUND','RETURN')),
  tracking_no text not null unique,
  status text not null default 'CREATED' check (status in ('CREATED','PICKED_UP','IN_TRANSIT','OUT_FOR_DELIVERY','DELIVERED','RETURNING','RETURNED','CANCELLED')),
  status_rank integer not null default 0,
  is_sandbox boolean not null default true,
  created_at timestamptz not null default now(),
  last_event_at timestamptz,
  unique (order_id, direction)
);

create table if not exists public.bex_events (
  id bigserial primary key,
  external_event_id text not null unique,
  tracking_no text,
  order_id uuid,
  event_type text not null,
  occurred_at timestamptz not null,
  payload jsonb not null default '{}'::jsonb,
  source text not null default 'SANDBOX' check (source in ('SANDBOX','BEX')),
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  result text
);
create index if not exists bex_events_order_idx on public.bex_events (order_id, occurred_at);

create table if not exists public.outbox (
  id bigserial primary key,
  topic text not null,
  idempotency_key text not null unique,
  payload jsonb not null,
  status text not null default 'PENDING' check (status in ('PENDING','SENT','FAILED','SANDBOX_DONE')),
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  processed_at timestamptz
);

create table if not exists public.packing_evidence (
  id bigserial primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  uploader_id uuid not null references public.profiles(id),
  path text not null unique,
  sha256 text not null,
  mime text not null,
  size_bytes bigint not null,
  created_at timestamptz not null default now()
);
drop trigger if exists evidence_immutable on public.packing_evidence;
create trigger evidence_immutable before update on public.packing_evidence for each row execute function public.trg_immutable();

create table if not exists public.complaints (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  buyer_id uuid not null references public.profiles(id),
  reason text not null,
  description text not null,
  status text not null default 'OPEN' check (status in ('OPEN','UNDER_REVIEW','RESOLVED_SELLER','RESOLVED_BUYER','CLOSED')),
  post_payout boolean not null default false,
  resolution text,
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists complaints_one_open on public.complaints (order_id) where status in ('OPEN','UNDER_REVIEW');
drop trigger if exists audit_complaints on public.complaints;
create trigger audit_complaints after insert or update on public.complaints for each row execute function public.trg_audit();

create table if not exists public.payout_holds (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.orders(id),
  complaint_id uuid references public.complaints(id),
  kind text not null check (kind in ('COMPLAINT','FRAUD_SUSPICION','ACCOUNT_CHECK')),
  reason text not null,
  status text not null default 'ACTIVE' check (status in ('ACTIVE','RELEASE_REQUESTED','RELEASED','CONVERTED_REFUND')),
  bex_hold_requested_at timestamptz,
  bex_hold_confirmed_at timestamptz,
  release_requested_by uuid,
  release_requested_at timestamptz,
  released_by uuid,
  released_at timestamptz,
  release_reason text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create unique index if not exists payout_holds_one_active on public.payout_holds (order_id) where status in ('ACTIVE','RELEASE_REQUESTED');
drop trigger if exists audit_payout_holds on public.payout_holds;
create trigger audit_payout_holds after insert or update on public.payout_holds for each row execute function public.trg_audit();

-- Dvostavna evidencija (memo knjiga: eBex ne drži novac, samo prati tok BEX novca)
create table if not exists public.ledger_entries (
  id bigserial primary key,
  entry_group uuid not null,
  idempotency_key text not null unique,
  order_id uuid references public.orders(id),
  account text not null check (account in ('BEX_COD_RECEIVABLE','SELLER_PAYABLE','BEX_SHIPPING_FEE')),
  amount_para bigint not null,
  currency text not null default 'RSD',
  reason text not null,
  external_ref text,
  created_at timestamptz not null default now(),
  created_by uuid
);
create index if not exists ledger_order_idx on public.ledger_entries (order_id);
drop trigger if exists ledger_immutable on public.ledger_entries;
create trigger ledger_immutable before update or delete on public.ledger_entries for each row execute function public.trg_immutable();
drop trigger if exists bex_events_no_delete on public.bex_events;
create trigger bex_events_no_delete before delete on public.bex_events for each row execute function public.trg_immutable();

create table if not exists public.reconciliation_cases (
  id bigserial primary key,
  order_id uuid,
  kind text not null,
  details jsonb not null default '{}'::jsonb,
  status text not null default 'OPEN' check (status in ('OPEN','RESOLVED')),
  note text,
  resolved_by uuid,
  resolved_at timestamptz,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 9. Interne pomoćne funkcije
-- ---------------------------------------------------------------------
create or replace function public._notify(p_user uuid, p_title text, p_body text, p_link text) returns void
language sql security definer set search_path = public as
$$ insert into public.notifications (user_id, title, body, link) values (p_user, p_title, p_body, p_link) $$;

create or replace function public._risk(p_user uuid, p_kind text, p_ref_type text, p_ref_id text, p_details jsonb) returns void
language sql security definer set search_path = public as
$$ insert into public.risk_signals (user_id, kind, ref_type, ref_id, details) values (p_user, p_kind, p_ref_type, p_ref_id, coalesce(p_details, '{}'::jsonb)) $$;

create or replace function public._recon(p_order uuid, p_kind text, p_details jsonb) returns void
language sql security definer set search_path = public as
$$ insert into public.reconciliation_cases (order_id, kind, details) values (p_order, p_kind, coalesce(p_details, '{}'::jsonb)) $$;

create or replace function public._rate(p_kind text) returns void
language plpgsql security definer set search_path = public as
$$ declare v_lim jsonb := public.cfg('rate_limits') -> p_kind; v_n integer;
begin
  if v_lim is null or auth.uid() is null then return; end if;
  select count(*) into v_n from public.rate_events
   where user_id = auth.uid() and kind = p_kind and at > now() - make_interval(mins => (v_lim ->> 'window_min')::int);
  if v_n >= (v_lim ->> 'max')::int then
    raise exception 'Previše pokušaja u kratkom roku. Sačekaj malo pa pokušaj ponovo.';
  end if;
  insert into public.rate_events (user_id, kind) values (auth.uid(), p_kind);
end $$;

create or replace function public._uid() returns uuid
language plpgsql stable security definer set search_path = public as
$$ begin
  if auth.uid() is null then raise exception 'Prijavi se da bi nastavio.' using errcode = '42501'; end if;
  if exists (select 1 from public.profiles where id = auth.uid() and status = 'SUSPENDED') then
    raise exception 'Nalog je privremeno suspendovan. Obrati se podršci.' using errcode = '42501';
  end if;
  return auth.uid();
end $$;

create or replace function public._set_reason(p_reason text) returns void
language sql as $$ select set_config('ebex.reason', coalesce(p_reason, ''), true) $$;

create or replace function public.normalize_phone(p text) returns text
language plpgsql immutable as
$$ declare d text := regexp_replace(coalesce(p, ''), '[^0-9+]', '', 'g');
begin
  if d like '+381%' then d := substr(d, 2);
  elsif d like '00381%' then d := substr(d, 3);
  elsif d like '0%' then d := '381' || substr(d, 2);
  elsif d ~ '^6[0-9]{7,8}$' then d := '381' || d;
  end if;
  if d ~ '^3816[0-9]{7,8}$' then return '+' || d; end if;
  return null;
end $$;

create or replace function public.mask_phone(p text) returns text
language sql immutable as $$ select case when p is null then null else left(p, 6) || '•••' || right(p, 2) end $$;

-- Prepoznavanje kontakt podataka i pokušaja dogovora van platforme
create or replace function public.detect_contact(p text) returns text[]
language plpgsql stable security definer set search_path = public as
$$ declare
  t text := public.f_norm(p);
  hits text[] := '{}';
  kw text;
begin
  if t ~ '((\+|00)\s*381|(^|[^0-9])0)[\s\-\./()]*[1-9]([\s\-\./()]*[0-9]){6,10}' then hits := hits || 'telefon'::text; end if;
  if 'telefon' <> all(hits) and t ~ '(^|[^0-9])6[0-9]([\s\-\./]*[0-9]){6,8}($|[^0-9])' then hits := hits || 'telefon'::text; end if;
  if t ~ '[a-z0-9._%+-]+\s*(@|\(at\)|\[at\])\s*[a-z0-9-]+\.[a-z]{2,}' then hits := hits || 'email'::text; end if;
  if t ~ '(https?://|www\.)' or t ~ '[a-z0-9-]{2,}\.(rs|com|net|org|me|info|io|co|shop|store|link|ly)(\M|/)' then hits := hits || 'link'::text; end if;
  for kw in select jsonb_array_elements_text(coalesce(public.cfg('contact_keywords'), '[]'::jsonb)) loop
    if t ~ ('(^|[^a-z0-9])' || regexp_replace(public.f_norm(kw), '([.+*?()\[\]{}|^$\\])', '\\\1', 'g') || '($|[^a-z0-9])') then
      hits := hits || ('fraza: ' || kw);
    end if;
  end loop;
  return hits;
end $$;

create or replace function public.shipping_quote_para(p_weight_g integer) returns bigint
language sql stable security definer set search_path = public as
$$ select ((e ->> 'price_rsd')::numeric * 100)::bigint
     from jsonb_array_elements(coalesce(public.cfg('shipping_price_table'), '[]'::jsonb)) e
    where p_weight_g <= (e ->> 'max_kg')::numeric * 1000
    order by (e ->> 'max_kg')::numeric
    limit 1 $$;

create or replace function public._next_payout_date(p_ts timestamptz) returns date
language plpgsql stable security definer set search_path = public as
$$ declare
  d date := (p_ts at time zone 'Europe/Belgrade')::date + coalesce(public.cfg_num('payout_delay_days'), 1)::int;
  off jsonb := coalesce(public.cfg('payout_non_working_days'), '[]'::jsonb);
  guard integer := 0;
begin
  loop
    exit when guard > 20;
    if (public.cfg_bool('payout_skip_weekends') and extract(isodow from d) in (6, 7)) or off ? d::text then
      d := d + 1; guard := guard + 1;
    else
      exit;
    end if;
  end loop;
  return d;
end $$;

create or replace function public.normalize_account(p text) returns text
language plpgsql immutable as
$$ declare s text := regexp_replace(coalesce(p, ''), '\s', '', 'g'); parts text[];
begin
  if s ~ '^[0-9]{3}-[0-9]{1,13}-[0-9]{2}$' then
    parts := string_to_array(s, '-');
    s := parts[1] || lpad(parts[2], 13, '0') || parts[3];
  end if;
  s := regexp_replace(s, '-', '', 'g');
  if s !~ '^[0-9]{18}$' then return null; end if;
  if (s::numeric % 97) <> 1 then return null; end if;
  return substr(s, 1, 3) || '-' || substr(s, 4, 13) || '-' || substr(s, 17, 2);
end $$;

create or replace function public._ledger(p_order uuid, p_key text, p_reason text, p_ref text, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as
$$ declare g uuid := gen_random_uuid(); s bigint; l jsonb; i integer := 0;
begin
  select coalesce(sum((x ->> 'amount')::bigint), 0) into s from jsonb_array_elements(p_lines) x;
  if s <> 0 then raise exception 'Knjiženje nije uravnoteženo (%).', s; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    i := i + 1;
    insert into public.ledger_entries (entry_group, idempotency_key, order_id, account, amount_para, reason, external_ref, created_by)
    values (g, p_key || ':' || i, p_order, l ->> 'account', (l ->> 'amount')::bigint, p_reason, p_ref, auth.uid())
    on conflict (idempotency_key) do nothing;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 10. Korisničke radnje: profil, saglasnosti, telefon, račun za isplatu
-- ---------------------------------------------------------------------
create or replace function public.accept_terms(p_terms_version text, p_privacy_version text, p_age_confirmed boolean, p_marketing boolean)
returns jsonb language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); v jsonb := public.cfg('policy_versions');
begin
  if p_terms_version is distinct from v ->> 'terms' or p_privacy_version is distinct from v ->> 'privacy' then
    raise exception 'Uslovi su u međuvremenu promenjeni. Osveži stranicu i pročitaj novu verziju.';
  end if;
  if not coalesce(p_age_confirmed, false) then
    raise exception 'Platformu mogu koristiti samo punoletna lica (% i više godina).', public.cfg_num('min_age');
  end if;
  insert into public.consents (user_id, doc_type, doc_version, accepted) values
    (v_uid, 'terms', p_terms_version, true), (v_uid, 'privacy', p_privacy_version, true),
    (v_uid, 'age_confirmation', public.cfg_num('min_age')::text, true),
    (v_uid, 'marketing', 'v1', coalesce(p_marketing, false));
  update public.profile_private set terms_version = p_terms_version, terms_accepted_at = now(),
         privacy_version = p_privacy_version, marketing_consent = coalesce(p_marketing, false)
   where id = v_uid;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.update_profile(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); v_priv public.profile_private; v_dn text; v_phone text;
begin
  select * into v_priv from public.profile_private where id = v_uid;
  if p ? 'display_name' then
    v_dn := trim(p ->> 'display_name');
    if length(v_dn) < 2 or length(v_dn) > 40 then raise exception 'Prikazano ime mora imati od 2 do 40 znakova.'; end if;
    if array_length(public.detect_contact(v_dn), 1) > 0 then raise exception 'Prikazano ime ne sme sadržati kontakt podatke.'; end if;
    update public.profiles set display_name = v_dn where id = v_uid;
  end if;
  if p ? 'city' then update public.profiles set city = nullif(trim(p ->> 'city'), '') where id = v_uid; end if;
  if p ? 'full_name' and coalesce(trim(p ->> 'full_name'), '') is distinct from coalesce(v_priv.full_name, '') then
    if v_priv.identity_status = 'VERIFIED' then
      raise exception 'Ime i prezime je verifikovano. Za izmenu se obrati podršci.';
    end if;
    update public.profile_private set full_name = nullif(trim(p ->> 'full_name'), '') where id = v_uid;
  end if;
  if p ? 'delivery' then
    v_phone := public.normalize_phone(p -> 'delivery' ->> 'phone');
    if v_phone is null then raise exception 'Telefon primaoca nije ispravan (mobilni broj u Srbiji).'; end if;
    if coalesce(p -> 'delivery' ->> 'postal', '') !~ '^[0-9]{5}$' then raise exception 'Poštanski broj mora imati 5 cifara.'; end if;
    update public.profile_private set
      delivery_name = nullif(trim(p -> 'delivery' ->> 'name'), ''), delivery_phone = v_phone,
      delivery_street = nullif(trim(p -> 'delivery' ->> 'street'), ''), delivery_city = nullif(trim(p -> 'delivery' ->> 'city'), ''),
      delivery_postal = p -> 'delivery' ->> 'postal'
     where id = v_uid;
  end if;
  if p ? 'pickup' then
    if coalesce(p -> 'pickup' ->> 'postal', '') !~ '^[0-9]{5}$' then raise exception 'Poštanski broj mora imati 5 cifara.'; end if;
    update public.profile_private set
      pickup_street = nullif(trim(p -> 'pickup' ->> 'street'), ''), pickup_city = nullif(trim(p -> 'pickup' ->> 'city'), ''),
      pickup_postal = p -> 'pickup' ->> 'postal'
     where id = v_uid;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.request_phone_otp(p_phone text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); v_phone text := public.normalize_phone(p_phone); v_code text; v_salt text;
begin
  if v_phone is null then return jsonb_build_object('ok', false, 'error', 'Unesi ispravan broj mobilnog telefona, npr. 064 123 4567.'); end if;
  if exists (select 1 from public.profile_private where phone = v_phone and phone_verified_at is not null and id <> v_uid) then
    perform public._risk(v_uid, 'PHONE_REUSE_ATTEMPT', 'user', v_uid::text, jsonb_build_object('phone', public.mask_phone(v_phone)));
    return jsonb_build_object('ok', false, 'error', 'Ovaj broj je već povezan sa drugim nalogom.');
  end if;
  perform public._rate('otp');
  if not public.cfg_bool('sandbox_mode') then
    raise exception 'SMS servis još nije povezan. Produkcija zahteva SMS provajdera (videti Registar odluka).';
  end if;
  update public.phone_otps set consumed_at = now() where user_id = v_uid and consumed_at is null;
  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(3), 'hex'))::bit(24)::int) % 1000000)::text, 6, '0');
  v_salt := encode(extensions.gen_random_bytes(8), 'hex');
  insert into public.phone_otps (user_id, phone, code_hash, salt, expires_at)
  values (v_uid, v_phone, encode(sha256(convert_to(v_salt || v_code, 'UTF8')), 'hex'), v_salt, now() + interval '10 minutes');
  return jsonb_build_object('ok', true, 'phone', public.mask_phone(v_phone), 'sandbox_code', v_code);
end $$;

create or replace function public.verify_phone_otp(p_code text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); v_otp public.phone_otps;
begin
  select * into v_otp from public.phone_otps
   where user_id = v_uid and consumed_at is null and expires_at > now()
   order by id desc limit 1 for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'Kod je istekao. Zatraži novi kod.'); end if;
  if v_otp.attempts >= 5 then
    update public.phone_otps set consumed_at = now() where id = v_otp.id;
    perform public._risk(v_uid, 'OTP_TOO_MANY_ATTEMPTS', 'user', v_uid::text, '{}'::jsonb);
    return jsonb_build_object('ok', false, 'error', 'Previše pogrešnih pokušaja. Zatraži novi kod.');
  end if;
  if encode(sha256(convert_to(v_otp.salt || coalesce(trim(p_code), ''), 'UTF8')), 'hex') <> v_otp.code_hash then
    update public.phone_otps set attempts = attempts + 1 where id = v_otp.id;
    return jsonb_build_object('ok', false, 'error', 'Pogrešan kod. Preostalo pokušaja: ' || (4 - v_otp.attempts));
  end if;
  update public.phone_otps set consumed_at = now() where id = v_otp.id;
  update public.profile_private set phone = v_otp.phone, phone_verified_at = now() where id = v_uid;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.add_payout_account(p_account text, p_holder text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); v_acc text := public.normalize_account(p_account);
        v_priv public.profile_private; v_status text := 'PENDING'; v_flags text[] := '{}'; v_id uuid;
begin
  if v_acc is null then raise exception 'Broj računa nije ispravan. Unesi 18 cifara u obliku 160-0000000000000-00.'; end if;
  select * into v_priv from public.profile_private where id = v_uid;
  if coalesce(v_priv.full_name, '') = '' then raise exception 'Prvo unesi ime i prezime u profilu.'; end if;
  if public.f_name(p_holder) <> public.f_name(v_priv.full_name) then
    v_status := 'REVIEW'; v_flags := v_flags || 'IME_SE_NE_POKLAPA'::text;
    perform public._risk(v_uid, 'PAYOUT_NAME_MISMATCH', 'user', v_uid::text, jsonb_build_object('holder', p_holder));
  end if;
  if exists (select 1 from public.payout_accounts where account_number = v_acc and user_id <> v_uid and status <> 'REJECTED') then
    v_status := 'REVIEW'; v_flags := v_flags || 'RACUN_KOD_DRUGOG_KORISNIKA'::text;
    perform public._risk(v_uid, 'PAYOUT_ACCOUNT_SHARED', 'user', v_uid::text, '{}'::jsonb);
  end if;
  if exists (select 1 from public.orders where seller_id = v_uid and payout_status in ('REMITTANCE_PENDING','PAYOUT_HOLD')) then
    v_flags := v_flags || 'PROMENA_SA_OTVORENIM_ISPLATAMA'::text;
    perform public._risk(v_uid, 'PAYOUT_ACCOUNT_CHANGED_WITH_PENDING', 'user', v_uid::text, '{}'::jsonb);
  end if;
  update public.payout_accounts set is_current = false where user_id = v_uid and is_current;
  insert into public.payout_accounts (user_id, account_number, holder_name, status, flags)
  values (v_uid, v_acc, regexp_replace(trim(p_holder), '\s+', ' ', 'g'), v_status, v_flags) returning id into v_id;
  if (select identity_status from public.profile_private where id = v_uid) = 'NONE' then
    update public.profile_private set identity_status = 'PENDING' where id = v_uid;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id, 'status', v_status, 'account', v_acc);
end $$;

create or replace function public.create_data_request(p_kind text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid();
begin
  insert into public.data_requests (user_id, kind, note) values (v_uid, p_kind, left(p_note, 1000));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.mark_notifications_read() returns void
language sql security definer set search_path = public as
$$ update public.notifications set read_at = now() where user_id = auth.uid() and read_at is null $$;

create or replace function public.my_status() returns jsonb
language sql stable security definer set search_path = public as
$$ select jsonb_build_object(
    'phone_verified', pp.phone_verified_at is not null,
    'phone', public.mask_phone(pp.phone),
    'terms_ok', pp.terms_version = (public.cfg('policy_versions') ->> 'terms'),
    'identity_status', pp.identity_status,
    'full_name', pp.full_name,
    'payout', (select jsonb_build_object('account', pa.account_number, 'holder', pa.holder_name, 'status', pa.status, 'flags', pa.flags)
                 from public.payout_accounts pa where pa.user_id = pp.id and pa.is_current order by created_at desc limit 1),
    'delivery', jsonb_build_object('name', pp.delivery_name, 'phone', pp.delivery_phone, 'street', pp.delivery_street, 'city', pp.delivery_city, 'postal', pp.delivery_postal),
    'pickup', jsonb_build_object('street', pp.pickup_street, 'city', pp.pickup_city, 'postal', pp.pickup_postal),
    'marketing', pp.marketing_consent,
    'status', p.status,
    'unread', (select count(*) from public.notifications n where n.user_id = pp.id and n.read_at is null),
    'is_staff', exists (select 1 from public.admin_users a where a.user_id = pp.id and a.active))
  from public.profile_private pp join public.profiles p on p.id = pp.id
  where pp.id = auth.uid() $$;

-- ---------------------------------------------------------------------
-- 11. Oglasi: čuvanje, provera, objava
-- ---------------------------------------------------------------------
create or replace function public._evaluate_listing(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare l public.listings; c public.categories; reasons text[] := '{}'; kw text; v_status text;
begin
  select * into l from public.listings where id = p_id for update;
  select * into c from public.categories where id = l.category_id;
  reasons := public.detect_contact(l.title || ' ' || l.description);
  if array_length(reasons, 1) > 0 then
    perform public._risk(l.seller_id, 'LISTING_CONTACT_DATA', 'listing', l.id::text, jsonb_build_object('hits', reasons));
  end if;
  for kw in select jsonb_array_elements_text(coalesce(public.cfg('prohibited_keywords'), '[]'::jsonb)) loop
    if l.search_doc ~ ('(^|[^a-z0-9])' || public.f_norm(kw) || '($|[^a-z0-9])') then reasons := reasons || ('zabranjena roba: ' || kw); end if;
  end loop;
  if c.requires_review then reasons := reasons || ('kategorija zahteva pregled: ' || c.name); end if;
  if exists (select 1 from public.listings x where x.seller_id = l.seller_id and x.id <> l.id
               and x.status in ('ACTIVE','PENDING_REVIEW') and public.f_norm(x.title) = public.f_norm(l.title)) then
    reasons := reasons || 'mogući dupli oglas'::text;
  end if;
  v_status := case when array_length(reasons, 1) > 0 then 'PENDING_REVIEW' else 'ACTIVE' end;
  update public.listings set status = v_status,
         published_at = case when v_status = 'ACTIVE' then coalesce(published_at, now()) else published_at end,
         moderation_note = case when v_status = 'PENDING_REVIEW' then array_to_string(reasons, '; ') else null end
   where id = l.id;
  insert into public.listing_moderation (listing_id, decision, reasons, auto)
  values (l.id, case when v_status = 'ACTIVE' then 'AUTO_APPROVED' else 'SENT_TO_REVIEW' end, reasons, true);
  return jsonb_build_object('status', v_status, 'reasons', reasons);
end $$;

create or replace function public.save_listing(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); l public.listings; v_id uuid;
        v_title text := trim(p ->> 'title'); v_desc text := coalesce(trim(p ->> 'description'), '');
        v_price numeric := (p ->> 'price_rsd')::numeric; v_decl numeric := coalesce(nullif(p ->> 'declared_value_rsd', '')::numeric, (p ->> 'price_rsd')::numeric);
        v_w integer := (p ->> 'weight_g')::integer; v_lc integer := (p ->> 'length_cm')::integer;
        v_wc integer := (p ->> 'width_cm')::integer; v_hc integer := (p ->> 'height_cm')::integer;
        v_eval jsonb;
begin
  if length(coalesce(v_title, '')) < 5 or length(v_title) > 80 then raise exception 'Naslov mora imati od 5 do 80 znakova.'; end if;
  if length(v_desc) > 4000 then raise exception 'Opis može imati najviše 4000 znakova.'; end if;
  if v_price is null or v_price <= 0 or v_price <> trunc(v_price) then raise exception 'Cena mora biti ceo broj dinara veći od nule.'; end if;
  if v_price > public.cfg_num('max_price_rsd') then raise exception 'Cena je veća od dozvoljene (% RSD).', public.cfg_num('max_price_rsd'); end if;
  if v_decl is null or v_decl <= 0 then raise exception 'Deklarisana vrednost mora biti veća od nule.'; end if;
  if v_w is null or v_w <= 0 then raise exception 'Unesi masu paketa u gramima.'; end if;
  if v_w > public.cfg_num('max_weight_kg') * 1000 then raise exception 'Paket je teži od dozvoljenih % kg za BEX dostavu.', public.cfg_num('max_weight_kg'); end if;
  if coalesce(v_lc, 0) <= 0 or coalesce(v_wc, 0) <= 0 or coalesce(v_hc, 0) <= 0 then raise exception 'Unesi dimenzije paketa u centimetrima.'; end if;
  if greatest(v_lc, v_wc, v_hc) > public.cfg_num('max_side_cm') then raise exception 'Najduža stranica paketa može biti najviše % cm.', public.cfg_num('max_side_cm'); end if;
  if coalesce(p ->> 'sale_mode', '') not in ('BUY','CONTACT') then raise exception 'Izaberi način prodaje: Kupi ili Kontaktiraj me.'; end if;
  if coalesce(trim(p ->> 'city'), '') = '' then raise exception 'Unesi mesto.'; end if;

  if p_id is null then
    insert into public.listings (seller_id, category_id, title, description, condition, price_para, price_negotiable, sale_mode, city,
                                 weight_g, length_cm, width_cm, height_cm, declared_value_para, rights_confirmed_at)
    values (v_uid, p ->> 'category_id', v_title, v_desc, p ->> 'condition', (v_price * 100)::bigint, coalesce((p ->> 'price_negotiable')::boolean, false),
            p ->> 'sale_mode', trim(p ->> 'city'), v_w, v_lc, v_wc, v_hc, (v_decl * 100)::bigint,
            case when coalesce((p ->> 'rights_confirmed')::boolean, false) then now() end)
    returning id into v_id;
    return jsonb_build_object('ok', true, 'id', v_id, 'status', 'DRAFT');
  end if;

  select * into l from public.listings where id = p_id for update;
  if not found or l.seller_id <> v_uid then raise exception 'Oglas nije pronađen.'; end if;
  if l.status in ('RESERVED','SOLD','REMOVED') then raise exception 'Ovaj oglas se više ne može menjati.'; end if;
  update public.listings set category_id = p ->> 'category_id', title = v_title, description = v_desc, condition = p ->> 'condition',
         price_para = (v_price * 100)::bigint, price_negotiable = coalesce((p ->> 'price_negotiable')::boolean, false),
         sale_mode = p ->> 'sale_mode', city = trim(p ->> 'city'), weight_g = v_w, length_cm = v_lc, width_cm = v_wc, height_cm = v_hc,
         declared_value_para = (v_decl * 100)::bigint,
         rights_confirmed_at = case when coalesce((p ->> 'rights_confirmed')::boolean, false) then coalesce(rights_confirmed_at, now()) else null end
   where id = p_id;
  if l.status in ('ACTIVE','PENDING_REVIEW') then
    v_eval := public._evaluate_listing(p_id);
    return jsonb_build_object('ok', true, 'id', p_id) || v_eval;
  end if;
  return jsonb_build_object('ok', true, 'id', p_id, 'status', l.status);
end $$;

create or replace function public.set_listing_media(p_listing_id uuid, p_paths text[]) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); l public.listings; v_path text; i integer := 0;
begin
  select * into l from public.listings where id = p_listing_id;
  if not found or l.seller_id <> v_uid then raise exception 'Oglas nije pronađen.'; end if;
  if l.status in ('RESERVED','SOLD','REMOVED') then raise exception 'Fotografije ovog oglasa se više ne mogu menjati.'; end if;
  if coalesce(array_length(p_paths, 1), 0) > public.cfg_num('max_listing_photos') then
    raise exception 'Najviše % fotografija po oglasu.', public.cfg_num('max_listing_photos');
  end if;
  delete from public.listing_media where listing_id = p_listing_id;
  foreach v_path in array coalesce(p_paths, '{}') loop
    if v_path not like v_uid::text || '/' || p_listing_id::text || '/%' or v_path like '%..%' then
      raise exception 'Neispravna putanja fotografije.';
    end if;
    insert into public.listing_media (listing_id, path, sort) values (p_listing_id, v_path, i);
    i := i + 1;
  end loop;
  return jsonb_build_object('ok', true, 'count', i);
end $$;

create or replace function public.publish_listing(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); l public.listings; pp public.profile_private;
begin
  select * into l from public.listings where id = p_id for update;
  if not found or l.seller_id <> v_uid then raise exception 'Oglas nije pronađen.'; end if;
  if l.status not in ('DRAFT','REJECTED') then raise exception 'Oglas je već objavljen ili je na pregledu.'; end if;
  select * into pp from public.profile_private where id = v_uid;
  if pp.phone_verified_at is null then raise exception 'Pre objave potvrdi broj mobilnog telefona u profilu.'; end if;
  if pp.terms_version is distinct from public.cfg('policy_versions') ->> 'terms' then raise exception 'Prihvati važeće uslove korišćenja.'; end if;
  if l.rights_confirmed_at is null then raise exception 'Potvrdi da imaš pravo da prodaješ predmet i da je opis tačan.'; end if;
  if not exists (select 1 from public.listing_media where listing_id = p_id) then raise exception 'Dodaj bar jednu fotografiju.'; end if;
  if public.shipping_quote_para(l.weight_g) is null then raise exception 'Za ovu masu ne postoji BEX tarifa.'; end if;
  if public.cfg_bool('publish_requires_payout_account')
     and not exists (select 1 from public.payout_accounts where user_id = v_uid and is_current and status <> 'REJECTED') then
    raise exception 'Pre objave unesi račun za isplatu u profilu (isplatu vrši BEX samo na tvoj račun).';
  end if;
  perform public._rate('publish');
  return jsonb_build_object('ok', true) || public._evaluate_listing(p_id);
end $$;

create or replace function public.set_listing_status(p_id uuid, p_status text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); l public.listings;
begin
  select * into l from public.listings where id = p_id for update;
  if not found or l.seller_id <> v_uid then raise exception 'Oglas nije pronađen.'; end if;
  if p_status = 'PAUSED' and l.status = 'ACTIVE' then
    update public.listings set status = 'PAUSED' where id = p_id;
  elsif p_status = 'ACTIVE' and l.status = 'PAUSED' then
    return jsonb_build_object('ok', true) || public._evaluate_listing(p_id);
  elsif p_status = 'REMOVED' and l.status not in ('RESERVED','SOLD') then
    update public.listings set status = 'REMOVED' where id = p_id;
  else
    raise exception 'Ova promena statusa nije dozvoljena.';
  end if;
  return jsonb_build_object('ok', true, 'status', p_status);
end $$;

create or replace function public.search_listings(
  p_q text default null, p_category text default null, p_min_rsd numeric default null, p_max_rsd numeric default null,
  p_city text default null, p_mode text default null, p_sort text default 'newest', p_limit integer default 24, p_offset integer default 0)
returns table (id uuid, title text, price_para bigint, price_negotiable boolean, sale_mode text, city text, condition text,
               category_id text, published_at timestamptz, cover text, seller_id uuid, seller_name text, total bigint)
language sql stable security definer set search_path = public as
$$ with q as (select nullif(public.f_norm(trim(coalesce(p_q, ''))), '') as t)
  select l.id, l.title, l.price_para, l.price_negotiable, l.sale_mode, l.city, l.condition, l.category_id, l.published_at,
         (select m.path from public.listing_media m where m.listing_id = l.id order by m.sort limit 1),
         l.seller_id, p.display_name, count(*) over ()
    from public.listings l join public.profiles p on p.id = l.seller_id cross join q
   where l.status = 'ACTIVE' and p.status = 'ACTIVE'
     and (q.t is null
          or l.search_doc like '%' || replace(replace(replace(q.t, '\', '\\'), '%', '\%'), '_', '\_') || '%'
          or extensions.word_similarity(q.t, l.search_doc) >= 0.45)
     and (p_category is null or l.category_id = p_category)
     and (p_min_rsd is null or l.price_para >= p_min_rsd * 100)
     and (p_max_rsd is null or l.price_para <= p_max_rsd * 100)
     and (p_city is null or public.f_norm(l.city) = public.f_norm(p_city))
     and (p_mode is null or l.sale_mode = p_mode)
   order by
     case when p_sort = 'price_asc' then l.price_para end asc,
     case when p_sort = 'price_desc' then l.price_para end desc,
     case when p_sort = 'relevance' and q.t is not null then extensions.word_similarity(q.t, l.search_doc) end desc nulls last,
     l.published_at desc nulls last
   limit least(greatest(coalesce(p_limit, 24), 1), 60) offset greatest(coalesce(p_offset, 0), 0) $$;

create or replace function public.get_shipping_quote(p_listing_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as
$$ declare l public.listings; v_ship bigint; v_payer text := coalesce(public.cfg('shipping_payer') #>> '{}', 'buyer');
begin
  select * into l from public.listings where id = p_listing_id and status in ('ACTIVE','RESERVED');
  if not found then return null; end if;
  v_ship := public.shipping_quote_para(l.weight_g);
  return jsonb_build_object('shipping_para', v_ship, 'payer', v_payer,
    'cod_para', case when v_payer = 'buyer' then l.price_para + v_ship else l.price_para end,
    'evidence_required', l.declared_value_para >= public.cfg_num('evidence_value_threshold_rsd') * 100,
    'sandbox', public.cfg_bool('sandbox_mode'));
end $$;

-- ---------------------------------------------------------------------
-- 12. Chat i formalne ponude
-- ---------------------------------------------------------------------
create or replace function public.start_conversation(p_listing_id uuid) returns uuid
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); l public.listings; v_id uuid;
begin
  select * into l from public.listings where id = p_listing_id and status = 'ACTIVE';
  if not found then raise exception 'Oglas nije aktivan.'; end if;
  if l.seller_id = v_uid then raise exception 'Ne možeš slati poruke na sopstveni oglas.'; end if;
  if (select phone_verified_at from public.profile_private where id = v_uid) is null then
    raise exception 'Za slanje poruka potvrdi broj telefona u profilu.';
  end if;
  insert into public.conversations (listing_id, buyer_id, seller_id) values (l.id, v_uid, l.seller_id)
  on conflict (listing_id, buyer_id) do update set listing_id = excluded.listing_id
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.send_message(p_conversation_id uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); c public.conversations; v_body text := trim(coalesce(p_body, '')); hits text[]; v_other uuid;
begin
  select * into c from public.conversations where id = p_conversation_id;
  if not found or v_uid not in (c.buyer_id, c.seller_id) then raise exception 'Razgovor nije pronađen.'; end if;
  if length(v_body) = 0 or length(v_body) > 2000 then raise exception 'Poruka mora imati od 1 do 2000 znakova.'; end if;
  perform public._rate('message');
  v_other := case when v_uid = c.buyer_id then c.seller_id else c.buyer_id end;
  hits := public.detect_contact(v_body);
  if array_length(hits, 1) > 0 and not public.cfg_bool('external_contact_sharing_enabled') then
    insert into public.messages (conversation_id, sender_id, body, blocked, blocked_reason)
    values (c.id, v_uid, v_body, true, array_to_string(hits, ', '));
    perform public._risk(v_uid, 'CHAT_CONTACT_ATTEMPT', 'conversation', c.id::text, jsonb_build_object('hits', hits));
    return jsonb_build_object('ok', true, 'blocked', true,
      'reason', 'Poruka nije isporučena: deljenje kontakata, linkova i dogovor van eBex-a nisu dozvoljeni.');
  end if;
  insert into public.messages (conversation_id, sender_id, body) values (c.id, v_uid, v_body);
  update public.conversations set last_message_at = now() where id = c.id;
  perform public._notify(v_other, 'Nova poruka', left(v_body, 120), '#/poruke/' || c.id);
  return jsonb_build_object('ok', true, 'blocked', false);
end $$;

create or replace function public.make_offer(p_conversation_id uuid, p_price_rsd numeric) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); c public.conversations; l public.listings; v_other uuid; v_id uuid; pp public.profile_private;
begin
  select * into c from public.conversations where id = p_conversation_id;
  if not found or v_uid not in (c.buyer_id, c.seller_id) then raise exception 'Razgovor nije pronađen.'; end if;
  select * into l from public.listings where id = c.listing_id;
  if l.status <> 'ACTIVE' then raise exception 'Oglas više nije aktivan.'; end if;
  if l.sale_mode <> 'CONTACT' then raise exception 'Za ovaj oglas važi fiksna cena — koristi dugme Kupi.'; end if;
  if p_price_rsd is null or p_price_rsd <= 0 or p_price_rsd <> trunc(p_price_rsd) then raise exception 'Cena ponude mora biti ceo broj dinara.'; end if;
  if v_uid = c.buyer_id then
    select * into pp from public.profile_private where id = v_uid;
    if pp.delivery_street is null or pp.delivery_phone is null then
      raise exception 'Pre slanja ponude sačuvaj adresu za BEX dostavu u profilu.';
    end if;
  end if;
  perform public._rate('offer');
  v_other := case when v_uid = c.buyer_id then c.seller_id else c.buyer_id end;
  update public.offers set status = 'WITHDRAWN', responded_at = now() where conversation_id = c.id and status = 'PENDING';
  insert into public.offers (conversation_id, listing_id, from_user, to_user, price_para, expires_at)
  values (c.id, l.id, v_uid, v_other, (p_price_rsd * 100)::bigint, now() + make_interval(hours => public.cfg_num('offer_ttl_hours')::int))
  returning id into v_id;
  insert into public.messages (conversation_id, sender_id, kind, body, offer_id)
  values (c.id, v_uid, 'OFFER', 'Formalna ponuda: ' || translate(to_char(p_price_rsd, 'FM999,999,999'), ',', '.') || ' RSD', v_id);
  update public.conversations set last_message_at = now() where id = c.id;
  perform public._notify(v_other, 'Nova ponuda', 'Ponuda za „' || l.title || '”', '#/poruke/' || c.id);
  return jsonb_build_object('ok', true, 'id', v_id);
end $$;

-- Jedino mesto gde nastaje narudžbina (Kupi i prihvaćena ponuda)
create or replace function public._create_order(p_listing uuid, p_buyer uuid, p_price bigint, p_source text, p_offer uuid, p_delivery jsonb)
returns uuid language plpgsql security definer set search_path = public as
$$ declare l public.listings; bpp public.profile_private; v_ship bigint; v_payer text := coalesce(public.cfg('shipping_payer') #>> '{}', 'buyer');
        v_cod bigint; v_id uuid; v_no text; v_phone text := public.normalize_phone(p_delivery ->> 'phone'); v_media jsonb;
begin
  select * into l from public.listings where id = p_listing for update;
  if not found or l.status <> 'ACTIVE' then raise exception 'Oglas više nije dostupan.'; end if;
  if l.seller_id = p_buyer then raise exception 'Ne možeš kupiti sopstveni predmet.'; end if;
  if exists (select 1 from public.profiles where id in (l.seller_id, p_buyer) and status <> 'ACTIVE') then
    raise exception 'Kupovina trenutno nije moguća. Obrati se podršci.';
  end if;
  select * into bpp from public.profile_private where id = p_buyer;
  if bpp.phone_verified_at is null then raise exception 'Kupac mora imati potvrđen broj telefona.'; end if;
  if bpp.terms_version is distinct from public.cfg('policy_versions') ->> 'terms' then raise exception 'Kupac mora prihvatiti važeće uslove.'; end if;
  if v_phone is null then raise exception 'Telefon primaoca nije ispravan.'; end if;
  if coalesce(trim(p_delivery ->> 'name'), '') = '' or coalesce(trim(p_delivery ->> 'street'), '') = '' or coalesce(trim(p_delivery ->> 'city'), '') = '' then
    raise exception 'Popuni ime primaoca, ulicu i mesto za BEX dostavu.';
  end if;
  if coalesce(p_delivery ->> 'postal', '') !~ '^[0-9]{5}$' then raise exception 'Poštanski broj mora imati 5 cifara.'; end if;
  v_ship := public.shipping_quote_para(l.weight_g);
  if v_ship is null then raise exception 'Za ovu pošiljku ne postoji BEX tarifa.'; end if;
  v_cod := case when v_payer = 'buyer' then p_price + v_ship else p_price end;
  if v_cod - v_ship <= 0 then raise exception 'Cena mora biti veća od cene dostave.'; end if;
  select coalesce(jsonb_agg(m.path order by m.sort), '[]'::jsonb) into v_media from public.listing_media m where m.listing_id = l.id;
  v_no := 'EB-' || to_char(now() at time zone 'Europe/Belgrade', 'YYMM') || '-' || lpad(nextval('public.order_no_seq')::text, 6, '0');
  insert into public.orders (order_no, listing_id, buyer_id, seller_id, offer_id, source, item_price_para, shipping_para, shipping_payer,
                             cod_amount_para, seller_net_para, evidence_required, handover_deadline, buyer_city, listing_snapshot)
  values (v_no, l.id, p_buyer, l.seller_id, p_offer, p_source, p_price, v_ship, v_payer, v_cod, v_cod - v_ship,
          l.declared_value_para >= public.cfg_num('evidence_value_threshold_rsd') * 100,
          now() + make_interval(days => public.cfg_num('seller_handover_days')::int),
          trim(p_delivery ->> 'city'),
          to_jsonb(l) - 'search_doc' || jsonb_build_object('media', v_media))
  returning id into v_id;
  insert into public.order_delivery (order_id, recipient_name, recipient_phone, street, city, postal_code, note)
  values (v_id, trim(p_delivery ->> 'name'), v_phone, trim(p_delivery ->> 'street'), trim(p_delivery ->> 'city'), p_delivery ->> 'postal', left(p_delivery ->> 'note', 200));
  update public.listings set status = 'RESERVED' where id = l.id;
  update public.offers set status = 'EXPIRED', responded_at = now() where listing_id = l.id and status = 'PENDING' and id is distinct from p_offer;
  perform public._notify(l.seller_id, 'Nova porudžbina ' || v_no, 'Spakuj predmet i prijavi pošiljku BEX-u u roku.', '#/narudzbina/' || v_id);
  perform public._notify(p_buyer, 'Porudžbina ' || v_no || ' je potvrđena', 'Plaćaš kuriru BEX-a pri uručenju.', '#/narudzbina/' || v_id);
  if (select count(*) from public.orders where buyer_id = p_buyer and created_at > now() - interval '1 day') > 5 then
    perform public._risk(p_buyer, 'MANY_ORDERS_24H', 'order', v_id::text, '{}'::jsonb);
  end if;
  return v_id;
end $$;

create or replace function public.place_order(p_listing_id uuid, p_delivery jsonb, p_save_default boolean default false) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); l public.listings; v_id uuid;
begin
  select * into l from public.listings where id = p_listing_id;
  if not found then raise exception 'Oglas nije pronađen.'; end if;
  if l.sale_mode <> 'BUY' then raise exception 'Za ovaj oglas se kupovina dogovara kroz poruke i formalnu ponudu.'; end if;
  perform public._rate('order');
  v_id := public._create_order(l.id, v_uid, l.price_para, 'BUY', null, p_delivery);
  if coalesce(p_save_default, false) then perform public.update_profile(jsonb_build_object('delivery', p_delivery)); end if;
  return jsonb_build_object('ok', true, 'order_id', v_id);
end $$;

create or replace function public.respond_offer(p_offer_id uuid, p_accept boolean) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); o public.offers; c public.conversations; bpp public.profile_private; v_order uuid;
begin
  select * into o from public.offers where id = p_offer_id for update;
  if not found or o.to_user <> v_uid then raise exception 'Ponuda nije pronađena.'; end if;
  if o.status <> 'PENDING' then raise exception 'Ponuda više nije aktivna.'; end if;
  if o.expires_at < now() then
    update public.offers set status = 'EXPIRED', responded_at = now() where id = o.id;
    return jsonb_build_object('ok', false, 'error', 'Ponuda je istekla.');
  end if;
  select * into c from public.conversations where id = o.conversation_id;
  if not p_accept then
    update public.offers set status = 'REJECTED', responded_at = now() where id = o.id;
    insert into public.messages (conversation_id, sender_id, kind, body) values (c.id, null, 'SYSTEM', 'Ponuda je odbijena.');
    perform public._notify(o.from_user, 'Ponuda odbijena', null, '#/poruke/' || c.id);
    return jsonb_build_object('ok', true, 'accepted', false);
  end if;
  select * into bpp from public.profile_private where id = c.buyer_id;
  if bpp.delivery_street is null then raise exception 'Kupac nema sačuvanu adresu za dostavu. Kupac je unosi u profilu.'; end if;
  v_order := public._create_order(o.listing_id, c.buyer_id, o.price_para, 'OFFER', o.id,
    jsonb_build_object('name', bpp.delivery_name, 'phone', bpp.delivery_phone, 'street', bpp.delivery_street, 'city', bpp.delivery_city, 'postal', bpp.delivery_postal));
  update public.offers set status = 'ACCEPTED', responded_at = now(), order_id = v_order where id = o.id;
  insert into public.messages (conversation_id, sender_id, kind, body)
  values (c.id, null, 'SYSTEM', 'Ponuda je prihvaćena. Kreirana je porudžbina sa plaćanjem pouzećem preko BEX-a.');
  return jsonb_build_object('ok', true, 'accepted', true, 'order_id', v_order);
end $$;

-- ---------------------------------------------------------------------
-- 13. Narudžbina: otkazivanje, dokaz pakovanja, predaja BEX-u, reklamacija
-- ---------------------------------------------------------------------
create or replace function public.cancel_order(p_order_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); o public.orders; v_other uuid;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or v_uid not in (o.buyer_id, o.seller_id) then raise exception 'Porudžbina nije pronađena.'; end if;
  if o.status <> 'AWAITING_SHIPMENT' or exists (select 1 from public.shipments where order_id = o.id) then
    raise exception 'Pošiljka je već prijavljena BEX-u. Za otkazivanje se obrati podršci.';
  end if;
  perform public._set_reason(p_reason);
  update public.orders set status = 'CANCELLED', cod_status = 'CANCELLED', cancel_reason = left(coalesce(p_reason, ''), 300) where id = o.id;
  update public.listings set status = 'ACTIVE' where id = o.listing_id and status = 'RESERVED';
  v_other := case when v_uid = o.buyer_id then o.seller_id else o.buyer_id end;
  perform public._notify(v_other, 'Porudžbina ' || o.order_no || ' je otkazana', p_reason, '#/narudzbina/' || o.id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.add_packing_evidence(p_order_id uuid, p_path text, p_sha256 text, p_mime text, p_size bigint) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); o public.orders;
begin
  select * into o from public.orders where id = p_order_id;
  if not found or o.seller_id <> v_uid then raise exception 'Porudžbina nije pronađena.'; end if;
  if o.status <> 'AWAITING_SHIPMENT' then raise exception 'Dokaz pakovanja se dodaje pre predaje pošiljke.'; end if;
  if p_path not like v_uid::text || '/' || p_order_id::text || '/%' or p_path like '%..%' then raise exception 'Neispravna putanja datoteke.'; end if;
  if p_mime not in ('image/jpeg','image/png','image/webp','video/mp4','video/quicktime','video/webm') then raise exception 'Dozvoljene su fotografije i video.'; end if;
  if coalesce(p_sha256, '') !~ '^[0-9a-f]{64}$' then raise exception 'Nedostaje kontrolni zbir datoteke.'; end if;
  insert into public.packing_evidence (order_id, uploader_id, path, sha256, mime, size_bytes) values (o.id, v_uid, p_path, p_sha256, p_mime, p_size);
  return jsonb_build_object('ok', true, 'count', (select count(*) from public.packing_evidence where order_id = o.id));
end $$;

create or replace function public.mark_ready_for_pickup(p_order_id uuid) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); o public.orders; pp public.profile_private; d public.order_delivery; v_tr text; v_cnt integer;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.seller_id <> v_uid then raise exception 'Porudžbina nije pronađena.'; end if;
  if o.status <> 'AWAITING_SHIPMENT' then raise exception 'Porudžbina nije u fazi predaje.'; end if;
  if exists (select 1 from public.shipments where order_id = o.id and direction = 'OUTBOUND') then
    return jsonb_build_object('ok', true, 'already', true);
  end if;
  if o.handover_deadline < now() then raise exception 'Rok za predaju je istekao.'; end if;
  select * into pp from public.profile_private where id = v_uid;
  if pp.pickup_street is null then raise exception 'Unesi adresu preuzimanja u profilu (odakle BEX preuzima paket).'; end if;
  if public.cfg_bool('payout_requires_verified_identity') and pp.identity_status <> 'VERIFIED' then
    raise exception 'Identitet još nije verifikovan. Isplata je moguća samo verifikovanom prodavcu.';
  end if;
  if not exists (select 1 from public.payout_accounts where user_id = v_uid and is_current and status = 'VERIFIED') then
    raise exception 'Račun za isplatu još nije verifikovan.';
  end if;
  select count(*) into v_cnt from public.packing_evidence where order_id = o.id;
  if o.evidence_required and v_cnt < public.cfg_num('evidence_min_photos') then
    raise exception 'Za ovu vrednost je obavezan dokaz pakovanja. Dodato: % od % potrebnih fotografija.', v_cnt, public.cfg_num('evidence_min_photos');
  end if;
  select * into d from public.order_delivery where order_id = o.id;
  v_tr := 'SBX' || lpad(nextval('public.tracking_seq')::text, 9, '0');
  insert into public.shipments (order_id, tracking_no, is_sandbox) values (o.id, v_tr, public.cfg_bool('sandbox_mode'));
  insert into public.outbox (topic, idempotency_key, payload, status) values ('BEX_CREATE_SHIPMENT', 'create:' || o.id,
    jsonb_build_object('order_no', o.order_no, 'tracking_no', v_tr, 'cod_amount_para', o.cod_amount_para,
      'pickup', jsonb_build_object('name', pp.full_name, 'phone', pp.phone, 'street', pp.pickup_street, 'city', pp.pickup_city, 'postal', pp.pickup_postal),
      'delivery', to_jsonb(d) - 'order_id',
      'parcel', jsonb_build_object('weight_g', o.listing_snapshot -> 'weight_g', 'length_cm', o.listing_snapshot -> 'length_cm',
                                   'width_cm', o.listing_snapshot -> 'width_cm', 'height_cm', o.listing_snapshot -> 'height_cm',
                                   'declared_value_para', o.listing_snapshot -> 'declared_value_para')),
    case when public.cfg_bool('sandbox_mode') then 'SANDBOX_DONE' else 'PENDING' end)
  on conflict (idempotency_key) do nothing;
  perform public._notify(o.buyer_id, 'Pošiljka je prijavljena BEX-u', 'Broj pošiljke: ' || v_tr, '#/narudzbina/' || o.id);
  return jsonb_build_object('ok', true, 'tracking_no', v_tr);
end $$;

create or replace function public._open_hold(p_order uuid, p_complaint uuid, p_kind text, p_reason text) returns uuid
language plpgsql security definer set search_path = public as
$$ declare v_id uuid;
begin
  insert into public.payout_holds (order_id, complaint_id, kind, reason, bex_hold_requested_at, created_by)
  values (p_order, p_complaint, p_kind, p_reason, now(), auth.uid()) returning id into v_id;
  update public.orders set payout_status = 'PAYOUT_HOLD' where id = p_order;
  insert into public.outbox (topic, idempotency_key, payload, status)
  values ('BEX_HOLD_REQUEST', 'hold:' || v_id, jsonb_build_object('order_id', p_order, 'hold_id', v_id, 'reason', p_kind),
          case when public.cfg_bool('sandbox_mode') then 'SANDBOX_DONE' else 'PENDING' end);
  return v_id;
end $$;

create or replace function public.open_complaint(p_order_id uuid, p_reason text, p_description text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid := public._uid(); o public.orders; v_id uuid; v_post boolean;
begin
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.buyer_id <> v_uid then raise exception 'Porudžbina nije pronađena.'; end if;
  if not exists (select 1 from jsonb_array_elements(public.cfg('complaint_reasons')) e where e ->> 'code' = p_reason) then
    raise exception 'Izaberi razlog reklamacije sa liste.';
  end if;
  if length(trim(coalesce(p_description, ''))) < 10 then raise exception 'Opiši problem (najmanje 10 znakova).'; end if;
  if o.cod_status <> 'COLLECTED' then raise exception 'Reklamacija se otvara posle uručenja pošiljke.'; end if;
  if o.delivered_at < now() - make_interval(days => public.cfg_num('complaint_window_days')::int) then
    raise exception 'Rok za reklamaciju je istekao.';
  end if;
  if exists (select 1 from public.complaints where order_id = o.id and status in ('OPEN','UNDER_REVIEW')) then
    raise exception 'Za ovu porudžbinu već postoji otvorena reklamacija.';
  end if;
  perform public._rate('complaint');
  v_post := o.payout_status = 'PAID';
  insert into public.complaints (order_id, buyer_id, reason, description, post_payout)
  values (o.id, v_uid, p_reason, left(trim(p_description), 3000), v_post) returning id into v_id;
  if v_post then
    update public.orders set status = 'MANUAL_REVIEW' where id = o.id;
    perform public._recon(o.id, 'COMPLAINT_AFTER_PAYOUT', jsonb_build_object('complaint_id', v_id));
  else
    update public.orders set status = 'DISPUTED' where id = o.id;
    perform public._open_hold(o.id, v_id, 'COMPLAINT', p_reason);
  end if;
  perform public._notify(o.seller_id, 'Reklamacija za ' || o.order_no,
    case when v_post then 'Kupac je prijavio problem. Slučaj pregleda eBex podrška.' else 'Isplata je zadržana dok eBex ne pregleda slučaj.' end,
    '#/narudzbina/' || o.id);
  perform public._notify(o.buyer_id, 'Reklamacija je zaprimljena', 'eBex će pregledati slučaj i obavestiti obe strane.', '#/narudzbina/' || o.id);
  return jsonb_build_object('ok', true, 'id', v_id, 'post_payout', v_post);
end $$;

-- ---------------------------------------------------------------------
-- 14. Obrada BEX događaja (idempotentno, otporno na redosled)
--     U produkciji ovu funkciju poziva BEX webhook (Edge Function, service_role).
-- ---------------------------------------------------------------------
create or replace function public._apply_payout(p_order uuid, p_occurred timestamptz, p_payload jsonb, p_event_id bigint) returns text
language plpgsql security definer set search_path = public as
$$ declare o public.orders; v_ref text := coalesce(p_payload ->> 'payout_ref', 'evt-' || p_event_id);
begin
  select * into o from public.orders where id = p_order for update;
  if o.payout_status = 'PAID' then return 'ALREADY_PAID'; end if;
  if o.cod_status <> 'COLLECTED' then return 'DEFERRED'; end if;
  if exists (select 1 from public.payout_holds where order_id = o.id and status in ('ACTIVE','RELEASE_REQUESTED')) then
    perform public._recon(o.id, 'PAYOUT_DESPITE_HOLD', jsonb_build_object('event_id', p_event_id, 'payout_ref', v_ref));
  end if;
  update public.orders set payout_status = 'PAID', paid_out_at = p_occurred, payout_ref = v_ref,
         status = case when status = 'DELIVERED' then 'COMPLETED' else status end
   where id = o.id;
  perform public._ledger(o.id, 'payout:' || o.id, 'BEX isplata prodavcu', v_ref, jsonb_build_array(
    jsonb_build_object('account', 'SELLER_PAYABLE', 'amount', o.seller_net_para),
    jsonb_build_object('account', 'BEX_COD_RECEIVABLE', 'amount', -o.seller_net_para)));
  if o.shipping_para > 0 then
    perform public._ledger(o.id, 'shipfee:' || o.id, 'BEX zadržava cenu dostave', v_ref, jsonb_build_array(
      jsonb_build_object('account', 'BEX_SHIPPING_FEE', 'amount', o.shipping_para),
      jsonb_build_object('account', 'BEX_COD_RECEIVABLE', 'amount', -o.shipping_para)));
  end if;
  update public.profiles set completed_sales = completed_sales + 1 where id = o.seller_id;
  perform public._notify(o.seller_id, 'Isplata je izvršena', 'BEX je isplatio ' || translate(to_char(o.seller_net_para / 100.0, 'FM999,999,990.00'), ',.', '.,') || ' RSD za ' || o.order_no, '#/narudzbina/' || o.id);
  return 'PAID';
end $$;

create or replace function public.process_bex_event(p_external_event_id text, p_tracking_no text, p_event_type text,
                                                    p_occurred_at timestamptz, p_payload jsonb, p_source text default 'SANDBOX')
returns jsonb language plpgsql security definer set search_path = public as
$$ declare v_eid bigint; s public.shipments; o public.orders; v_res text := 'OK'; v_rank integer; ev record;
begin
  insert into public.bex_events (external_event_id, tracking_no, event_type, occurred_at, payload, source)
  values (p_external_event_id, p_tracking_no, p_event_type, coalesce(p_occurred_at, now()), coalesce(p_payload, '{}'::jsonb), p_source)
  on conflict (external_event_id) do nothing returning id into v_eid;
  if v_eid is null then return jsonb_build_object('result', 'DUPLICATE', 'external_event_id', p_external_event_id); end if;

  select * into s from public.shipments where tracking_no = p_tracking_no for update;
  if not found then
    update public.bex_events set processed_at = now(), result = 'UNKNOWN_SHIPMENT' where id = v_eid;
    perform public._recon(null, 'UNKNOWN_SHIPMENT', jsonb_build_object('tracking_no', p_tracking_no, 'event_id', v_eid));
    return jsonb_build_object('result', 'UNKNOWN_SHIPMENT', 'external_event_id', p_external_event_id);
  end if;
  select * into o from public.orders where id = s.order_id for update;
  update public.bex_events set order_id = o.id where id = v_eid;

  v_rank := case p_event_type when 'PICKED_UP' then 10 when 'IN_TRANSIT' then 20 when 'OUT_FOR_DELIVERY' then 30
                              when 'DELIVERED_COD_COLLECTED' then 40 when 'COD_FAILED' then 50 when 'RETURNED_TO_SENDER' then 60 else null end;
  if v_rank is not null and v_rank > s.status_rank then
    update public.shipments set status_rank = v_rank, last_event_at = coalesce(p_occurred_at, now()),
           status = case p_event_type when 'DELIVERED_COD_COLLECTED' then 'DELIVERED' when 'COD_FAILED' then 'RETURNING'
                                      when 'RETURNED_TO_SENDER' then 'RETURNED' else p_event_type end
     where id = s.id;
  end if;

  if p_event_type in ('PICKED_UP','IN_TRANSIT','OUT_FOR_DELIVERY') then
    if o.status = 'AWAITING_SHIPMENT' then
      update public.orders set status = 'IN_TRANSIT' where id = o.id;
      if p_event_type = 'PICKED_UP' then
        perform public._notify(o.buyer_id, 'Pošiljka je na putu', s.tracking_no, '#/narudzbina/' || o.id);
      end if;
    end if;

  elsif p_event_type = 'DELIVERED_COD_COLLECTED' then
    if o.cod_status = 'COLLECTED' then
      v_res := 'ALREADY_COLLECTED';
    elsif o.cod_status <> 'PENDING' or o.status in ('CANCELLED','SHIPMENT_EXPIRED') then
      v_res := 'CONFLICT';
      perform public._recon(o.id, 'COD_AFTER_FINAL_STATE', jsonb_build_object('event_id', v_eid, 'order_status', o.status));
    else
      update public.orders set cod_status = 'COLLECTED', cod_collected_at = coalesce(p_occurred_at, now()),
             delivered_at = coalesce(delivered_at, p_occurred_at, now()),
             status = case when status in ('AWAITING_SHIPMENT','IN_TRANSIT') then 'DELIVERED' else status end,
             payout_status = case when exists (select 1 from public.payout_holds h where h.order_id = o.id and h.status in ('ACTIVE','RELEASE_REQUESTED'))
                                  then 'PAYOUT_HOLD' else 'REMITTANCE_PENDING' end,
             expected_payout_date = public._next_payout_date(coalesce(p_occurred_at, now()))
       where id = o.id;
      perform public._ledger(o.id, 'cod:' || o.id, 'BEX naplatio pouzeće od kupca', coalesce(p_payload ->> 'cod_ref', s.tracking_no), jsonb_build_array(
        jsonb_build_object('account', 'BEX_COD_RECEIVABLE', 'amount', o.cod_amount_para),
        jsonb_build_object('account', 'SELLER_PAYABLE', 'amount', -o.seller_net_para),
        jsonb_build_object('account', 'BEX_SHIPPING_FEE', 'amount', -o.shipping_para)));
      update public.listings set status = 'SOLD' where id = o.listing_id;
      perform public._notify(o.buyer_id, 'Pošiljka je uručena', 'Ako nešto nije u redu, prijavi reklamaciju u roku od ' || public.cfg_num('complaint_window_days') || ' dana.', '#/narudzbina/' || o.id);
      perform public._notify(o.seller_id, 'Kupac je preuzeo pošiljku', 'Očekivana isplata: ' || to_char(public._next_payout_date(coalesce(p_occurred_at, now())), 'DD.MM.YYYY.'), '#/narudzbina/' || o.id);
      for ev in select id, occurred_at, payload from public.bex_events
                 where order_id = o.id and event_type = 'PAYOUT_EXECUTED' and result = 'DEFERRED' order by occurred_at loop
        update public.bex_events set result = public._apply_payout(o.id, ev.occurred_at, ev.payload, ev.id), processed_at = now() where id = ev.id;
      end loop;
    end if;

  elsif p_event_type = 'COD_FAILED' then
    if o.cod_status = 'COLLECTED' then
      v_res := 'CONFLICT';
      perform public._recon(o.id, 'COD_FAILED_AFTER_COLLECTION', jsonb_build_object('event_id', v_eid));
    elsif o.cod_status = 'PENDING' then
      update public.orders set cod_status = 'FAILED', status = 'COD_COLLECTION_FAILED' where id = o.id;
      perform public._notify(o.seller_id, 'Kupac nije preuzeo pošiljku', 'BEX vraća paket na tvoju adresu.', '#/narudzbina/' || o.id);
    end if;

  elsif p_event_type = 'RETURNED_TO_SENDER' then
    update public.listings set status = 'PAUSED' where id = o.listing_id and status = 'RESERVED';
    perform public._notify(o.seller_id, 'Paket je vraćen', 'Oglas je pauziran — možeš ga ponovo aktivirati.', '#/narudzbina/' || o.id);

  elsif p_event_type = 'HOLD_CONFIRMED' then
    update public.payout_holds set bex_hold_confirmed_at = coalesce(bex_hold_confirmed_at, coalesce(p_occurred_at, now()))
     where order_id = o.id and status in ('ACTIVE','RELEASE_REQUESTED');

  elsif p_event_type = 'PAYOUT_EXECUTED' then
    v_res := public._apply_payout(o.id, coalesce(p_occurred_at, now()), p_payload, v_eid);

  elsif p_event_type = 'PAYOUT_FAILED' then
    if o.payout_status <> 'PAID' then
      update public.orders set payout_status = 'PAYOUT_FAILED' where id = o.id;
      perform public._recon(o.id, 'PAYOUT_FAILED', jsonb_build_object('event_id', v_eid, 'payload', p_payload));
      perform public._notify(o.seller_id, 'Isplata nije uspela', 'eBex podrška proverava račun za isplatu.', '#/narudzbina/' || o.id);
    end if;
  else
    v_res := 'UNKNOWN_EVENT';
  end if;

  update public.bex_events set processed_at = now(), result = v_res where id = v_eid;
  return jsonb_build_object('result', v_res, 'event_id', v_eid, 'external_event_id', p_external_event_id);
end $$;

-- ---------------------------------------------------------------------
-- 15. Administrativne radnje (sve proveravaju ovlašćenje i MFA, sve se beleže)
-- ---------------------------------------------------------------------
create or replace function public.admin_whoami() returns jsonb
language sql stable security definer set search_path = public as
$$ select jsonb_build_object('role', public.admin_role(), 'mfa_ok', public.admin_mfa_ok(),
     'mfa_required', public.cfg_bool('admin_mfa_required'), 'sandbox', public.cfg_bool('sandbox_mode'),
     'permissions', coalesce((select jsonb_agg(rp.permission) from public.role_permissions rp where rp.role = public.admin_role()), '[]'::jsonb)) $$;

create or replace function public.admin_moderate_listing(p_id uuid, p_decision text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare l public.listings;
begin
  perform public.require_perm('moderate_listings');
  if p_decision not in ('APPROVE','REJECT','REMOVE') then raise exception 'Nepoznata odluka.'; end if;
  if p_decision <> 'APPROVE' and length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Upiši obrazloženje (najmanje 5 znakova).'; end if;
  select * into l from public.listings where id = p_id for update;
  if not found then raise exception 'Oglas nije pronađen.'; end if;
  if l.status in ('RESERVED','SOLD') and p_decision <> 'REMOVE' then raise exception 'Oglas je u prodaji; moguće je samo uklanjanje.'; end if;
  perform public._set_reason(p_reason);
  update public.listings set
    status = case p_decision when 'APPROVE' then 'ACTIVE' when 'REJECT' then 'REJECTED' else 'REMOVED' end,
    published_at = case when p_decision = 'APPROVE' then coalesce(published_at, now()) else published_at end,
    moderation_note = case when p_decision = 'APPROVE' then null else p_reason end
   where id = p_id;
  insert into public.listing_moderation (listing_id, decision, auto, admin_id, note) values (p_id, p_decision, false, auth.uid(), p_reason);
  perform public._notify(l.seller_id,
    case p_decision when 'APPROVE' then 'Oglas je objavljen' when 'REJECT' then 'Oglas je vraćen na doradu' else 'Oglas je uklonjen' end,
    case when p_decision = 'APPROVE' then l.title else l.title || ': ' || p_reason end, '#/moji-oglasi');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_bex_event(p_order_id uuid, p_event_type text, p_external_event_id text default null) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare s public.shipments;
begin
  perform public.require_perm('bex_simulate');
  if not public.cfg_bool('sandbox_mode') then raise exception 'BEX simulator radi samo u SANDBOX režimu.'; end if;
  select * into s from public.shipments where order_id = p_order_id and direction = 'OUTBOUND';
  if not found then raise exception 'Prodavac još nije prijavio pošiljku BEX-u.'; end if;
  return public.process_bex_event(coalesce(nullif(trim(p_external_event_id), ''), 'SBX-' || p_event_type || '-' || gen_random_uuid()),
                                  s.tracking_no, p_event_type, now(),
                                  jsonb_build_object('simulated', true, 'by', auth.uid(), 'payout_ref', 'SBX-PO-' || left(p_order_id::text, 8)), 'SANDBOX');
end $$;

create or replace function public.admin_sim_due_payouts() returns jsonb
language plpgsql security definer set search_path = public as
$$ declare r record; n integer := 0; v jsonb;
begin
  perform public.require_perm('bex_simulate');
  if not public.cfg_bool('sandbox_mode') then raise exception 'Simulacija isplata radi samo u SANDBOX režimu.'; end if;
  for r in select o.id, s.tracking_no from public.orders o join public.shipments s on s.order_id = o.id and s.direction = 'OUTBOUND'
            where o.payout_status = 'REMITTANCE_PENDING' and o.expected_payout_date <= (now() at time zone 'Europe/Belgrade')::date
              and not exists (select 1 from public.payout_holds h where h.order_id = o.id and h.status in ('ACTIVE','RELEASE_REQUESTED')) loop
    v := public.process_bex_event('SBX-PAYOUT-' || r.id, r.tracking_no, 'PAYOUT_EXECUTED', now(),
                                  jsonb_build_object('simulated', true, 'payout_ref', 'SBX-PO-' || left(r.id::text, 8)), 'SANDBOX');
    if v ->> 'result' = 'PAID' then n := n + 1; end if;
  end loop;
  return jsonb_build_object('ok', true, 'paid', n);
end $$;

create or replace function public.admin_place_hold(p_order_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare o public.orders;
begin
  perform public.require_perm('place_hold');
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Obrazloženje mora imati najmanje 10 znakova.'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then raise exception 'Porudžbina nije pronađena.'; end if;
  perform public._set_reason(p_reason);
  if o.payout_status = 'PAID' then
    perform public._recon(o.id, 'FRAUD_SUSPICION_AFTER_PAYOUT', jsonb_build_object('reason', p_reason));
    update public.orders set status = 'MANUAL_REVIEW' where id = o.id;
    return jsonb_build_object('ok', true, 'note', 'Isplata je već izvršena — otvoren je slučaj za pregled, iznos nije zamrznut.');
  end if;
  if exists (select 1 from public.payout_holds where order_id = o.id and status in ('ACTIVE','RELEASE_REQUESTED')) then
    raise exception 'Zadržavanje je već aktivno.';
  end if;
  perform public._open_hold(o.id, null, 'FRAUD_SUSPICION', p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public._release_hold(p_hold_id uuid, p_reason text) returns text
language plpgsql security definer set search_path = public as
$$ declare h public.payout_holds; o public.orders;
begin
  select * into h from public.payout_holds where id = p_hold_id for update;
  if not found or h.status not in ('ACTIVE','RELEASE_REQUESTED') then raise exception 'Zadržavanje nije aktivno.'; end if;
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Obrazloženje mora imati najmanje 10 znakova.'; end if;
  perform public._set_reason(p_reason);
  if public.cfg_bool('four_eyes_payout_release') then
    if h.status = 'ACTIVE' then
      update public.payout_holds set status = 'RELEASE_REQUESTED', release_requested_by = auth.uid(), release_requested_at = now(), release_reason = p_reason where id = h.id;
      return 'PENDING_SECOND_APPROVAL';
    elsif h.release_requested_by = auth.uid() then
      raise exception 'Drugo odobrenje mora dati drugi administrator (princip četiri oka).';
    end if;
  end if;
  update public.payout_holds set status = 'RELEASED', released_by = auth.uid(), released_at = now(), release_reason = coalesce(release_reason || ' | ', '') || p_reason where id = h.id;
  select * into o from public.orders where id = h.order_id for update;
  update public.orders set
    payout_status = case when payout_status = 'PAYOUT_HOLD' then case when cod_status = 'COLLECTED' then 'REMITTANCE_PENDING' else 'NOT_DUE' end else payout_status end,
    status = case when status = 'DISPUTED' then 'DELIVERED' else status end,
    expected_payout_date = case when cod_status = 'COLLECTED' and payout_status = 'PAYOUT_HOLD' then public._next_payout_date(now()) else expected_payout_date end
   where id = o.id;
  update public.complaints set status = 'RESOLVED_SELLER', resolution = p_reason, resolved_by = auth.uid(), resolved_at = now()
   where id = h.complaint_id and status in ('OPEN','UNDER_REVIEW');
  insert into public.outbox (topic, idempotency_key, payload, status)
  values ('BEX_HOLD_RELEASE', 'release:' || h.id, jsonb_build_object('order_id', h.order_id, 'hold_id', h.id),
          case when public.cfg_bool('sandbox_mode') then 'SANDBOX_DONE' else 'PENDING' end)
  on conflict (idempotency_key) do nothing;
  perform public._notify(o.seller_id, 'Isplata je odblokirana', o.order_no || ': isplata nastavlja prema BEX roku.', '#/narudzbina/' || o.id);
  perform public._notify(o.buyer_id, 'Reklamacija je rešena', o.order_no || ': ' || p_reason, '#/narudzbina/' || o.id);
  return 'RELEASED';
end $$;

create or replace function public.admin_release_hold(p_hold_id uuid, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ begin
  perform public.require_perm('release_hold');
  return jsonb_build_object('ok', true, 'result', public._release_hold(p_hold_id, p_reason));
end $$;

create or replace function public.admin_resolve_complaint(p_complaint_id uuid, p_outcome text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare c public.complaints; h public.payout_holds; v text;
begin
  perform public.require_perm('resolve_complaints');
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Obrazloženje mora imati najmanje 10 znakova.'; end if;
  select * into c from public.complaints where id = p_complaint_id for update;
  if not found or c.status not in ('OPEN','UNDER_REVIEW') then raise exception 'Reklamacija nije otvorena.'; end if;
  select * into h from public.payout_holds where complaint_id = c.id and status in ('ACTIVE','RELEASE_REQUESTED');
  perform public._set_reason(p_reason);
  if p_outcome = 'SELLER' then
    if h.id is null then
      update public.complaints set status = 'RESOLVED_SELLER', resolution = p_reason, resolved_by = auth.uid(), resolved_at = now() where id = c.id;
      update public.orders set status = case when payout_status = 'PAID' then 'COMPLETED' else status end where id = c.order_id and status = 'MANUAL_REVIEW';
      return jsonb_build_object('ok', true, 'result', 'RESOLVED');
    end if;
    perform public.require_perm('release_hold');
    v := public._release_hold(h.id, p_reason);
    if v = 'PENDING_SECOND_APPROVAL' then update public.complaints set status = 'UNDER_REVIEW' where id = c.id; end if;
    return jsonb_build_object('ok', true, 'result', v);
  elsif p_outcome = 'BUYER' then
    update public.complaints set status = 'RESOLVED_BUYER', resolution = p_reason, resolved_by = auth.uid(), resolved_at = now() where id = c.id;
    update public.payout_holds set status = 'CONVERTED_REFUND' where id = h.id;
    update public.orders set status = 'RETURN_REQUIRED' where id = c.order_id;
    perform public._recon(c.order_id, 'RETURN_AND_COD_REFUND_REQUIRED', jsonb_build_object('complaint_id', c.id, 'note', 'Povrat robe preko BEX-a i povraćaj pouzeća — ručni postupak do Faze 2'));
    perform public._notify(c.buyer_id, 'Reklamacija je usvojena', 'eBex podrška te kontaktira u aplikaciji radi BEX povrata robe.', '#/narudzbina/' || c.order_id);
    perform public._notify((select seller_id from public.orders where id = c.order_id), 'Reklamacija je usvojena', 'Isplata ostaje zadržana; sledi povrat robe preko BEX-a.', '#/narudzbina/' || c.order_id);
    return jsonb_build_object('ok', true, 'result', 'RESOLVED_BUYER');
  end if;
  raise exception 'Nepoznat ishod.';
end $$;

create or replace function public.admin_set_identity(p_user_id uuid, p_status text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ begin
  perform public.require_perm('verify_identity');
  if p_status not in ('VERIFIED','REJECTED','PENDING') then raise exception 'Nepoznat status.'; end if;
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Upiši kako je identitet proveren.'; end if;
  perform public._set_reason(p_reason);
  update public.profile_private set identity_status = p_status where id = p_user_id;
  perform public.audit('identity_' || lower(p_status), 'profile_private', p_user_id::text, p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.audit(p_action text, p_entity text, p_entity_id text, p_reason text) returns void
language sql security definer set search_path = public as
$$ insert into public.audit_events (actor_id, actor_role, action, entity, entity_id, reason)
   values (auth.uid(), coalesce(public.admin_role(), 'user'), p_action, p_entity, p_entity_id, p_reason) $$;

create or replace function public.admin_verify_payout_account(p_account_id uuid, p_approve boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare a public.payout_accounts; pp public.profile_private;
begin
  perform public.require_perm('verify_accounts');
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Upiši obrazloženje provere.'; end if;
  select * into a from public.payout_accounts where id = p_account_id for update;
  if not found then raise exception 'Račun nije pronađen.'; end if;
  select * into pp from public.profile_private where id = a.user_id;
  if p_approve and public.f_name(a.holder_name) <> public.f_name(pp.full_name) then
    raise exception 'Vlasnik računa se ne poklapa sa imenom korisnika. Isplata trećem licu nije dozvoljena.';
  end if;
  perform public._set_reason(p_reason);
  update public.payout_accounts set status = case when p_approve then 'VERIFIED' else 'REJECTED' end,
         verified_by = auth.uid(), verified_at = now(), review_note = p_reason where id = a.id;
  perform public._notify(a.user_id, case when p_approve then 'Račun za isplatu je verifikovan' else 'Račun za isplatu nije prihvaćen' end, p_reason, '#/profil');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_set_user_status(p_user_id uuid, p_status text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ begin
  perform public.require_perm('suspend_users');
  if p_status not in ('ACTIVE','SUSPENDED') then raise exception 'Nepoznat status.'; end if;
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Obrazloženje mora imati najmanje 10 znakova.'; end if;
  perform public._set_reason(p_reason);
  update public.profiles set status = p_status where id = p_user_id;
  perform public.audit('user_' || lower(p_status), 'profiles', p_user_id::text, p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_set_config(p_key text, p_value jsonb, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare c public.app_config;
begin
  perform public.require_perm('manage_config');
  select * into c from public.app_config where key = p_key for update;
  if not found then raise exception 'Nepoznat parametar.'; end if;
  if c.locked then raise exception 'Zaključana poslovna odluka. Menja se samo uz saglasnost vlasnika proizvoda, izmenom SQL-a.'; end if;
  if jsonb_typeof(p_value) is distinct from jsonb_typeof(c.value) then raise exception 'Vrednost mora biti istog tipa (%).', jsonb_typeof(c.value); end if;
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Upiši razlog izmene.'; end if;
  perform public._set_reason(p_reason);
  update public.app_config set value = p_value where key = p_key;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_set_category(p_id text, p_active boolean, p_requires_review boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare c public.categories;
begin
  perform public.require_perm('manage_config');
  select * into c from public.categories where id = p_id for update;
  if not found then raise exception 'Kategorija nije pronađena.'; end if;
  if p_active and c.feature_flag is not null and not public.cfg_bool(c.feature_flag) then
    raise exception 'Kategorija je isključena zaključanom poslovnom odlukom (%).', c.feature_flag;
  end if;
  perform public._set_reason(p_reason);
  update public.categories set is_active = p_active, requires_review = p_requires_review where id = p_id;
  perform public.audit('category_update', 'categories', p_id, p_reason);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_set_role(p_email text, p_role text, p_active boolean) returns jsonb
language plpgsql security definer set search_path = public as
$$ declare v_uid uuid;
begin
  perform public.require_perm('manage_admins');
  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));
  if v_uid is null then raise exception 'Korisnik sa tom e-adresom ne postoji. Neka se prvo registruje u aplikaciji.'; end if;
  if v_uid = auth.uid() and (not p_active or p_role <> 'super_admin') then raise exception 'Ne možeš sebi ukloniti ulogu glavnog administratora.'; end if;
  insert into public.admin_users (user_id, role, active) values (v_uid, p_role, p_active)
  on conflict (user_id) do update set role = excluded.role, active = excluded.active;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_expire_overdue_orders() returns jsonb
language plpgsql security definer set search_path = public as
$$ declare r record; n integer := 0;
begin
  perform public.require_perm('run_jobs');
  for r in select o.* from public.orders o
            where o.status = 'AWAITING_SHIPMENT' and o.handover_deadline < now()
              and not exists (select 1 from public.shipments s where s.order_id = o.id) for update loop
    update public.orders set status = 'SHIPMENT_EXPIRED', cod_status = 'CANCELLED', cancel_reason = 'Prodavac nije predao pošiljku u roku' where id = r.id;
    update public.listings set status = 'ACTIVE' where id = r.listing_id and status = 'RESERVED';
    perform public._risk(r.seller_id, 'HANDOVER_MISSED', 'order', r.id::text, '{}'::jsonb);
    perform public._notify(r.buyer_id, 'Porudžbina ' || r.order_no || ' je otkazana', 'Prodavac nije predao pošiljku u roku. Ništa nisi platio.', '#/narudzbina/' || r.id);
    perform public._notify(r.seller_id, 'Porudžbina ' || r.order_no || ' je istekla', 'Pošiljka nije predata u roku.', '#/narudzbina/' || r.id);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'expired', n);
end $$;

create or replace function public.admin_resolve_reconciliation(p_id bigint, p_note text) returns jsonb
language plpgsql security definer set search_path = public as
$$ begin
  perform public.require_perm('reconcile');
  if length(coalesce(trim(p_note), '')) < 10 then raise exception 'Upiši kako je slučaj usaglašen (najmanje 10 znakova).'; end if;
  perform public._set_reason(p_note);
  update public.reconciliation_cases set status = 'RESOLVED', note = p_note, resolved_by = auth.uid(), resolved_at = now() where id = p_id and status = 'OPEN';
  perform public.audit('reconciliation_resolved', 'reconciliation_cases', p_id::text, p_note);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_list_users(p_q text default null) returns table
  (id uuid, email text, display_name text, full_name text, phone text, phone_verified boolean, identity_status text,
   status text, created_at timestamptz, payout_id uuid, payout_account text, payout_holder text, payout_status text, payout_flags text[], risk_count bigint)
language plpgsql stable security definer set search_path = public as
$$ begin
  perform public.require_perm('view_users');
  return query
  select p.id, u.email::text, p.display_name, pp.full_name, public.mask_phone(pp.phone), pp.phone_verified_at is not null, pp.identity_status,
         p.status, p.created_at, pa.id, pa.account_number, pa.holder_name, pa.status, pa.flags,
         (select count(*) from public.risk_signals r where r.user_id = p.id)
    from public.profiles p join public.profile_private pp on pp.id = p.id join auth.users u on u.id = p.id
    left join lateral (select * from public.payout_accounts x where x.user_id = p.id and x.is_current order by x.created_at desc limit 1) pa on true
   where p_q is null or p_q = '' or u.email ilike '%' || p_q || '%' or p.display_name ilike '%' || p_q || '%' or pp.full_name ilike '%' || p_q || '%'
   order by (pa.status in ('PENDING','REVIEW')) desc nulls last, p.created_at desc
   limit 200;
end $$;

create or replace function public.admin_dashboard() returns jsonb
language plpgsql stable security definer set search_path = public as
$$ begin
  perform public.require_perm('view_dashboard');
  return jsonb_build_object(
    'users', (select count(*) from public.profiles),
    'users_phone_verified', (select count(*) from public.profile_private where phone_verified_at is not null),
    'listings', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from public.listings group by status) x),
    'orders', (select coalesce(jsonb_object_agg(status, n), '{}'::jsonb) from (select status, count(*) n from public.orders group by status) x),
    'payout', (select coalesce(jsonb_object_agg(payout_status, n), '{}'::jsonb) from (select payout_status, count(*) n from public.orders group by payout_status) x),
    'gmv_para', (select coalesce(sum(item_price_para), 0) from public.orders where cod_status = 'COLLECTED'),
    'shipping_para', (select coalesce(sum(shipping_para), 0) from public.orders where cod_status = 'COLLECTED'),
    'pending_payout_para', (select coalesce(sum(seller_net_para), 0) from public.orders where payout_status in ('REMITTANCE_PENDING','PAYOUT_HOLD')),
    'holds_active', (select count(*) from public.payout_holds where status in ('ACTIVE','RELEASE_REQUESTED')),
    'review_queue', (select count(*) from public.listings where status = 'PENDING_REVIEW'),
    'recon_open', (select count(*) from public.reconciliation_cases where status = 'OPEN'),
    'accounts_to_verify', (select count(*) from public.payout_accounts where is_current and status in ('PENDING','REVIEW')),
    'ledger_balance_para', (select coalesce(sum(amount_para), 0) from public.ledger_entries),
    'risk_24h', (select count(*) from public.risk_signals where created_at > now() - interval '1 day'));
end $$;

-- ---------------------------------------------------------------------
-- 16. Row Level Security (čitanje); sav upis ide isključivo kroz funkcije iznad
-- ---------------------------------------------------------------------
do $$ declare t text;
begin
  foreach t in array array['app_config','role_permissions','admin_users','audit_events','profiles','profile_private','consents','phone_otps',
    'payout_accounts','rate_events','risk_signals','notifications','data_requests','categories','listings','listing_media','listing_moderation',
    'conversations','offers','messages','orders','order_delivery','shipments','bex_events','outbox','packing_evidence','complaints',
    'payout_holds','ledger_entries','reconciliation_cases'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke insert, update, delete, truncate, references, trigger on public.%I from anon, authenticated', t);
  end loop;
end $$;

drop policy if exists p_read on public.app_config;
create policy p_read on public.app_config for select using (is_public or public.has_perm('manage_config'));
drop policy if exists p_read on public.role_permissions;
create policy p_read on public.role_permissions for select to authenticated using (true);
drop policy if exists p_read on public.admin_users;
create policy p_read on public.admin_users for select to authenticated using (user_id = auth.uid() or public.has_perm('manage_admins'));
drop policy if exists p_read on public.audit_events;
create policy p_read on public.audit_events for select to authenticated using (public.has_perm('view_audit'));
drop policy if exists p_read on public.profiles;
create policy p_read on public.profiles for select using (true);
drop policy if exists p_read on public.profile_private;
create policy p_read on public.profile_private for select to authenticated using (id = auth.uid() or public.has_perm('view_users'));
drop policy if exists p_read on public.consents;
create policy p_read on public.consents for select to authenticated using (user_id = auth.uid() or public.has_perm('view_users'));
drop policy if exists p_read on public.payout_accounts;
create policy p_read on public.payout_accounts for select to authenticated using (user_id = auth.uid() or public.has_perm('verify_accounts') or public.has_perm('view_finance'));
drop policy if exists p_read on public.risk_signals;
create policy p_read on public.risk_signals for select to authenticated using (public.has_perm('view_risk'));
drop policy if exists p_read on public.notifications;
create policy p_read on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists p_read on public.data_requests;
create policy p_read on public.data_requests for select to authenticated using (user_id = auth.uid() or public.has_perm('view_data_requests'));
drop policy if exists p_read on public.categories;
create policy p_read on public.categories for select using (true);
drop policy if exists p_read on public.listings;
create policy p_read on public.listings for select using (
  status in ('ACTIVE','RESERVED','SOLD') or seller_id = auth.uid() or public.has_perm('view_listings_all') or public.has_perm('moderate_listings'));
drop policy if exists p_read on public.listing_media;
create policy p_read on public.listing_media for select using (exists (select 1 from public.listings l where l.id = listing_id));
drop policy if exists p_read on public.listing_moderation;
create policy p_read on public.listing_moderation for select to authenticated using (
  public.has_perm('moderate_listings') or exists (select 1 from public.listings l where l.id = listing_id and l.seller_id = auth.uid()));
drop policy if exists p_read on public.conversations;
create policy p_read on public.conversations for select to authenticated using (auth.uid() in (buyer_id, seller_id) or public.has_perm('moderate_chat'));
drop policy if exists p_read on public.offers;
create policy p_read on public.offers for select to authenticated using (auth.uid() in (from_user, to_user) or public.has_perm('moderate_chat'));
drop policy if exists p_read on public.messages;
create policy p_read on public.messages for select to authenticated using (
  public.has_perm('moderate_chat') or exists (select 1 from public.conversations c where c.id = conversation_id and auth.uid() in (c.buyer_id, c.seller_id)
                                              and (not blocked or sender_id = auth.uid())));
drop policy if exists p_read on public.orders;
create policy p_read on public.orders for select to authenticated using (auth.uid() in (buyer_id, seller_id) or public.has_perm('view_orders'));
drop policy if exists p_read on public.order_delivery;
create policy p_read on public.order_delivery for select to authenticated using (
  public.has_perm('view_delivery') or exists (select 1 from public.orders o where o.id = order_id and o.buyer_id = auth.uid()));
drop policy if exists p_read on public.shipments;
create policy p_read on public.shipments for select to authenticated using (exists (select 1 from public.orders o where o.id = order_id));
drop policy if exists p_read on public.bex_events;
create policy p_read on public.bex_events for select to authenticated using (public.has_perm('view_orders'));
drop policy if exists p_read on public.outbox;
create policy p_read on public.outbox for select to authenticated using (public.has_perm('view_delivery'));
drop policy if exists p_read on public.packing_evidence;
create policy p_read on public.packing_evidence for select to authenticated using (uploader_id = auth.uid() or public.has_perm('view_evidence'));
drop policy if exists p_read on public.complaints;
create policy p_read on public.complaints for select to authenticated using (
  public.has_perm('view_orders') or exists (select 1 from public.orders o where o.id = order_id and auth.uid() in (o.buyer_id, o.seller_id)));
drop policy if exists p_read on public.payout_holds;
create policy p_read on public.payout_holds for select to authenticated using (
  public.has_perm('view_orders') or exists (select 1 from public.orders o where o.id = order_id and auth.uid() in (o.buyer_id, o.seller_id)));
drop policy if exists p_read on public.ledger_entries;
create policy p_read on public.ledger_entries for select to authenticated using (public.has_perm('view_finance'));
drop policy if exists p_read on public.reconciliation_cases;
create policy p_read on public.reconciliation_cases for select to authenticated using (public.has_perm('reconcile') or public.has_perm('view_finance'));

-- ---------------------------------------------------------------------
-- 17. Skladište datoteka (fotografije oglasa javne, dokazi privatni)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('listing-media', 'listing-media', true, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('evidence', 'evidence', false, 52428800, array['image/jpeg','image/png','image/webp','video/mp4','video/quicktime','video/webm'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists ebex_media_insert on storage.objects;
create policy ebex_media_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'listing-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists ebex_media_delete on storage.objects;
create policy ebex_media_delete on storage.objects for delete to authenticated
  using (bucket_id = 'listing-media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists ebex_evidence_insert on storage.objects;
create policy ebex_evidence_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'evidence' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists ebex_evidence_read on storage.objects;
create policy ebex_evidence_read on storage.objects for select to authenticated
  using (bucket_id = 'evidence' and ((storage.foldername(name))[1] = auth.uid()::text or public.has_perm('view_evidence')));

-- ---------------------------------------------------------------------
-- 18. Prava izvršavanja funkcija (najmanja potrebna)
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.has_perm(text), public.admin_mfa_ok(), public.admin_role(), public.cfg_bool(text) to anon, authenticated;
grant execute on function public.search_listings(text, text, numeric, numeric, text, text, text, integer, integer), public.get_shipping_quote(uuid) to anon, authenticated;
grant execute on function
  public.accept_terms(text, text, boolean, boolean), public.update_profile(jsonb), public.request_phone_otp(text), public.verify_phone_otp(text),
  public.add_payout_account(text, text), public.create_data_request(text, text), public.mark_notifications_read(), public.my_status(),
  public.save_listing(uuid, jsonb), public.set_listing_media(uuid, text[]), public.publish_listing(uuid), public.set_listing_status(uuid, text),
  public.start_conversation(uuid), public.send_message(uuid, text), public.make_offer(uuid, numeric), public.respond_offer(uuid, boolean),
  public.place_order(uuid, jsonb, boolean), public.cancel_order(uuid, text), public.add_packing_evidence(uuid, text, text, text, bigint),
  public.mark_ready_for_pickup(uuid), public.open_complaint(uuid, text, text),
  public.admin_whoami(), public.admin_moderate_listing(uuid, text, text), public.admin_bex_event(uuid, text, text), public.admin_sim_due_payouts(),
  public.admin_place_hold(uuid, text), public.admin_release_hold(uuid, text), public.admin_resolve_complaint(uuid, text, text),
  public.admin_set_identity(uuid, text, text), public.admin_verify_payout_account(uuid, boolean, text), public.admin_set_user_status(uuid, text, text),
  public.admin_set_config(text, jsonb, text), public.admin_set_category(text, boolean, boolean, text), public.admin_set_role(text, text, boolean),
  public.admin_expire_overdue_orders(), public.admin_resolve_reconciliation(bigint, text), public.admin_list_users(text), public.admin_dashboard()
to authenticated;
-- process_bex_event NIJE dostupna korisnicima; poziva je samo administratorski simulator ili budući BEX webhook (service_role).
grant execute on function public.process_bex_event(text, text, text, timestamptz, jsonb, text) to service_role;

-- ---------------------------------------------------------------------
-- 19. Realtime za chat i obaveštenja
-- ---------------------------------------------------------------------
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end;
    begin alter publication supabase_realtime add table public.notifications; exception when duplicate_object then null; end;
  end if;
end $$;

commit;
-- Kraj. Ako vidiš "Success. No rows returned", šema je spremna.
