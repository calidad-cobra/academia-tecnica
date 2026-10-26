-- =====================================================================
-- Academia Técnica · Nota "Clave inicial" de la pestaña "Usuarios" (solo administrador)
-- Pegar en Supabase > SQL Editor > Run. Se puede volver a ejecutar.
-- La clave inicial sigue guardada en privado.config (no en el repositorio, que es público);
-- estas funciones solo dejan que un administrador la vea o la cambie desde la página.
-- Cambiarla NO cambia la clave de nadie: se usa para los usuarios nuevos y al "Restablecer".
-- =====================================================================

-- Devuelve la clave inicial actual (null si aún no está configurada).
create or replace function public.admin_ver_clave_inicial()
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_clave text;
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'No autorizado'; end if;
  select valor into v_clave from privado.config where clave = 'clave_inicial';
  return v_clave;
end $$;
revoke all on function public.admin_ver_clave_inicial() from public, anon;
grant execute on function public.admin_ver_clave_inicial() to authenticated;

-- Cambia la clave inicial (mínimo 8 caracteres).
create or replace function public.admin_cambiar_clave_inicial(p_clave text)
returns text language plpgsql security definer set search_path = '' as $$
begin
  if public.mi_rol() is distinct from 'admin' then raise exception 'No autorizado'; end if;
  if length(coalesce(trim(p_clave), '')) < 8 then raise exception 'La clave debe tener al menos 8 caracteres'; end if;
  insert into privado.config (clave, valor) values ('clave_inicial', trim(p_clave))
  on conflict (clave) do update set valor = excluded.valor;
  return 'ok';
end $$;
revoke all on function public.admin_cambiar_clave_inicial(text) from public, anon;
grant execute on function public.admin_cambiar_clave_inicial(text) to authenticated;

-- Comprobación: debe mostrar las dos funciones.
select proname from pg_proc where proname in ('admin_ver_clave_inicial', 'admin_cambiar_clave_inicial') order by 1;
