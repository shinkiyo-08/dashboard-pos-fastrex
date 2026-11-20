-- Fastrex POS: Supabase setup
-- Jalankan seluruh file ini sekali di Supabase SQL Editor.
-- Penyimpanan memakai satu dokumen JSONB dengan optimistic locking.
-- Kasir membaca versi yang sudah disanitasi; HPP, biaya, pengeluaran, dan settings
-- tidak dikirim ke browser kasir. Update realtime hanya mengirim versi + user ID.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  store_id uuid not null default 'f45e0000-0000-4000-8000-000000000001',
  role text not null check (role in ('admin','cashier')),
  display_name text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.app_state (
  id integer primary key check (id = 1),
  store_id uuid not null default 'f45e0000-0000-4000-8000-000000000001',
  state jsonb not null,
  version bigint not null default 1,
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

-- Database awal kosong: tidak ada produk, bahan, nota, atau pengeluaran demo.
insert into public.app_state (id, store_id, state)
values (
  1,
  'f45e0000-0000-4000-8000-000000000001',
  '{"demo":false,"set":{"name":"Fastrex Advertising & Akrilik","addr":"Alamat usaha Anda","wa":"08xx-xxxx-xxxx","terms":"Periksa cetakan sebelum dibawa pulang. Komplain maks. 1x24 jam dengan nota ini."},"mats":[],"prods":[],"notas":[],"exp":[]}'::jsonb
)
on conflict (id) do nothing;

alter table public.profiles enable row level security;
alter table public.app_state enable row level security;

-- Pengguna hanya boleh membaca profilnya sendiri.
drop policy if exists "profile_select_self" on public.profiles;
create policy "profile_select_self" on public.profiles
for select to authenticated
using (id = auth.uid());

grant select on public.profiles to authenticated;
-- Tidak ada akses baca/tulis langsung ke dokumen state. Semua lewat RPC.
revoke all on public.app_state from anon, authenticated;

create or replace function public.load_fastrex_state()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_row public.app_state%rowtype;
  v_role text;
  v_store uuid;
  v_safe jsonb;
  v_mats jsonb;
  v_prods jsonb;
  v_notes jsonb;
  v_note jsonb;
  v_item jsonb;
  v_items jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select role, store_id into v_role, v_store from public.profiles where id = auth.uid();
  if v_role is null then
    raise exception 'Fastrex profile not found' using errcode = '42501';
  end if;
  select * into v_row from public.app_state where id = 1 and store_id = v_store;
  if not found then raise exception 'Store state not found' using errcode = 'P0002'; end if;

  if v_role = 'admin' then
    v_safe := v_row.state;
  else
    -- Kasir tidak menerima biaya bahan, biaya tambahan produk, pengeluaran,
    -- maupun nilai HPP per item nota.
    select coalesce(jsonb_agg(value - 'cost' order by value->>'id'), '[]'::jsonb)
      into v_mats from jsonb_array_elements(v_row.state->'mats');
    select coalesce(jsonb_agg(value - 'other' order by value->>'id'), '[]'::jsonb)
      into v_prods from jsonb_array_elements(v_row.state->'prods');
    v_notes := '[]'::jsonb;
    for v_note in select value from jsonb_array_elements(v_row.state->'notas') loop
      v_items := '[]'::jsonb;
      for v_item in select value from jsonb_array_elements(coalesce(v_note->'items','[]'::jsonb)) loop
        v_items := v_items || jsonb_build_array(v_item - 'hpp');
      end loop;
      v_notes := v_notes || jsonb_build_array(v_note || jsonb_build_object('items',v_items));
    end loop;
    v_safe := v_row.state || jsonb_build_object(
      'mats',v_mats,'prods',v_prods,'notas',v_notes,'exp','[]'::jsonb
    );
  end if;
  return jsonb_build_object('state',v_safe,'version',v_row.version);
end;
$$;
revoke all on function public.load_fastrex_state() from public;
grant execute on function public.load_fastrex_state() to authenticated;

create or replace function public.save_fastrex_state(
  p_state jsonb,
  p_expected_version bigint
)
returns bigint
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_row public.app_state%rowtype;
  v_role text;
  v_store uuid;
  v_next_version bigint;
  v_new_mats jsonb;
  v_old_mats jsonb;
  v_new_prods jsonb;
  v_old_prods jsonb;
  v_merged_mats jsonb;
  v_notes jsonb;
  v_note jsonb;
  v_item jsonb;
  v_items jsonb;
  v_prod jsonb;
  v_mat jsonb;
  v_base numeric;
  v_hpp_unit numeric;
  v_hpp bigint;
  v_cost numeric;
  v_use numeric;
  v_other numeric;
  v_merged_state jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;
  select role, store_id into v_role, v_store from public.profiles where id = auth.uid();
  if v_role is null then raise exception 'Fastrex profile not found' using errcode = '42501'; end if;

  select * into v_row from public.app_state where id = 1 and store_id = v_store for update;
  if not found then raise exception 'Store state not found' using errcode = 'P0002'; end if;
  if v_row.version <> p_expected_version then
    raise exception 'Data changed by another device. Reload and retry.' using errcode = '40001';
  end if;

  if jsonb_typeof(p_state) <> 'object'
     or jsonb_typeof(p_state->'mats') <> 'array'
     or jsonb_typeof(p_state->'prods') <> 'array'
     or jsonb_typeof(p_state->'notas') <> 'array'
     or jsonb_typeof(p_state->'exp') <> 'array'
     or jsonb_typeof(p_state->'set') <> 'object' then
    raise exception 'Invalid Fastrex state structure' using errcode = '22023';
  end if;

  if v_role = 'admin' then
    v_merged_state := p_state;
  else
    -- Kasir hanya dapat mengubah nota dan stok. Data sensitif diambil kembali
    -- dari versi database, bukan dipercaya dari browser.
    if (p_state - 'notas' - 'mats' - 'prods' - 'exp' - 'cust') is distinct from
       (v_row.state - 'notas' - 'mats' - 'prods' - 'exp' - 'cust') then
      raise exception 'Cashier role cannot edit store settings' using errcode = '42501';
    end if;
    if coalesce(p_state->'exp','[]'::jsonb) <> '[]'::jsonb then
      raise exception 'Cashier role cannot edit expenses' using errcode = '42501';
    end if;

    select coalesce(jsonb_agg(value - 'stock' - 'cost' order by value->>'id'), '[]'::jsonb)
      into v_new_mats from jsonb_array_elements(p_state->'mats');
    select coalesce(jsonb_agg(value - 'stock' - 'cost' order by value->>'id'), '[]'::jsonb)
      into v_old_mats from jsonb_array_elements(v_row.state->'mats');
    if v_new_mats is distinct from v_old_mats then
      raise exception 'Cashier role cannot add, remove, or edit material details' using errcode = '42501';
    end if;

    select coalesce(jsonb_agg(value - 'other' order by value->>'id'), '[]'::jsonb)
      into v_new_prods from jsonb_array_elements(p_state->'prods');
    select coalesce(jsonb_agg(value - 'other' order by value->>'id'), '[]'::jsonb)
      into v_old_prods from jsonb_array_elements(v_row.state->'prods');
    if v_new_prods is distinct from v_old_prods then
      raise exception 'Cashier role cannot edit products or prices' using errcode = '42501';
    end if;

    select coalesce(jsonb_agg(old_m.value || jsonb_build_object('stock',new_m.value->'stock') order by old_m.value->>'id'),'[]'::jsonb)
      into v_merged_mats
      from jsonb_array_elements(v_row.state->'mats') old_m(value)
      join jsonb_array_elements(p_state->'mats') new_m(value)
        on old_m.value->>'id' = new_m.value->>'id';

    -- HPP dihitung ulang di server agar kasir tidak perlu menerima nilai biaya.
    v_notes := '[]'::jsonb;
    for v_note in select value from jsonb_array_elements(p_state->'notas') loop
      v_items := '[]'::jsonb;
      for v_item in select value from jsonb_array_elements(coalesce(v_note->'items','[]'::jsonb)) loop
        v_prod := null; v_mat := null;
        select value into v_prod from jsonb_array_elements(v_row.state->'prods') where value->>'id' = v_item->>'p' limit 1;
        if v_prod is not null then
          select value into v_mat from jsonb_array_elements(v_row.state->'mats') where value->>'id' = v_prod->>'mat' limit 1;
        end if;
        v_cost := coalesce((v_mat->>'cost')::numeric,0);
        v_use := coalesce((v_prod->>'use')::numeric,0);
        v_other := coalesce((v_prod->>'other')::numeric,0);
        v_hpp_unit := (v_cost * v_use / case when v_prod->>'type' = 'cm2' then 10000 else 1 end) + v_other;
        if v_item->>'type' in ('m2','cm2') then
          v_base := coalesce((v_item->>'l')::numeric,0) * coalesce((v_item->>'w')::numeric,0) * coalesce((v_item->>'q')::numeric,0);
        else
          v_base := coalesce((v_item->>'q')::numeric,0);
        end if;
        v_hpp := round(v_base * v_hpp_unit)::bigint;
        v_items := v_items || jsonb_build_array(v_item || jsonb_build_object('hpp',v_hpp));
      end loop;
      v_notes := v_notes || jsonb_build_array(v_note || jsonb_build_object('items',v_items));
    end loop;

    v_merged_state := v_row.state || jsonb_build_object(
      'mats',v_merged_mats,
      'notas',v_notes,
      'cust',coalesce(p_state->'cust',v_row.state->'cust','[]'::jsonb)
    );
  end if;

  v_next_version := v_row.version + 1;
  update public.app_state
  set state = v_merged_state,
      version = v_next_version,
      updated_by = auth.uid(),
      updated_at = now()
  where id = 1;
  return v_next_version;
end;
$$;
revoke all on function public.save_fastrex_state(jsonb, bigint) from public;
grant execute on function public.save_fastrex_state(jsonb, bigint) to authenticated;

-- Broadcast privat hanya berisi versi dan ID pengguna yang menyimpan, bukan isi data.
create or replace function public.broadcast_fastrex_state_change()
returns trigger
language plpgsql
security definer
set search_path = public, realtime
as $$
begin
  perform realtime.send(
    jsonb_build_object('version',new.version,'updated_by',new.updated_by),
    'state_changed',
    'fastrex:' || new.store_id::text,
    true
  );
  return new;
end;
$$;

drop trigger if exists fastrex_state_broadcast on public.app_state;
create trigger fastrex_state_broadcast
after update on public.app_state
for each row execute function public.broadcast_fastrex_state_change();

-- Izin menerima private broadcast hanya untuk anggota toko terkait.
drop policy if exists "fastrex_store_members_receive" on realtime.messages;
create policy "fastrex_store_members_receive" on realtime.messages
for select to authenticated
using (
  extension = 'broadcast'
  and topic = 'fastrex:' || (
    select p.store_id::text from public.profiles p where p.id = auth.uid()
  )
);
