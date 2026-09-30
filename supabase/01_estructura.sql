-- =====================================================================
-- Academia Técnica · Estructura de base de datos (Supabase)
-- Pegar completo en Supabase > SQL Editor > New query > Run.
-- Se puede volver a ejecutar sin romper nada.
-- =====================================================================

-- ---------- RUT: normalizar y validar dígito verificador ----------
-- Normaliza "12.345.678-k" -> "12345678-K"
create or replace function public.rut_normalizar(p_rut text)
returns text language sql immutable set search_path = '' as $$
  select case
    when length(regexp_replace(upper(coalesce(p_rut, '')), '[^0-9K]', '', 'g')) < 2 then null
    else left(regexp_replace(upper(p_rut), '[^0-9K]', '', 'g'), -1) || '-' ||
         right(regexp_replace(upper(p_rut), '[^0-9K]', '', 'g'), 1)
  end
$$;

create or replace function public.rut_valido(p_rut text)
returns boolean language plpgsql immutable set search_path = '' as $$
declare
  r text := public.rut_normalizar(p_rut);
  cuerpo text; dv text; suma int := 0; mult int := 2; i int; esperado text;
begin
  if r is null or r !~ '^[0-9]{6,8}-[0-9K]$' then return false; end if;
  cuerpo := split_part(r, '-', 1); dv := split_part(r, '-', 2);
  for i in reverse length(cuerpo)..1 loop
    suma := suma + substr(cuerpo, i, 1)::int * mult;
    mult := case when mult = 7 then 2 else mult + 1 end;
  end loop;
  esperado := case 11 - (suma % 11) when 11 then '0' when 10 then 'K' else (11 - (suma % 11))::text end;
  return dv = esperado;
end $$;

-- ---------- Tablas ----------
create table if not exists public.perfiles (
  id                 uuid primary key references auth.users(id) on delete cascade,
  rut                text not null unique check (public.rut_valido(rut)),
  nombre             text not null,
  zona               text,
  rol                text not null default 'tecnico' check (rol in ('tecnico', 'supervisor', 'admin')),
  debe_cambiar_clave boolean not null default true,
  creado_en          timestamptz not null default now()
);

create table if not exists public.avance (
  usuario_id     uuid primary key references public.perfiles(id) on delete cascade,
  lecciones      jsonb not null default '{}'::jsonb,   -- { "seg": ["epp","altura"], ... }
  evaluaciones   jsonb not null default '{}'::jsonb,   -- { "seg": { "enviada": "2026-09-30T..." }, ... }
  actualizado_en timestamptz not null default now()
);

-- ---------- Quién soy (usado por los permisos) ----------
create or replace function public.mi_rol()
returns text language sql stable security definer set search_path = '' as $$
  select rol from public.perfiles where id = auth.uid()
$$;

create or replace function public.mi_zona()
returns text language sql stable security definer set search_path = '' as $$
  select zona from public.perfiles where id = auth.uid()
$$;

-- ¿Puedo ver a este usuario? Yo mismo, un admin, o un supervisor de su misma zona.
create or replace function public.puedo_ver(p_usuario uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_usuario = auth.uid()
      or public.mi_rol() = 'admin'
      or (public.mi_rol() = 'supervisor'
          and exists (select 1 from public.perfiles p where p.id = p_usuario and p.zona is not distinct from public.mi_zona()))
$$;

-- ---------- Permisos (RLS): cada técnico ve solo lo suyo ----------
alter table public.perfiles enable row level security;
alter table public.avance   enable row level security;

drop policy if exists "ver perfiles" on public.perfiles;
create policy "ver perfiles" on public.perfiles
  for select to authenticated using (public.puedo_ver(id));

drop policy if exists "ver avance" on public.avance;
create policy "ver avance" on public.avance
  for select to authenticated using (public.puedo_ver(usuario_id));

drop policy if exists "crear mi avance" on public.avance;
create policy "crear mi avance" on public.avance
  for insert to authenticated with check (usuario_id = auth.uid());

drop policy if exists "actualizar mi avance" on public.avance;
create policy "actualizar mi avance" on public.avance
  for update to authenticated using (usuario_id = auth.uid()) with check (usuario_id = auth.uid());

-- Nadie sin sesión ve nada; los técnicos no pueden editar su perfil (ni su rol).
revoke all on public.perfiles, public.avance from anon, authenticated;
grant select on public.perfiles to authenticated;
grant select, insert, update on public.avance to authenticated;

-- ---------- Acciones que puede hacer el técnico ----------
-- Tras cambiar su contraseña, la página llama a esto para no volver a pedírsela.
create or replace function public.marcar_clave_cambiada()
returns void language sql security definer set search_path = '' as $$
  update public.perfiles set debe_cambiar_clave = false where id = auth.uid()
$$;
revoke all on function public.marcar_clave_cambiada() from public, anon;
grant execute on function public.marcar_clave_cambiada() to authenticated;

-- La página usa esto para convertir el RUT en el usuario interno de login.
grant execute on function public.rut_normalizar(text), public.rut_valido(text) to anon, authenticated;

-- ---------- Crear técnicos (solo desde el SQL Editor) ----------
-- Uso:  select public.crear_tecnico('12.345.678-5', 'Juan Pérez', 'RM Norte', 'ClaveInicial123');
--       select public.crear_tecnico('11.111.111-1', 'Ana Soto', null, 'OtraClave456', 'admin');
create or replace function public.crear_tecnico(
  p_rut text, p_nombre text, p_zona text, p_clave text, p_rol text default 'tecnico')
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_rut   text := public.rut_normalizar(p_rut);
  v_email text;
  v_id    uuid;
begin
  if not public.rut_valido(v_rut) then raise exception 'RUT inválido: %', p_rut; end if;
  if length(coalesce(p_clave, '')) < 8 then raise exception 'La clave de % debe tener al menos 8 caracteres', v_rut; end if;
  v_email := lower(v_rut) || '@tecnicos.academia.invalid';

  select id into v_id from auth.users where email = v_email;
  if v_id is null then
    v_id := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                            raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                            confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
            extensions.crypt(p_clave, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}', jsonb_build_object('rut', v_rut, 'nombre', p_nombre),
            now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_id, v_id::text,
            jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true),
            'email', now(), now(), now());
  else
    -- Ya existía: se restablece la clave y se vuelve a pedir cambio.
    update auth.users set encrypted_password = extensions.crypt(p_clave, extensions.gen_salt('bf')), updated_at = now()
     where id = v_id;
  end if;

  insert into public.perfiles (id, rut, nombre, zona, rol, debe_cambiar_clave)
  values (v_id, v_rut, p_nombre, p_zona, p_rol, true)
  on conflict (id) do update set nombre = excluded.nombre, zona = excluded.zona, rol = excluded.rol, debe_cambiar_clave = true;

  return v_rut || ' listo';
end $$;
revoke all on function public.crear_tecnico(text, text, text, text, text) from public, anon, authenticated;
