-- =====================================================================
-- Academia Técnica · Evaluaciones dentro de la academia
-- Pegar en Supabase > SQL Editor > Run. Se puede volver a ejecutar.
--
-- · Las preguntas y sus respuestas correctas solo las leen admin y supervisor.
-- · El técnico recibe las preguntas SIN la respuesta correcta y la corrección
--   se hace en el servidor: solo ve su nota.
-- · Modo liviano: una fila por técnico y curso (mejor nota, intentos, último intento).
-- =====================================================================

create table if not exists public.pruebas (
  curso_id       text primary key,
  aprobacion     int  not null default 80 check (aprobacion between 1 and 100),
  max_intentos   int  not null default 3  check (max_intentos between 1 and 20),
  activa         boolean not null default true,
  actualizado_en timestamptz not null default now()
);

create table if not exists public.preguntas (
  id           uuid primary key default gen_random_uuid(),
  curso_id     text not null references public.pruebas(curso_id) on delete cascade,
  orden        int  not null default 0,
  enunciado    text not null,
  alternativas jsonb not null,          -- ["alternativa 1", "alternativa 2", ...]
  correcta     int  not null,           -- posición de la correcta (0 = primera)
  check (jsonb_typeof(alternativas) = 'array' and jsonb_array_length(alternativas) between 2 and 6),
  check (correcta >= 0 and correcta < jsonb_array_length(alternativas))
);
create index if not exists preguntas_curso_idx on public.preguntas (curso_id, orden);

create table if not exists public.resultados (
  usuario_id         uuid not null references public.perfiles(id) on delete cascade,
  curso_id           text not null,
  mejor_nota         int  not null default 0,
  aprobado           boolean not null default false,
  intentos           int  not null default 0,
  ultima_nota        int,
  ultimas_respuestas jsonb,             -- [{"p": id pregunta, "e": elegida, "ok": true/false}]
  fecha_ultimo       timestamptz,
  fecha_aprobado     timestamptz,
  primary key (usuario_id, curso_id)
);

alter table public.pruebas    enable row level security;
alter table public.preguntas  enable row level security;
alter table public.resultados enable row level security;

-- Pruebas y preguntas: las leen admin y supervisor; las edita solo el admin.
drop policy if exists "leer pruebas" on public.pruebas;
create policy "leer pruebas" on public.pruebas for select to authenticated using (public.mi_rol() in ('admin', 'supervisor'));
drop policy if exists "editar pruebas" on public.pruebas;
create policy "editar pruebas" on public.pruebas for all to authenticated using (public.mi_rol() = 'admin') with check (public.mi_rol() = 'admin');

drop policy if exists "leer preguntas" on public.preguntas;
create policy "leer preguntas" on public.preguntas for select to authenticated using (public.mi_rol() in ('admin', 'supervisor'));
drop policy if exists "editar preguntas" on public.preguntas;
create policy "editar preguntas" on public.preguntas for all to authenticated using (public.mi_rol() = 'admin') with check (public.mi_rol() = 'admin');

-- Resultados con el detalle de respuestas: solo admin y supervisor. Nadie los escribe directo.
drop policy if exists "leer resultados" on public.resultados;
create policy "leer resultados" on public.resultados for select to authenticated using (public.mi_rol() in ('admin', 'supervisor'));

revoke all on public.pruebas, public.preguntas, public.resultados from anon, authenticated;
grant select, insert, update, delete on public.pruebas, public.preguntas to authenticated;
grant select on public.resultados to authenticated;

-- El técnico ya no puede escribir su propia nota: solo sus lecciones.
revoke insert, update on public.avance from authenticated;
grant insert (usuario_id, lecciones, actualizado_en) on public.avance to authenticated;
grant update (usuario_id, lecciones, actualizado_en) on public.avance to authenticated;

-- ---------- Rendir: entrega las preguntas sin la respuesta correcta ----------
create or replace function public.obtener_prueba(p_curso text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_p public.pruebas;
  v_r public.resultados;
  v_q jsonb;
begin
  if auth.uid() is null or public.mi_rol() is null then raise exception 'No autorizado'; end if;
  select * into v_p from public.pruebas where curso_id = p_curso and activa;
  if not found then return jsonb_build_object('disponible', false); end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'enunciado', enunciado, 'alternativas', alternativas) order by orden, id), '[]'::jsonb)
    into v_q from public.preguntas where curso_id = p_curso;
  if jsonb_array_length(v_q) = 0 then return jsonb_build_object('disponible', false); end if;
  select * into v_r from public.resultados where usuario_id = auth.uid() and curso_id = p_curso;
  return jsonb_build_object(
    'disponible', true, 'aprobacion', v_p.aprobacion, 'max_intentos', v_p.max_intentos,
    'intentos', coalesce(v_r.intentos, 0), 'aprobado', coalesce(v_r.aprobado, false),
    'mejor_nota', coalesce(v_r.mejor_nota, 0), 'preguntas', v_q);
end $$;

-- ---------- Corregir en el servidor y guardar el resultado ----------
create or replace function public.responder_prueba(p_curso text, p_respuestas jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_rol   text := public.mi_rol();
  v_p     public.pruebas;
  v_r     public.resultados;
  v_total int; v_ok int; v_nota int; v_aprob boolean; v_det jsonb;
begin
  if auth.uid() is null or v_rol is null then raise exception 'No autorizado'; end if;
  select * into v_p from public.pruebas where curso_id = p_curso and activa;
  if not found then raise exception 'Evaluación no disponible'; end if;

  select * into v_r from public.resultados where usuario_id = auth.uid() and curso_id = p_curso for update;
  if v_rol = 'tecnico' then
    if coalesce(v_r.aprobado, false) then raise exception 'Ya aprobaste esta evaluación'; end if;
    if coalesce(v_r.intentos, 0) >= v_p.max_intentos then raise exception 'Sin intentos disponibles'; end if;
  end if;

  select count(*),
         count(*) filter (where (p_respuestas ->> (id::text))::int = correcta),
         jsonb_agg(jsonb_build_object('p', id, 'e', (p_respuestas ->> (id::text))::int,
                                      'ok', coalesce((p_respuestas ->> (id::text))::int = correcta, false)) order by orden, id)
    into v_total, v_ok, v_det
    from public.preguntas where curso_id = p_curso;
  if v_total = 0 then raise exception 'Evaluación sin preguntas'; end if;

  v_nota  := round(100.0 * v_ok / v_total)::int;
  v_aprob := v_nota >= v_p.aprobacion;

  insert into public.resultados as r (usuario_id, curso_id, mejor_nota, aprobado, intentos, ultima_nota, ultimas_respuestas, fecha_ultimo, fecha_aprobado)
  values (auth.uid(), p_curso, v_nota, v_aprob, 1, v_nota, v_det, now(), case when v_aprob then now() end)
  on conflict (usuario_id, curso_id) do update set
    mejor_nota = greatest(r.mejor_nota, excluded.mejor_nota),
    aprobado = r.aprobado or excluded.aprobado,
    intentos = r.intentos + 1,
    ultima_nota = excluded.ultima_nota,
    ultimas_respuestas = excluded.ultimas_respuestas,
    fecha_ultimo = now(),
    fecha_aprobado = coalesce(r.fecha_aprobado, excluded.fecha_aprobado)
  returning * into v_r;

  -- Refleja la nota en el avance (lo que muestran el panel y el Excel).
  insert into public.avance as a (usuario_id, evaluaciones, actualizado_en)
  values (auth.uid(),
          jsonb_build_object(p_curso, jsonb_build_object('best', v_r.mejor_nota / 100.0, 'passed', v_r.aprobado, 'at', coalesce(v_r.fecha_aprobado, v_r.fecha_ultimo))),
          now())
  on conflict (usuario_id) do update set evaluaciones = a.evaluaciones || excluded.evaluaciones, actualizado_en = now();

  return jsonb_build_object('nota', v_nota, 'aprobado', v_aprob, 'mejor_nota', v_r.mejor_nota,
                            'ya_aprobado', v_r.aprobado, 'intentos', v_r.intentos, 'max_intentos', v_p.max_intentos);
end $$;

-- ---------- Supervisor / admin: habilitar nuevos intentos ----------
create or replace function public.reiniciar_intentos(p_usuario uuid, p_curso text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if public.mi_rol() is null or public.mi_rol() not in ('admin', 'supervisor') then raise exception 'No autorizado'; end if;
  update public.resultados set intentos = 0 where usuario_id = p_usuario and curso_id = p_curso;
end $$;

revoke all on function public.obtener_prueba(text), public.responder_prueba(text, jsonb), public.reiniciar_intentos(uuid, text) from public, anon;
grant execute on function public.obtener_prueba(text), public.responder_prueba(text, jsonb), public.reiniciar_intentos(uuid, text) to authenticated;
