-- =====================================================================
-- Academia Técnica · Botón "Cambiar clave" de la pestaña "Usuarios" (solo administrador)
-- Pegar en Supabase > SQL Editor > Run. Se puede volver a ejecutar.
-- El administrador escribe una clave provisoria; el usuario debe crear una propia al entrar.
-- ("Restablecer" usa la función restablecer_clave del script 02.)
-- =====================================================================

create or replace function public.admin_cambiar_clave(p_usuario uuid, p_clave text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_obj public.perfiles;
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'No autorizado'; end if;
  if p_usuario = auth.uid() then raise exception 'No puedes cambiar tu propia clave aquí'; end if;
  if length(coalesce(p_clave, '')) < 8 then raise exception 'La clave debe tener al menos 8 caracteres'; end if;

  select * into v_obj from public.perfiles where id = p_usuario;
  if not found then raise exception 'Usuario no encontrado'; end if;

  update auth.users
     set encrypted_password = extensions.crypt(p_clave, extensions.gen_salt('bf')), updated_at = now()
   where id = p_usuario;
  update public.perfiles set debe_cambiar_clave = true where id = p_usuario;

  -- Cierra sus sesiones abiertas en otros equipos.
  delete from auth.refresh_tokens where user_id = p_usuario::text;
  delete from auth.sessions where user_id = p_usuario;

  return v_obj.nombre;
end $$;
revoke all on function public.admin_cambiar_clave(uuid, text) from public, anon;
grant execute on function public.admin_cambiar_clave(uuid, text) to authenticated;

-- Comprobación: debe devolver una fila con admin_cambiar_clave.
select proname from pg_proc where proname = 'admin_cambiar_clave';
