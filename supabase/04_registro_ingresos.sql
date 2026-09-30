-- =====================================================================
-- Academia Técnica · Registro de ingresos (solo lo ven los admin)
-- Pegar en Supabase > SQL Editor > Run. Se puede volver a ejecutar.
-- =====================================================================

create table if not exists public.ingresos (
  id          bigint generated always as identity primary key,
  usuario_id  uuid not null references public.perfiles(id) on delete cascade,
  fecha       timestamptz not null default now(),
  dispositivo text
);
create index if not exists ingresos_fecha_idx on public.ingresos (fecha desc);

alter table public.ingresos enable row level security;

-- Cada usuario registra solo su propio ingreso.
drop policy if exists "registrar mi ingreso" on public.ingresos;
create policy "registrar mi ingreso" on public.ingresos
  for insert to authenticated with check (usuario_id = auth.uid());

-- Solo los admin leen el registro.
drop policy if exists "admin ve ingresos" on public.ingresos;
create policy "admin ve ingresos" on public.ingresos
  for select to authenticated using (public.mi_rol() = 'admin');

revoke all on public.ingresos from anon, authenticated;
grant insert (usuario_id, dispositivo) on public.ingresos to authenticated;
grant select on public.ingresos to authenticated;
