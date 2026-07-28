-- ═══════════════════════════════════════════════════════════════════════════
-- WE ARE — Semáforo, segunda vuelta
--
-- Correr DESPUÉS de semaforo-schema.sql. Se puede correr más de una vez.
--
-- Suma:
--   · células (el grupo de marcas que lleva un KAM) para agrupar y filtrar
--   · plan de acción de la marca en el mes
--   · hilo de comentarios sobre ese plan
-- ═══════════════════════════════════════════════════════════════════════════

-- ── CÉLULAS ─────────────────────────────────────────────────────────────────
create table if not exists sem_celulas (
  id      serial primary key,
  nombre  text not null unique,
  kam     text,                       -- quién la lleva
  activa  boolean not null default true
);

alter table sem_marcas
  add column if not exists celula_id int references sem_celulas(id) on delete set null;

create index if not exists sem_marcas_celula_idx on sem_marcas (celula_id);

-- ── PLAN DE ACCIÓN Y COMENTARIOS ────────────────────────────────────────────
alter table sem_registros add column if not exists plan_accion text;

create table if not exists sem_comentarios (
  id          serial primary key,
  registro_id int  not null references sem_registros(id) on delete cascade,
  autor       text,
  texto       text not null,
  creado_at   timestamptz not null default now()
);
create index if not exists sem_comentarios_reg_idx on sem_comentarios (registro_id, creado_at);

-- ── VISTAS (se redefinen para exponer la célula) ────────────────────────────
-- Van dropeadas y no "create or replace": las columnas nuevas caen en el medio
-- y replace solo admite agregar al final.
drop view if exists sem_v_detalle;
drop view if exists sem_v_marcas_mes;

create view sem_v_detalle as
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
       m.celula_id, c.nombre as celula, c.kam,
       b.periodo, to_char(b.periodo, 'YYYY-MM') as periodo_txt,
       b.servicio_id, s.nombre as servicio, s.orden as servicio_orden,
       coalesce(d.estado, 'sin_servicio') as estado, d.nota,
       r.q1, r.q2, r.q3, r.plan_accion
  from base b
  join sem_marcas    m on m.id = b.marca_id
  join sem_servicios s on s.id = b.servicio_id
  join sem_registros r on r.id = b.registro_id
  left join sem_celulas c on c.id = m.celula_id
  left join sem_detalle d on d.registro_id = b.registro_id
                         and d.servicio_id = b.servicio_id
 where sem_rol() is not null;

create view sem_v_marcas_mes as
select r.id as registro_id, m.id as marca_id, m.nombre as marca, m.activa,
       m.celula_id, c.nombre as celula, c.kam,
       r.periodo, to_char(r.periodo, 'YYYY-MM') as periodo_txt,
       coalesce(r.estado_manual, agg.estado_calc) as estado,
       (r.estado_manual is not null) as estado_forzado,
       agg.estado_calc,
       agg.n_verde, agg.n_amarillo, agg.n_rojo, agg.n_sin,
       r.q1, r.q2, r.q3, r.plan_accion,
       (select count(*) from sem_comentarios k where k.registro_id = r.id) as n_comentarios,
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
  left join sem_celulas c on c.id = m.celula_id
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

-- ── RLS de lo nuevo ─────────────────────────────────────────────────────────
alter table sem_celulas     enable row level security;
alter table sem_comentarios enable row level security;

drop policy if exists sem_celulas_read on sem_celulas;
create policy sem_celulas_read on sem_celulas for select to authenticated
  using (sem_rol() is not null);

drop policy if exists sem_celulas_admin on sem_celulas;
create policy sem_celulas_admin on sem_celulas for all to authenticated
  using (sem_rol() = 'admin') with check (sem_rol() = 'admin');

-- Los comentarios los lee cualquiera y los escribe quien puede cargar la marca.
drop policy if exists sem_coment_read on sem_comentarios;
create policy sem_coment_read on sem_comentarios for select to authenticated
  using (sem_rol() is not null);

drop policy if exists sem_coment_write on sem_comentarios;
create policy sem_coment_write on sem_comentarios for all to authenticated
  using (exists (select 1 from sem_registros r
                  where r.id = registro_id and sem_puede_editar(r.marca_id)))
  with check (exists (select 1 from sem_registros r
                  where r.id = registro_id and sem_puede_editar(r.marca_id)));

-- ── Células iniciales ───────────────────────────────────────────────────────
-- Si el sistema de slots ya tiene células cargadas, las copia. Si no existe,
-- no hace nada y las cargás a mano desde la solapa Marcas.
do $$
begin
  if to_regclass('public.slot_celulas') is not null then
    insert into sem_celulas (nombre)
    select distinct nombre from slot_celulas
    on conflict (nombre) do nothing;
  end if;
end $$;

select 'células' as que, count(*)::text as cuantas from sem_celulas
union all select 'marcas sin célula', count(*)::text from sem_marcas where celula_id is null;
