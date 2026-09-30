-- =====================================================================
-- Academia Técnica · Restablecer contraseña desde el panel de Supervisión
-- Pegar en Supabase > SQL Editor > Run. Se puede volver a ejecutar.
-- La clave inicial NO va en este archivo (el repositorio es público):
-- se guarda aparte en privado.config con una línea que se ejecuta solo en Supabase.
-- =====================================================================

-- Esquema privado: no se expone a la página ni a la API.
create schema if not exists privado;
revoke all on schema privado from public, anon, authenticated;
create table if not exists privado.config (
  clave text primary key,
  valor text not null
);

-- Restablece la clave de un técnico a la clave inicial y obliga a cambiarla al entrar.
-- Admin: cualquier usuario. Supervisor: solo técnicos de su zona. Nadie a sí mismo.
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
  if v_rol = 'supervisor' and (v_obj.rol <> 'tecnico' or v_obj.zona is distinct from public.mi_zona()) then
    raise exception 'No autorizado';
  end if;

  select valor into v_clave from privado.config where clave = 'clave_inicial';
  if v_clave is null then raise exception 'Falta configurar la clave inicial'; end if;

  update auth.users
     set encrypted_password = extensions.crypt(v_clave, extensions.gen_salt('bf')), updated_at = now()
   where id = p_usuario;
  update public.perfiles set debe_cambiar_clave = true where id = p_usuario;

  -- Cierra sus sesiones abiertas en otros equipos.
  delete from auth.refresh_tokens where user_id = p_usuario::text;
  delete from auth.sessions where user_id = p_usuario;

  return v_obj.nombre;
end $$;
revoke all on function public.restablecer_clave(uuid) from public, anon;
grant execute on function public.restablecer_clave(uuid) to authenticated;
