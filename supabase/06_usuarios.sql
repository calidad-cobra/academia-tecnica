-- =====================================================================
-- Academia Técnica · Crear y editar usuarios desde la pestaña "Usuarios" (solo administrador)
-- Pegar en Supabase > SQL Editor > Run. Se puede volver a ejecutar.
-- La clave inicial NO va aquí (el repositorio es público): se usa la de privado.config
-- (la misma de "Restablecer clave"). El usuario nuevo debe crear su clave al primer ingreso.
-- =====================================================================

-- Operación del usuario (Tigo / VTR). Sin operación = ve todos los cursos (admin, supervisor general).
alter table public.perfiles add column if not exists operacion text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'perfiles_operacion_check') then
    alter table public.perfiles add constraint perfiles_operacion_check check (operacion is null or operacion in ('tigo', 'vtr'));
  end if;
end $$;

-- Crea un usuario nuevo con la clave inicial. Si el RUT ya existe NO lo toca (devuelve 'existe').
-- Devuelve: 'creado' | 'existe'. Errores: RUT inválido, rol u operación no válidos, sin permiso.
create or replace function public.admin_crear_usuario(
  p_rut text, p_nombre text, p_operacion text default null, p_rol text default 'tecnico')
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_rut   text := public.rut_normalizar(p_rut);
  v_op    text := nullif(lower(trim(coalesce(p_operacion, ''))), '');
  v_rol   text := lower(trim(coalesce(p_rol, 'tecnico')));
  v_clave text;
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'No autorizado'; end if;
  if not public.rut_valido(v_rut) then raise exception 'RUT inválido: %', p_rut; end if;
  if length(trim(coalesce(p_nombre, ''))) < 3 then raise exception 'Falta el nombre de %', v_rut; end if;
  if v_rol not in ('tecnico', 'supervisor', 'admin') then raise exception 'Nivel no válido: %', p_rol; end if;
  if v_op is not null and v_op not in ('tigo', 'vtr') then raise exception 'Operación no válida: %', p_operacion; end if;
  if exists (select 1 from public.perfiles where rut = v_rut)
     or exists (select 1 from auth.users where email = lower(v_rut) || '@tecnicos.academia.invalid') then
    return 'existe';
  end if;
  select valor into v_clave from privado.config where clave = 'clave_inicial';
  if v_clave is null then raise exception 'Falta configurar la clave inicial'; end if;
  perform public.crear_tecnico(v_rut, trim(p_nombre), null, v_clave, v_rol);
  update public.perfiles set operacion = v_op where rut = v_rut;
  return 'creado';
end $$;
revoke all on function public.admin_crear_usuario(text, text, text, text) from public, anon;
grant execute on function public.admin_crear_usuario(text, text, text, text) to authenticated;

-- Cambia nombre, nivel u operación de un usuario. Nadie puede cambiar su propio nivel
-- (así un administrador no se deja sin acceso por error).
create or replace function public.admin_editar_usuario(
  p_usuario uuid, p_nombre text, p_operacion text, p_rol text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_op  text := nullif(lower(trim(coalesce(p_operacion, ''))), '');
  v_rol text := lower(trim(coalesce(p_rol, '')));
  v_act public.perfiles;
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'No autorizado'; end if;
  select * into v_act from public.perfiles where id = p_usuario;
  if not found then raise exception 'Usuario no encontrado'; end if;
  if v_rol not in ('tecnico', 'supervisor', 'admin') then raise exception 'Nivel no válido: %', p_rol; end if;
  if v_op is not null and v_op not in ('tigo', 'vtr') then raise exception 'Operación no válida: %', p_operacion; end if;
  if p_usuario = auth.uid() and v_rol <> v_act.rol then raise exception 'No puedes cambiar tu propio nivel'; end if;
  if length(trim(coalesce(p_nombre, ''))) < 3 then raise exception 'Falta el nombre'; end if;
  update public.perfiles set nombre = trim(p_nombre), operacion = v_op, rol = v_rol where id = p_usuario;
  return 'ok';
end $$;
revoke all on function public.admin_editar_usuario(uuid, text, text, text) from public, anon;
grant execute on function public.admin_editar_usuario(uuid, text, text, text) to authenticated;

-- Comprobación: debe mostrar las dos funciones.
select proname from pg_proc where proname in ('admin_crear_usuario', 'admin_editar_usuario') order by 1;
