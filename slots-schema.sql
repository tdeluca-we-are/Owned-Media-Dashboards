-- ═══════════════════════════════════════════════════════════════════════════
-- WE ARE — Sistema de Slots
-- Esquema completo. Correr una sola vez en el SQL Editor de Supabase.
-- Todas las tablas van con prefijo slot_ para no chocar con el dashboard.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── REFERENCIA: TIERS ───────────────────────────────────────────────────────
-- Espeja la hoja REF.TIER & CUARTIL. peso = cuánto ocupa una cuenta de ese
-- tier en la capacidad de una persona (antes se hacía a mano: "King (1.5)").
create table if not exists slot_tiers (
  codigo        text primary key,
  concepto      text not null,
  cuartil_min   numeric(3,1) not null,
  scoring_min   int not null,
  peso          numeric(3,2) not null,
  orden         int not null,
  descripcion   text
);

insert into slot_tiers (codigo, concepto, cuartil_min, scoring_min, peso, orden, descripcion) values
  ('complejo', 'Complejidad a medida', 2.5, 90, 1.50, 1, 'Caso especial — análisis de complejidad previo al cierre'),
  ('1',        'Alto',                 2.4, 80, 1.25, 2, 'Cuentas de alta complejidad y mayor exigencia operativa'),
  ('2',        'Medio',                2.3, 60, 1.00, 3, 'Cuentas de complejidad media, flujo estándar'),
  ('3',        'Bajo',                 2.2, 40, 0.85, 4, 'Cuentas de baja complejidad, menor demanda'),
  ('4',        'Inicial',              2.1, 20, 0.70, 5, 'Cuentas iniciales, menor requerimiento de seniority')
on conflict (codigo) do nothing;

-- ── SERVICIOS ───────────────────────────────────────────────────────────────
create table if not exists slot_servicios (
  id      serial primary key,
  nombre  text not null unique,
  orden   int not null default 99,
  activo  boolean not null default true
);

insert into slot_servicios (nombre, orden) values
  ('GE 360 (KAM)', 1), ('CSE (Fronter)', 2), ('Paid (Strategist)', 3),
  ('Implementador Paid', 4), ('Email', 5), ('Diseño', 6), ('Redes', 7),
  ('Marketplace', 8), ('Operaciones', 9), ('PM', 10), ('DDD', 11)
on conflict (nombre) do nothing;

-- ── LÍDERES Y CÉLULAS ───────────────────────────────────────────────────────
create table if not exists slot_lideres (
  id      serial primary key,
  nombre  text not null unique,
  activo  boolean not null default true
);

create table if not exists slot_celulas (
  id      serial primary key,
  nombre  text not null unique,
  activa  boolean not null default true
);

-- ── CUENTAS ─────────────────────────────────────────────────────────────────
-- tier arranca en null a propósito: la planilla nunca guardó el tier de la
-- cuenta (solo el de la persona), así que clasificarlas es el primer trabajo.
create table if not exists slot_cuentas (
  id            serial primary key,
  nombre        text not null unique,
  razon_social  text,
  tier          text references slot_tiers(codigo),
  activa        boolean not null default true,
  revisar       boolean not null default false,
  nota          text,
  created_at    timestamptz not null default now()
);

-- ── PERSONAS ────────────────────────────────────────────────────────────────
create table if not exists slot_personas (
  id           serial primary key,
  nombre       text not null,
  servicio_id  int not null references slot_servicios(id),
  rol          text,
  cuartil      numeric(3,1),
  cap_max      numeric(5,2) not null default 0,
  lider_id     int references slot_lideres(id),
  celula_id    int references slot_celulas(id),
  activa       boolean not null default true,
  nota         text,
  created_at   timestamptz not null default now(),
  unique (nombre, servicio_id)
);

-- ── ASIGNACIONES ────────────────────────────────────────────────────────────
-- El corazón del sistema: una fila por (persona × cuenta × servicio).
-- Todo lo que antes se contaba a mano sale de acá.
--   activa        → la tiene hoy
--   baja_prevista → la tiene hoy pero se va (libera slot)
--   proyectada    → todavía no la tiene, próximo cierre (ocupa slot)
create table if not exists slot_asignaciones (
  id           serial primary key,
  persona_id   int not null references slot_personas(id) on delete cascade,
  cuenta_id    int not null references slot_cuentas(id) on delete cascade,
  servicio_id  int not null references slot_servicios(id),
  estado       text not null default 'activa'
                 check (estado in ('activa','baja_prevista','proyectada')),
  fecha_desde  date,
  fecha_hasta  date,
  nota         text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (persona_id, cuenta_id, servicio_id)
);

create index if not exists slot_asig_persona_idx on slot_asignaciones(persona_id);
create index if not exists slot_asig_cuenta_idx  on slot_asignaciones(cuenta_id);

create or replace function slot_touch() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists slot_asig_touch on slot_asignaciones;
create trigger slot_asig_touch before update on slot_asignaciones
  for each row execute function slot_touch();

-- ── USUARIOS Y ROLES ────────────────────────────────────────────────────────
create table if not exists slot_usuarios (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text,
  nombre     text,
  rol        text not null check (rol in ('admin','lider','comercial')),
  lider_id   int references slot_lideres(id),
  created_at timestamptz not null default now()
);

-- ── SNAPSHOTS (historial de ocupación) ──────────────────────────────────────
create table if not exists slot_snapshots (
  id          serial primary key,
  fecha       date not null,
  persona_id  int not null references slot_personas(id) on delete cascade,
  cap_max     numeric(5,2),
  carga       numeric(5,2),
  neta        numeric(5,2),
  vendible    numeric(5,2),
  unique (fecha, persona_id)
);

-- ═══════════════════════════════════════════════════════════════════════════
-- VISTAS — acá vive toda la aritmética que antes se tipeaba a mano
-- ═══════════════════════════════════════════════════════════════════════════

-- Peso de cada asignación según el tier de la cuenta.
-- Cuenta sin tier clasificado pesa 1.00 (equivale al conteo simple de hoy).
create or replace view slot_v_asignaciones as
select
  a.id, a.persona_id, a.cuenta_id, a.servicio_id, a.estado,
  a.fecha_desde, a.fecha_hasta, a.nota,
  c.nombre  as cuenta,
  c.tier     as cuenta_tier,
  c.activa   as cuenta_activa,
  coalesce(t.peso, 1.00) as peso,
  t.cuartil_min as tier_cuartil_min
from slot_asignaciones a
join slot_cuentas c on c.id = a.cuenta_id
left join slot_tiers t on t.codigo = c.tier;

-- Ocupación por persona. Replica la hoja EQUIPO pero calculada:
--   carga    = lo que tiene hoy          (activa + baja_prevista)
--   bajas    = lo que va a soltar        (baja_prevista)
--   cierres  = lo que va a entrar        (proyectada)
--   neta     = carga - bajas + cierres
--   vendible = cap_max - neta
create or replace view slot_v_ocupacion as
select
  p.id as persona_id, p.nombre, p.rol, p.cuartil, p.cap_max, p.activa,
  p.servicio_id, s.nombre as servicio, s.orden as servicio_orden,
  p.lider_id, l.nombre as lider,
  p.celula_id, ce.nombre as celula,
  coalesce(sum(a.peso) filter (where a.estado in ('activa','baja_prevista')), 0) as carga,
  coalesce(sum(a.peso) filter (where a.estado = 'baja_prevista'), 0) as bajas,
  coalesce(sum(a.peso) filter (where a.estado = 'proyectada'), 0) as cierres,
  count(a.id) filter (where a.estado in ('activa','baja_prevista')) as cuentas_activas,
  count(a.id) filter (where a.estado in ('activa','baja_prevista') and a.cuenta_tier is null) as cuentas_sin_tier,
  coalesce(sum(a.peso) filter (where a.estado in ('activa','baja_prevista')), 0)
    - coalesce(sum(a.peso) filter (where a.estado = 'baja_prevista'), 0)
    + coalesce(sum(a.peso) filter (where a.estado = 'proyectada'), 0) as neta,
  p.cap_max
    - ( coalesce(sum(a.peso) filter (where a.estado in ('activa','baja_prevista')), 0)
      - coalesce(sum(a.peso) filter (where a.estado = 'baja_prevista'), 0)
      + coalesce(sum(a.peso) filter (where a.estado = 'proyectada'), 0) ) as vendible,
  -- tier máximo que puede tomar, derivado del cuartil (antes se cargaba a mano
  -- y quedaba desincronizado). Queda null si el cuartil está por debajo del
  -- piso de la tabla de referencia (2.1), que es el caso de los implementadores.
  ( select t.codigo from slot_tiers t
    where t.cuartil_min <= coalesce(p.cuartil, 0)
    order by t.orden limit 1 ) as tier_max
from slot_personas p
join slot_servicios s on s.id = p.servicio_id
left join slot_lideres l on l.id = p.lider_id
left join slot_celulas ce on ce.id = p.celula_id
left join slot_v_asignaciones a on a.persona_id = p.id
group by p.id, s.nombre, s.orden, l.nombre, ce.nombre;

-- Vista comercial: cuántos slots hay libres por célula × servicio, y hasta qué
-- tier se pueden vender. Antes esta hoja se tipeaba a mano y quedaba vieja.
create or replace view slot_v_comercial as
select
  o.celula_id, o.celula, o.servicio_id, o.servicio, o.servicio_orden,
  sum(greatest(o.vendible, 0))          as slots_libres,
  sum(o.cap_max)                        as capacidad,
  sum(o.neta)                           as ocupado,
  count(*)                              as personas,
  count(*) filter (where o.vendible < 0) as personas_sobrecargadas,
  -- mejor tier que la célula puede absorber en este servicio: el más exigente
  -- entre las personas que todavía tienen slot libre (orden 1 = más exigente)
  min(t.orden) filter (where o.vendible > 0) as mejor_tier_orden
from slot_v_ocupacion o
left join slot_tiers t on t.codigo = o.tier_max
where o.activa
group by o.celula_id, o.celula, o.servicio_id, o.servicio, o.servicio_orden;

-- Alertas. Lo que la planilla no podía detectar sola.
create or replace view slot_v_alertas as
  select 'sobrecarga' as tipo, o.persona_id, o.nombre as persona, o.servicio,
         o.lider, o.celula,
         'Tiene ' || round(o.neta,2) || ' de carga sobre una capacidad de ' || o.cap_max as detalle
  from slot_v_ocupacion o where o.activa and o.vendible < 0
union all
  select 'tier_excedido', o.persona_id, o.nombre, o.servicio, o.lider, o.celula,
         'Cuartil ' || o.cuartil || ' pero tiene asignada ' || a.cuenta || ' (TIER ' || a.cuenta_tier || ')'
  from slot_v_ocupacion o
  join slot_v_asignaciones a on a.persona_id = o.persona_id
  where o.activa and a.estado in ('activa','baja_prevista')
    and a.tier_cuartil_min > coalesce(o.cuartil, 0)
union all
  select 'sin_capacidad', o.persona_id, o.nombre, o.servicio, o.lider, o.celula,
         'No tiene capacidad máxima cargada'
  from slot_v_ocupacion o where o.activa and o.cap_max = 0
union all
  select 'sin_cuartil', o.persona_id, o.nombre, o.servicio, o.lider, o.celula,
         'No tiene cuartil cargado, no se puede saber qué tier puede tomar'
  from slot_v_ocupacion o where o.activa and o.cuartil is null;

-- ═══════════════════════════════════════════════════════════════════════════
-- SEGURIDAD
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function slot_rol() returns text
  language sql stable security definer set search_path = public as $$
  select rol from slot_usuarios where user_id = auth.uid()
$$;

create or replace function slot_mi_lider() returns int
  language sql stable security definer set search_path = public as $$
  select lider_id from slot_usuarios where user_id = auth.uid()
$$;

-- ¿Puedo escribir sobre esta persona? Admin sí; líder solo sobre su gente.
create or replace function slot_puede_editar(p_persona_id int) returns boolean
  language sql stable security definer set search_path = public as $$
  select slot_rol() = 'admin'
      or ( slot_rol() = 'lider'
           and exists (select 1 from slot_personas p
                       where p.id = p_persona_id and p.lider_id = slot_mi_lider()) )
$$;

alter table slot_tiers        enable row level security;
alter table slot_servicios    enable row level security;
alter table slot_lideres      enable row level security;
alter table slot_celulas      enable row level security;
alter table slot_cuentas      enable row level security;
alter table slot_personas     enable row level security;
alter table slot_asignaciones enable row level security;
alter table slot_usuarios     enable row level security;
alter table slot_snapshots    enable row level security;

-- Lectura: todo usuario logueado y registrado en slot_usuarios ve todo.
-- La app filtra por rol; el dato agregado no es sensible entre áreas.
do $$
declare t text;
begin
  foreach t in array array['slot_tiers','slot_servicios','slot_lideres','slot_celulas',
                           'slot_cuentas','slot_personas','slot_asignaciones','slot_snapshots']
  loop
    execute format('drop policy if exists %I on %I', t||'_read', t);
    execute format('create policy %I on %I for select to authenticated using (slot_rol() is not null)', t||'_read', t);
  end loop;
end $$;

-- Escritura de asignaciones: admin, o el líder dueño de la persona.
drop policy if exists slot_asig_write on slot_asignaciones;
create policy slot_asig_write on slot_asignaciones for all to authenticated
  using (slot_puede_editar(persona_id)) with check (slot_puede_editar(persona_id));

-- Personas: admin edita todo, líder solo la capacidad de su gente.
drop policy if exists slot_personas_write on slot_personas;
create policy slot_personas_write on slot_personas for all to authenticated
  using (slot_rol() = 'admin' or (slot_rol() = 'lider' and lider_id = slot_mi_lider()))
  with check (slot_rol() = 'admin' or (slot_rol() = 'lider' and lider_id = slot_mi_lider()));

-- Cuentas: cualquier líder puede dar de alta y clasificar el tier.
drop policy if exists slot_cuentas_write on slot_cuentas;
create policy slot_cuentas_write on slot_cuentas for all to authenticated
  using (slot_rol() in ('admin','lider')) with check (slot_rol() in ('admin','lider'));

-- Catálogos: solo admin.
do $$
declare t text;
begin
  foreach t in array array['slot_tiers','slot_servicios','slot_lideres','slot_celulas']
  loop
    execute format('drop policy if exists %I on %I', t||'_write', t);
    execute format('create policy %I on %I for all to authenticated using (slot_rol() = ''admin'') with check (slot_rol() = ''admin'')', t||'_write', t);
  end loop;
end $$;

-- Usuarios: cada uno lee su fila; admin administra todas.
drop policy if exists slot_usuarios_self on slot_usuarios;
create policy slot_usuarios_self on slot_usuarios for select to authenticated
  using (user_id = auth.uid() or slot_rol() = 'admin');

drop policy if exists slot_usuarios_admin on slot_usuarios;
create policy slot_usuarios_admin on slot_usuarios for all to authenticated
  using (slot_rol() = 'admin') with check (slot_rol() = 'admin');

-- Snapshot del día. Llamar desde un cron o a mano.
create or replace function slot_tomar_snapshot() returns int
  language sql security definer set search_path = public as $$
  insert into slot_snapshots (fecha, persona_id, cap_max, carga, neta, vendible)
  select current_date, persona_id, cap_max, carga, neta, vendible
  from slot_v_ocupacion where activa
  on conflict (fecha, persona_id) do update
    set cap_max = excluded.cap_max, carga = excluded.carga,
        neta = excluded.neta, vendible = excluded.vendible
  returning 1;
$$;
