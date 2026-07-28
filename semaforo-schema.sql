-- ═══════════════════════════════════════════════════════════════════════════
-- WE ARE — Semáforo de marcas
--
-- Reemplaza la carga mensual del semáforo en ClickUp/planilla.
-- Una fila por (marca × mes) con los 3 bloques de números y las 3 preguntas,
-- y una fila por (marca × mes × servicio) con el color de ese servicio.
--
-- Todo con prefijo sem_ para no chocar con el sistema de slots (slot_) ni con
-- el dashboard (marcas / usuario_marcas).
-- Se puede correr más de una vez.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── SERVICIOS ───────────────────────────────────────────────────────────────
create table if not exists sem_servicios (
  id      serial primary key,
  nombre  text not null unique,
  orden   int not null default 99,
  activo  boolean not null default true
);

insert into sem_servicios (nombre, orden) values
  ('GE 360 (KAM)', 1), ('Servicio - Fronter', 2), ('Paid Media', 3),
  ('Email', 4), ('Diseño', 5), ('Social Media', 6),
  ('Marketplace', 7), ('Operaciones', 8), ('DDD', 9)
on conflict (nombre) do nothing;

-- ── MARCAS ──────────────────────────────────────────────────────────────────
create table if not exists sem_marcas (
  id         serial primary key,
  nombre     text not null unique,
  activa     boolean not null default true,
  baja_at    date,                     -- cuándo dejó de ser cliente
  creada_at  timestamptz not null default now()
);

-- Qué servicios tiene contratados hoy cada marca. El histórico no depende de
-- esto: si mañana se saca un servicio, los meses ya cargados lo siguen mostrando.
create table if not exists sem_marca_servicios (
  marca_id     int not null references sem_marcas(id)    on delete cascade,
  servicio_id  int not null references sem_servicios(id) on delete cascade,
  primary key (marca_id, servicio_id)
);

-- ── CIERRE MENSUAL (nivel marca) ────────────────────────────────────────────
create table if not exists sem_registros (
  id            serial primary key,
  marca_id      int  not null references sem_marcas(id) on delete cascade,
  periodo       date not null check (extract(day from periodo) = 1),  -- siempre día 1
  -- el color de la marca sale del peor servicio; esto lo pisa a mano si hace falta
  estado_manual text check (estado_manual in ('verde','amarillo','rojo')),
  -- las 3 preguntas del cierre
  q1            text,   -- ¿Por qué el semáforo tiene ese color?
  q2            text,   -- ¿Qué se está haciendo para revertirlo o mantenerlo?
  q3            text,   -- ¿Cuál es el foco/prioridad del cliente en la próxima quincena?
  -- desvío vs objetivo
  fact_obj      numeric(14,2), fact_real numeric(14,2),
  ord_obj       numeric(12,2), ord_real  numeric(12,2),
  ses_obj       numeric(14,2), ses_real  numeric(14,2),
  cargado_por   text,
  creado_at     timestamptz not null default now(),
  actualizado_at timestamptz not null default now(),
  unique (marca_id, periodo)
);
create index if not exists sem_registros_periodo_idx on sem_registros (periodo desc);

-- ── DESGLOSE POR SERVICIO ───────────────────────────────────────────────────
create table if not exists sem_detalle (
  id           serial primary key,
  registro_id  int not null references sem_registros(id) on delete cascade,
  servicio_id  int not null references sem_servicios(id),
  estado       text not null default 'sin_servicio'
               check (estado in ('verde','amarillo','rojo','sin_servicio')),
  nota         text,
  unique (registro_id, servicio_id)
);

-- ── USUARIOS ────────────────────────────────────────────────────────────────
-- Mismo criterio que slots: la autorización se guarda contra el mail y la
-- cuenta se vincula sola en el primer login.
create table if not exists sem_usuarios (
  id             serial primary key,
  email          text not null,
  nombre         text,
  rol            text not null default 'lector'
                 check (rol in ('admin','analista','lector')),
  activo         boolean not null default true,
  user_id        uuid,
  ultimo_ingreso timestamptz
);
create unique index if not exists sem_usuarios_email_idx on sem_usuarios (lower(email));
create unique index if not exists sem_usuarios_uid_idx   on sem_usuarios (user_id)
  where user_id is not null;

-- Qué marcas puede cargar cada analista. Los admin cargan todas.
create table if not exists sem_usuario_marcas (
  usuario_id int not null references sem_usuarios(id) on delete cascade,
  marca_id   int not null references sem_marcas(id)   on delete cascade,
  primary key (usuario_id, marca_id)
);

insert into sem_usuarios (email, nombre, rol) values
  ('tdeluca@we-ecommerce.com', 'Tomás De Luca', 'admin')
on conflict do nothing;

-- ── IDENTIDAD Y PERMISOS ────────────────────────────────────────────────────
create or replace function sem_email() returns text
  language sql stable security definer set search_path = public, auth as $$
  select lower(email) from auth.users where id = auth.uid()
$$;

create or replace function sem_rol() returns text
  language sql stable security definer set search_path = public as $$
  select rol from sem_usuarios
   where activo and (user_id = auth.uid() or lower(email) = sem_email())
   limit 1
$$;

create or replace function sem_uid() returns int
  language sql stable security definer set search_path = public as $$
  select id from sem_usuarios
   where activo and (user_id = auth.uid() or lower(email) = sem_email())
   limit 1
$$;

create or replace function sem_puede_editar(m int) returns boolean
  language sql stable security definer set search_path = public as $$
  select sem_rol() = 'admin'
      or (sem_rol() = 'analista' and exists (
            select 1 from sem_usuario_marcas um
             where um.usuario_id = sem_uid() and um.marca_id = m))
$$;

-- La app la llama después de loguear. Devuelve la fila del usuario.
create or replace function sem_vincular()
  returns setof sem_usuarios
  language plpgsql security definer set search_path = public as $$
begin
  update sem_usuarios
     set user_id = auth.uid(), ultimo_ingreso = now()
   where activo and lower(email) = sem_email()
     and (user_id is null or user_id = auth.uid());

  return query
    select * from sem_usuarios
     where activo and (user_id = auth.uid() or lower(email) = sem_email())
     limit 1;
end $$;

grant execute on function sem_email(), sem_rol(), sem_uid(),
                          sem_puede_editar(int), sem_vincular() to authenticated;

-- ── VISTAS ──────────────────────────────────────────────────────────────────
-- Una fila por marca × mes × servicio. Toma los servicios contratados hoy
-- unidos a los que quedaron cargados en el histórico, así sacar un servicio
-- no borra los meses viejos de la grilla.
create or replace view sem_v_detalle as
with base as (
  select r.id as registro_id, r.marca_id, r.periodo, ms.servicio_id
    from sem_registros r
    join sem_marca_servicios ms on ms.marca_id = r.marca_id
  union
  select d.registro_id, r.marca_id, r.periodo, d.servicio_id
    from sem_detalle d
    join sem_registros r on r.id = d.registro_id
)
select b.registro_id, b.marca_id, m.nombre as marca, m.activa,
       b.periodo, to_char(b.periodo, 'YYYY-MM') as periodo_txt,
       b.servicio_id, s.nombre as servicio, s.orden as servicio_orden,
       coalesce(d.estado, 'sin_servicio') as estado, d.nota,
       r.q1, r.q2, r.q3
  from base b
  join sem_marcas    m on m.id = b.marca_id
  join sem_servicios s on s.id = b.servicio_id
  join sem_registros r on r.id = b.registro_id
  left join sem_detalle d on d.registro_id = b.registro_id
                         and d.servicio_id = b.servicio_id
 where sem_rol() is not null;

-- Una fila por marca × mes: color agregado, conteo de colores y desvíos.
create or replace view sem_v_marcas_mes as
select r.id as registro_id, m.id as marca_id, m.nombre as marca, m.activa,
       r.periodo, to_char(r.periodo, 'YYYY-MM') as periodo_txt,
       coalesce(r.estado_manual, agg.estado_calc) as estado,
       (r.estado_manual is not null) as estado_forzado,
       agg.estado_calc,
       agg.n_verde, agg.n_amarillo, agg.n_rojo, agg.n_sin,
       r.q1, r.q2, r.q3,
       r.fact_obj, r.fact_real,
       case when r.fact_obj > 0
            then round((r.fact_real - r.fact_obj) / r.fact_obj * 100, 1) end as fact_desvio,
       r.ord_obj, r.ord_real,
       case when r.ord_obj > 0
            then round((r.ord_real - r.ord_obj) / r.ord_obj * 100, 1) end as ord_desvio,
       r.ses_obj, r.ses_real,
       case when r.ses_obj > 0
            then round((r.ses_real - r.ses_obj) / r.ses_obj * 100, 1) end as ses_desvio,
       r.cargado_por, r.actualizado_at
  from sem_registros r
  join sem_marcas m on m.id = r.marca_id
  left join lateral (
    select count(*) filter (where d.estado = 'verde')        as n_verde,
           count(*) filter (where d.estado = 'amarillo')     as n_amarillo,
           count(*) filter (where d.estado = 'rojo')         as n_rojo,
           count(*) filter (where d.estado = 'sin_servicio') as n_sin,
           case
             when count(*) filter (where d.estado = 'rojo')     > 0 then 'rojo'
             when count(*) filter (where d.estado = 'amarillo') > 0 then 'amarillo'
             when count(*) filter (where d.estado = 'verde')    > 0 then 'verde'
             else 'sin_servicio'
           end as estado_calc
      from sem_detalle d where d.registro_id = r.id
  ) agg on true
 where sem_rol() is not null;

grant select on sem_v_detalle, sem_v_marcas_mes to authenticated;

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table sem_servicios       enable row level security;
alter table sem_marcas          enable row level security;
alter table sem_marca_servicios enable row level security;
alter table sem_registros       enable row level security;
alter table sem_detalle         enable row level security;
alter table sem_usuarios        enable row level security;
alter table sem_usuario_marcas  enable row level security;

-- Catálogos: lee cualquier usuario habilitado, escribe admin.
do $$
declare t text;
begin
  foreach t in array array['sem_servicios','sem_marcas','sem_marca_servicios'] loop
    execute format('drop policy if exists %I on %I', t || '_read', t);
    execute format('create policy %I on %I for select to authenticated
                    using (sem_rol() is not null)', t || '_read', t);
    execute format('drop policy if exists %I on %I', t || '_admin', t);
    execute format('create policy %I on %I for all to authenticated
                    using (sem_rol() = ''admin'') with check (sem_rol() = ''admin'')',
                   t || '_admin', t);
  end loop;
end $$;

-- Cierres: lee cualquiera, escribe admin o el responsable de la marca.
drop policy if exists sem_registros_read on sem_registros;
create policy sem_registros_read on sem_registros for select to authenticated
  using (sem_rol() is not null);

drop policy if exists sem_registros_write on sem_registros;
create policy sem_registros_write on sem_registros for all to authenticated
  using (sem_puede_editar(marca_id)) with check (sem_puede_editar(marca_id));

drop policy if exists sem_detalle_read on sem_detalle;
create policy sem_detalle_read on sem_detalle for select to authenticated
  using (sem_rol() is not null);

drop policy if exists sem_detalle_write on sem_detalle;
create policy sem_detalle_write on sem_detalle for all to authenticated
  using (exists (select 1 from sem_registros r
                  where r.id = registro_id and sem_puede_editar(r.marca_id)))
  with check (exists (select 1 from sem_registros r
                  where r.id = registro_id and sem_puede_editar(r.marca_id)));

-- Usuarios: cada uno se ve a sí mismo; el admin ve y edita todo.
drop policy if exists sem_usuarios_self on sem_usuarios;
create policy sem_usuarios_self on sem_usuarios for select to authenticated
  using (user_id = auth.uid() or lower(email) = sem_email() or sem_rol() = 'admin');

drop policy if exists sem_usuarios_admin on sem_usuarios;
create policy sem_usuarios_admin on sem_usuarios for all to authenticated
  using (sem_rol() = 'admin') with check (sem_rol() = 'admin');

drop policy if exists sem_um_read on sem_usuario_marcas;
create policy sem_um_read on sem_usuario_marcas for select to authenticated
  using (sem_rol() is not null);

drop policy if exists sem_um_admin on sem_usuario_marcas;
create policy sem_um_admin on sem_usuario_marcas for all to authenticated
  using (sem_rol() = 'admin') with check (sem_rol() = 'admin');

-- ── OPCIONAL: traer las marcas del dashboard ────────────────────────────────
-- Si ya existe la tabla `marcas` del dashboard, esto copia las activas.
-- Descomentar y correr una sola vez.
--
-- insert into sem_marcas (nombre)
-- select distinct nombre from marcas where activa
-- on conflict (nombre) do nothing;
--
-- Y darle a todas los servicios que correspondan, por ejemplo:
-- insert into sem_marca_servicios (marca_id, servicio_id)
-- select m.id, s.id from sem_marcas m, sem_servicios s
--  where s.nombre in ('Email','Diseño','Paid Media')
-- on conflict do nothing;
