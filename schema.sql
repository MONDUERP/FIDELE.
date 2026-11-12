-- ============================================================
-- Fidèle — schéma Supabase
-- À coller en une fois dans : Supabase > SQL Editor > New query > Run
-- ============================================================

-- ---------- Tables ----------

create table public.restaurants (
  id          uuid primary key default gen_random_uuid(),
  slug        text unique not null check (slug ~ '^[a-z0-9-]+$'),
  name        text not null,
  prefix      text not null check (prefix ~ '^[A-Z]{2,4}$'),
  goal        int  not null default 10 check (goal between 2 and 20),
  reward      text not null default 'Une pizza offerte',
  color       text not null default '#B23A2B' check (color ~ '^#[0-9A-Fa-f]{6}$'),
  created_at  timestamptz not null default now()
);

-- Qui a le droit de scanner / gérer quel restaurant
create table public.staff (
  user_id        uuid not null references auth.users(id) on delete cascade,
  restaurant_id  uuid not null references public.restaurants(id) on delete cascade,
  role           text not null default 'serveur' check (role in ('gerant','serveur')),
  primary key (user_id, restaurant_id)
);

create table public.cards (
  id             uuid primary key default gen_random_uuid(),
  restaurant_id  uuid not null references public.restaurants(id) on delete cascade,
  token          uuid not null unique default gen_random_uuid(), -- secret : dans le QR et le lien du client
  code           text not null unique,                           -- court : saisie manuelle par le serveur
  first_name     text not null,
  phone          text not null,
  stamps         int  not null default 0,
  rewards        int  not null default 0,
  total_stamps   int  not null default 0,
  last_stamp_at  timestamptz,
  created_at     timestamptz not null default now(),
  unique (restaurant_id, phone)
);
create index cards_restaurant_idx on public.cards (restaurant_id);

create table public.events (
  id             bigint generated always as identity primary key,
  restaurant_id  uuid not null references public.restaurants(id) on delete cascade,
  card_id        uuid not null references public.cards(id) on delete cascade,
  type           text not null check (type in ('stamp','reward_earned','reward_used')),
  by_user        uuid,
  created_at     timestamptz not null default now()
);
create index events_restaurant_idx on public.events (restaurant_id, created_at desc);

-- ---------- Sécurité : tout est fermé par défaut ----------

alter table public.restaurants enable row level security;
alter table public.staff       enable row level security;
alter table public.cards       enable row level security;
alter table public.events      enable row level security;

revoke all on public.restaurants, public.staff, public.cards, public.events from anon, authenticated;

-- Le staff connecté peut LIRE les données de ses restaurants. Rien d'autre.
grant select on public.restaurants, public.staff, public.cards, public.events to authenticated;
-- Le gérant peut modifier le programme (pas le slug ni le préfixe).
grant update (name, goal, reward, color) on public.restaurants to authenticated;

create function public.is_staff(rid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff s where s.user_id = auth.uid() and s.restaurant_id = rid)
$$;

create function public.is_manager(rid uuid) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff s
                 where s.user_id = auth.uid() and s.restaurant_id = rid and s.role = 'gerant')
$$;

create policy staff_self   on public.staff       for select to authenticated using (user_id = (select auth.uid()));
create policy resto_read   on public.restaurants for select to authenticated using (public.is_staff(id));
create policy resto_update on public.restaurants for update to authenticated
  using (public.is_manager(id)) with check (public.is_manager(id));
create policy cards_read   on public.cards       for select to authenticated using (public.is_staff(restaurant_id));
create policy events_read  on public.events      for select to authenticated using (public.is_staff(restaurant_id));

-- ---------- Fonctions publiques (client, sans compte) ----------

-- Infos d'affichage d'un restaurant
create function public.resto_public(p_slug text) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object('name', r.name, 'goal', r.goal, 'reward', r.reward, 'color', r.color)
  from public.restaurants r where r.slug = p_slug
$$;

-- Inscription d'un client : renvoie le token secret de sa carte
create function public.signup(p_slug text, p_first_name text, p_phone text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  r        public.restaurants;
  v_name   text := btrim(coalesce(p_first_name, ''));
  v_phone  text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_code   text;
  v_token  uuid;
  i        int := 0;
begin
  select * into r from public.restaurants where slug = p_slug;
  if not found then return json_build_object('error', 'resto_inconnu'); end if;
  if char_length(v_name) < 1 or char_length(v_name) > 40 then
    return json_build_object('error', 'prenom_invalide');
  end if;
  if char_length(v_phone) < 9 or char_length(v_phone) > 15 then
    return json_build_object('error', 'telephone_invalide');
  end if;
  if exists (select 1 from public.cards c where c.restaurant_id = r.id and c.phone = v_phone) then
    return json_build_object('error', 'deja_inscrit');
  end if;

  loop
    v_code := r.prefix || '-' || lpad(floor(random() * 100000)::int::text, 5, '0');
    begin
      insert into public.cards (restaurant_id, code, first_name, phone)
      values (r.id, v_code, v_name, v_phone)
      returning token into v_token;
      exit;
    exception when unique_violation then
      i := i + 1;
      if i > 20 then return json_build_object('error', 'reessayer'); end if;
    end;
  end loop;

  return json_build_object('token', v_token);
end $$;

-- Lecture d'une carte par son token secret
create function public.card_view(p_token uuid) returns json
language sql stable security definer set search_path = '' as $$
  select json_build_object(
    'first_name', c.first_name, 'code', c.code, 'stamps', c.stamps, 'rewards', c.rewards,
    'resto', json_build_object('name', r.name, 'goal', r.goal, 'reward', r.reward, 'color', r.color))
  from public.cards c join public.restaurants r on r.id = c.restaurant_id
  where c.token = p_token
$$;

-- ---------- Fonctions staff (compte obligatoire) ----------

-- +1 tampon. p_scan = contenu du QR (token) ou code court tapé à la main.
create function public.add_stamp(p_scan text) returns json
language plpgsql security definer set search_path = '' as $$
declare
  c        public.cards;
  r        public.restaurants;
  v_token  uuid;
  v_won    boolean := false;
begin
  if auth.uid() is null then return json_build_object('error', 'non_connecte'); end if;

  begin
    v_token := btrim(p_scan)::uuid;
  exception when others then
    v_token := null;
  end;

  select * into c from public.cards k
   where ((v_token is not null and k.token = v_token) or k.code = upper(btrim(p_scan)))
     and public.is_staff(k.restaurant_id)
   for update;
  if not found then return json_build_object('error', 'carte_inconnue'); end if;

  select * into r from public.restaurants where id = c.restaurant_id;

  -- Anti double-scan : 1 tampon max par minute et par carte
  if c.last_stamp_at is not null and c.last_stamp_at > now() - interval '60 seconds' then
    return json_build_object('error', 'deja_scanne', 'goal', r.goal, 'reward', r.reward,
      'card', json_build_object('id', c.id, 'first_name', c.first_name, 'code', c.code,
                                'stamps', c.stamps, 'rewards', c.rewards, 'token', c.token));
  end if;

  c.stamps := c.stamps + 1;
  if c.stamps >= r.goal then
    c.stamps  := 0;
    c.rewards := c.rewards + 1;
    v_won     := true;
  end if;

  update public.cards
     set stamps = c.stamps, rewards = c.rewards,
         total_stamps = total_stamps + 1, last_stamp_at = now()
   where id = c.id;

  insert into public.events (restaurant_id, card_id, type, by_user)
  values (c.restaurant_id, c.id, 'stamp', auth.uid());
  if v_won then
    insert into public.events (restaurant_id, card_id, type, by_user)
    values (c.restaurant_id, c.id, 'reward_earned', auth.uid());
  end if;

  return json_build_object('ok', true, 'won', v_won, 'goal', r.goal, 'reward', r.reward,
    'card', json_build_object('id', c.id, 'first_name', c.first_name, 'code', c.code,
                              'stamps', c.stamps, 'rewards', c.rewards, 'token', c.token));
end $$;

-- Utiliser une récompense
create function public.redeem(p_card_id uuid) returns json
language plpgsql security definer set search_path = '' as $$
declare
  c public.cards;
begin
  if auth.uid() is null then return json_build_object('error', 'non_connecte'); end if;

  select * into c from public.cards k
   where k.id = p_card_id and public.is_staff(k.restaurant_id)
   for update;
  if not found then return json_build_object('error', 'carte_inconnue'); end if;
  if c.rewards < 1 then return json_build_object('error', 'aucune_recompense'); end if;

  update public.cards set rewards = rewards - 1 where id = c.id;
  insert into public.events (restaurant_id, card_id, type, by_user)
  values (c.restaurant_id, c.id, 'reward_used', auth.uid());

  return json_build_object('ok', true,
    'card', json_build_object('id', c.id, 'first_name', c.first_name, 'code', c.code,
                              'stamps', c.stamps, 'rewards', c.rewards - 1, 'token', c.token));
end $$;

-- ---------- Droits d'exécution ----------

revoke execute on function
  public.is_staff(uuid), public.is_manager(uuid),
  public.resto_public(text), public.signup(text, text, text), public.card_view(uuid),
  public.add_stamp(text), public.redeem(uuid)
from public, anon, authenticated;

grant execute on function public.resto_public(text), public.signup(text, text, text), public.card_view(uuid)
  to anon, authenticated;
grant execute on function public.is_staff(uuid), public.is_manager(uuid), public.add_stamp(text), public.redeem(uuid)
  to authenticated;

-- ---------- Premier restaurant ----------

insert into public.restaurants (slug, name, prefix, goal, reward, color)
values ('casa-di-meco', 'Casa Di Meco', 'CDM', 10, 'Une pizza offerte', '#B23A2B');
