-- ═══════════════════════════════════════════════════════════════════════════
-- WE ARE — Grilla comercial por mes
-- Correr DESPUÉS de slots-schema.sql y slots-seed.sql.
--
-- Replica la hoja COMERCIAL: cuántos slots hay para vender por célula,
-- servicio, grupo de tier y mes. Se carga a mano, como hoy.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Grupos de tier que usa comercial ────────────────────────────────────────
-- La hoja agrupa más grueso que la tabla de referencia: Tier 2 y 3 van juntos,
-- y Tier 4 va con el 5 (que hoy no existe). Complejo va aparte.
alter table slot_tiers add column if not exists bucket text;

update slot_tiers set bucket = case codigo
  when 'complejo' then 'complejo'
  when '1' then '1'
  when '2' then '2-3'
  when '3' then '2-3'
  when '4' then '4-5'
end;

create table if not exists slot_buckets (
  codigo  text primary key,
  nombre  text not null,
  orden   int not null
);
insert into slot_buckets (codigo, nombre, orden) values
  ('complejo','Complejo',1), ('1','Tier 1',2), ('2-3','Tier 2-3',3), ('4-5','Tier 4-5',4)
on conflict (codigo) do nothing;

-- ── La grilla ───────────────────────────────────────────────────────────────
-- mes se guarda como el primer día del mes.
create table if not exists slot_comercial (
  id          serial primary key,
  celula_id   int  not null references slot_celulas(id) on delete cascade,
  servicio_id int  not null references slot_servicios(id) on delete cascade,
  bucket      text not null references slot_buckets(codigo),
  mes         date not null,
  cantidad    int  not null default 0 check (cantidad >= 0),
  nota        text,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  unique (celula_id, servicio_id, bucket, mes)
);

create index if not exists slot_comercial_mes_idx on slot_comercial(mes);

drop trigger if exists slot_comercial_touch on slot_comercial;
create trigger slot_comercial_touch before update on slot_comercial
  for each row execute function slot_touch();

alter table slot_comercial enable row level security;
alter table slot_buckets   enable row level security;

drop policy if exists slot_comercial_read on slot_comercial;
create policy slot_comercial_read on slot_comercial for select to authenticated
  using (slot_rol() is not null);

-- Cargan los líderes y los admin. Comercial solo lee.
drop policy if exists slot_comercial_write on slot_comercial;
create policy slot_comercial_write on slot_comercial for all to authenticated
  using (slot_rol() in ('admin','lider')) with check (slot_rol() in ('admin','lider'));

drop policy if exists slot_buckets_read on slot_buckets;
create policy slot_buckets_read on slot_buckets for select to authenticated
  using (slot_rol() is not null);

-- ── Contraste: lo cargado a mano vs lo que dicen las cuentas ────────────────
-- Sirve para detectar cuándo la grilla quedó vieja respecto de las
-- asignaciones reales. No corrige nada, solo muestra la diferencia.
create or replace view slot_v_comercial_control as
select
  c.nombre  as celula,
  s.nombre  as servicio,
  sum(g.cantidad)                              as cargado_a_mano,
  coalesce(max(o.libres_calculados), 0)        as libres_segun_cuentas
from slot_comercial g
join slot_celulas   c on c.id = g.celula_id
join slot_servicios s on s.id = g.servicio_id
left join lateral (
  select sum(greatest(o2.vendible, 0)) as libres_calculados
  from slot_v_ocupacion o2
  where o2.celula_id = g.celula_id and o2.servicio_id = g.servicio_id and o2.activa
) o on true
where g.mes = date_trunc('month', current_date)::date
group by c.nombre, s.nombre;

-- ── Nombres completos de los líderes ────────────────────────────────────────
-- La planilla usaba apodos. Se guarda el apodo como referencia.
alter table slot_lideres add column if not exists apodo text;

update slot_lideres set apodo = nombre where apodo is null;

update slot_lideres set nombre = 'Mariana'   where apodo = 'Mariana';
update slot_lideres set nombre = 'Tomás'     where apodo = 'Tomi';
update slot_lideres set nombre = 'Gastón'    where apodo = 'Gasti';
update slot_lideres set nombre = 'Mercedes'  where apodo = 'Mecha';
update slot_lideres set nombre = 'Pilar'     where apodo = 'Pili';
update slot_lideres set nombre = 'Andrés'    where apodo = 'Andy';
-- Dolores ↔ "Flor": mapeo por descarte, confirmar antes de darle acceso.
update slot_lideres set nombre = 'Dolores'   where apodo = 'Flor';

select codigo, nombre, orden from slot_buckets order by orden;
select id, nombre, apodo from slot_lideres order by nombre;
