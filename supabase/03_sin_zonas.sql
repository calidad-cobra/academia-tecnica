-- =====================================================================
-- Academia Técnica · Sin zonas: supervisores y admin ven a todos los técnicos
-- Pegar en Supabase > SQL Editor > Run. Se puede volver a ejecutar.
-- (La columna "zona" queda en la tabla pero ya no se usa.)
-- =====================================================================

-- Ver datos: yo mismo, o cualquier supervisor / admin.
create or replace function public.puedo_ver(p_usuario uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_usuario = auth.uid() or public.mi_rol() in ('admin', 'supervisor')
$$;

-- Restablecer clave: admin a cualquiera; supervisor solo a técnicos; nadie a sí mismo.
create or replace function public.restablecer_clave(p_usuario uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_rol   text := public.mi_rol();
  v_obj   public.perfiles;
  v_clave text;
begin
  if v_rol is null or v_rol not in ('admin', 'supervisor') then raise exception 'No autorizado'; end if;
  if p_usuario = auth.uid() then raise exception 'No puedes restablecer tu propia clave'; end if;

  select * into v_obj from public.perfiles where id = p_usuario;
  if not found then raise exception 'Técnico no encontrado'; end if;
  if v_rol = 'supervisor' and v_obj.rol <> 'tecnico' then raise exception 'No autorizado'; end if;

  select valor into v_clave from privado.config where clave = 'clave_inicial';
  if v_clave is null then raise exception 'Falta configurar la clave inicial'; end if;

  update auth.users
     set encrypted_password = extensions.crypt(v_clave, extensions.gen_salt('bf')), updated_at = now()
   where id = p_usuario;
  update public.perfiles set debe_cambiar_clave = true where id = p_usuario;

  delete from auth.refresh_tokens where user_id = p_usuario::text;
  delete from auth.sessions where user_id = p_usuario;

  return v_obj.nombre;
end $$;
revoke all on function public.restablecer_clave(uuid) from public, anon;
grant execute on function public.restablecer_clave(uuid) to authenticated;

-- Sin zonas en los usuarios existentes.
update public.perfiles set zona = null where zona is not null;
