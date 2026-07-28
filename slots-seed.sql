-- ═══════════════════════════════════════════════════════════════════════════
-- WE ARE — Migración de la hoja EQUIPO al sistema de slots
-- Correr DESPUÉS de slots-schema.sql. Se puede correr más de una vez.
--
-- Los nombres de cuenta vienen normalizados: la planilla escribía la misma
-- marca de varias formas (Rio Lenceria / Rio lencería / RIO GROUP S.R.L.).
-- Lo que quedó ambiguo se marca revisar = true en vez de adivinar.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Reconciliación ──────────────────────────────────────────────────────────
-- La planilla declaraba a mano cuántas cuentas activas / bajas / cierres tenía
-- cada uno, y esos números no coinciden con las cuentas realmente listadas al
-- lado. Guardamos lo declarado para que cada líder resuelva la diferencia en la
-- app, en vez de perderla silenciosamente en la migración.
create table if not exists slot_reconciliacion (
  persona_id           int primary key references slot_personas(id) on delete cascade,
  planilla_activas     int,
  planilla_bajas       int,
  planilla_cierres     int,
  planilla_cap         numeric(5,2),
  planilla_vendible    numeric(5,2),
  resuelto             boolean not null default false,
  resuelto_at          timestamptz
);
alter table slot_reconciliacion enable row level security;
drop policy if exists slot_recon_read on slot_reconciliacion;
create policy slot_recon_read on slot_reconciliacion for select to authenticated
  using (slot_rol() is not null);
drop policy if exists slot_recon_write on slot_reconciliacion;
create policy slot_recon_write on slot_reconciliacion for all to authenticated
  using (slot_puede_editar(persona_id)) with check (slot_puede_editar(persona_id));

-- ── Líderes ─────────────────────────────────────────────────────────────────
insert into slot_lideres (nombre) values
  ('Juan'),('Antonella'),('Mariana'),('Gasti'),('Flor'),
  ('Mecha'),('Tomi'),('Pili'),('Carla'),('Andy')
on conflict (nombre) do nothing;

-- ═══════════════════════════════════════════════════════════════════════════
-- Datos crudos de la hoja EQUIPO, ya normalizados.
-- cuentas separadas por ';'  ·  cuentas vacío = fila sin cuentas en la planilla
-- ═══════════════════════════════════════════════════════════════════════════
drop table if exists _equipo;
create temp table _equipo (
  nombre    text,
  servicio  text,
  rol       text,
  lider     text,
  celula    text,
  cuartil   numeric(3,1),
  cap_max   numeric(5,2),
  p_activas int,
  p_bajas   int,
  p_cierres int,
  p_vend    numeric(5,2),
  nota      text,
  cuentas   text
);

insert into _equipo (nombre, servicio, rol, lider, celula, cuartil, cap_max, p_activas, p_bajas, p_cierres, p_vend, nota, cuentas) values
-- ── GE 360 (KAM) / CSE (Fronter) ────────────────────────────────────────────
('Delfina Enrico','GE 360 (KAM)','KAM','Juan','Célula Delfi Enrico',2.3,4,4,0,0,0,null,
  'Randers;Telas;Leder;Telas x metro'),
('Gaby','GE 360 (KAM)','KAM','Juan','Célula Gabriel Villareal',2.1,5,4,0,0,1,null,
  'Endavant;Brujo Sport;Habitar;UB Cuarenta'),
('Nacho','GE 360 (KAM)','KAM','Juan','Célula Nacho',2.3,4,4,0,0,0,null,
  'King of the Kongo;Sevensport;Chelsea;Exit'),
('Hector','GE 360 (KAM)','KAM','Juan','Célula Hector',2.2,5,5,0,0,0,null,
  'Cavatini;Cipitria;Baires4;Deville;Harvey Willys'),
('Mica Bancheri','GE 360 (KAM)','KAM','Juan','Célula Hector',2.1,3,1,0,0,2,null,
  'Fika Home;Ana Pugliesi'),
('Orne','CSE (Fronter)','CSE','Antonella','Célula Delfi, Hector y Nacho',2.1,8,7,0,0,1,null,
  'Iman;Suavestar;Cannon;Rosen;Mamy Blue;Cebra;Bremen'),
('Sofia Catera','GE 360 (KAM)','KAM','Mariana','Célula Sofia Catera',2.5,4,4,0,0,0,null,
  'Multipoint;Rainbow;Selú;Nathan Home'),
('Tamara','GE 360 (KAM)','KAM','Mariana','Célula Tamara',2.3,5,5,0,0,0,null,
  'Grupo Fava;Inpro Argentina;Green Deco;Neonix;Full Regalos'),
('Rocío','GE 360 (KAM)','KAM','Mariana','Célula Romina, Silvana y Rocío',2.4,5,5,0,0,0,null,
  'Rio Lencería Minorista;Rio Lencería Mayorista;Perramus;Bridgestone;Firestone'),
('Romi Rita','GE 360 (KAM)','KAM','Mariana','Célula Romina, Silvana y Rocío',2.3,5,5,0,0,0,
  'La planilla anotaba "Chemes (x2)" — verificar si son dos cuentas separadas',
  'Chemes;Admit One;Nor;Farmafull'),
('Delfi Longo','CSE (Fronter)','CSE','Antonella','Célula Delfi Longo',2.2,8,7,0,0,1,null,
  'Todo Visión;Flux;Piero;HV Colon;Muresco;Carmela Achaval;Vstore;Chemes'),
('Agos','GE 360 (KAM)','KAM',null,'Célula Sofia Catera',2.1,5,3,0,0,2,
  'Sin líder asignado en la planilla',
  'Mateu;Melocotón'),

-- ── Paid (Strategist) ───────────────────────────────────────────────────────
('Agus Canfora','Paid (Strategist)','Paid (Strategist)','Gasti','Célula Delfi Enrico',2.4,6,6,0,0,0,null,
  'Randers;Telas;Leder;Telas x metro;Iman'),
('Valentina Soneira','Paid (Strategist)','Paid (Strategist)','Flor','Célula Nacho',2.5,6,6,0,0,0,null,
  'King of the Kongo;King of the Kongo - Branding;Sevensport;Chelsea;Suavestar;Exit'),
('Malena Rubianes','Paid (Strategist)','Paid (Strategist)','Gasti','Célula Hector',2.3,7,7,0,0,0,null,
  'Baires4;Cipitria;Vstore;Rosen;Fika Home;Deville;Broer'),
('Sofia Dominguez','Paid (Strategist)','Paid (Strategist)','Gasti','Célula Orne',2.5,4,4,0,0,0,null,
  'Exit;Cannon;Cebra;Mamy Blue;Iman;Suavestar'),
('Cata Kelso','Paid (Strategist)','Paid (Strategist)','Gasti','Célula Sofia Catera',2.4,5,5,0,0,0,null,
  'Selú Perfo;Selú Branding;Rainbow;STI;Nathan Home;Habitar'),
('Candela Pacheco','Paid (Strategist)','Paid (Strategist)','Mecha','Célula Tamara',2.4,5,5,0,0,0,null,
  'Grupo Fava;Green Deco;Inpro Argentina;Neonix;Full Regalos'),
('Jose Zamorano','Paid (Strategist)','Paid (Strategist)','Gasti','Célula Romina, Silvana y Rocío',2.4,6,6,0,0,0,null,
  'Rio Lencería Mayorista;Rio Lencería Minorista;Chemes;Melocotón;Admit One;Farmafull;Nor'),
('GMO','Paid (Strategist)','Paid (Strategist)',null,'Célula Romina, Silvana y Rocío',null,0,0,0,0,0,
  'Fila sin cuartil ni capacidad en la planilla — completar',
  ''),
('Luisa Siri','Paid (Strategist)','Paid (Strategist)','Flor','Célula Delfi Longo',2.2,6,6,0,0,0,null,
  'Todo Visión;Flux;Brujo Sport;Piero;Carmela Achaval;Cloetas'),

-- ── Implementador Paid ──────────────────────────────────────────────────────
('Ivan Perez','Implementador Paid','Implementador Paid','Gasti','Célula Delfi Enrico',1.3,6,6,0,0,0,null,
  'Randers;Telas;Leder;Telas x metro;Iman'),
('Conrado Pereyra','Implementador Paid','Implementador Paid','Flor','Célula Nacho',1.4,6,6,0,0,0,null,
  'King of the Kongo;King of the Kongo - Branding;Sevensport;Chelsea;Suavestar;Exit'),
('Frederik Garcia','Implementador Paid','Implementador Paid','Flor','Célula Hector',2.2,7,7,0,0,0,
  'La planilla aclaraba "Rosen (como Strategist)"',
  'Baires4;Cipitria;Vstore;Fika Home;Deville;Broer;Rosen'),
('Vacante — Paid Orne','Implementador Paid','Implementador Paid','Gasti',null,2.2,4,4,0,0,0,
  'Fila sin nombre en la planilla',
  'Exit;Cannon;Cebra;Mamy Blue;Iman;Suavestar'),
('Jesus Alvia','Implementador Paid','Implementador Paid','Gasti','Célula Sofia Catera',1.4,5,5,0,0,0,null,
  'Selú Perfo;Selú Branding;Rainbow;STI;Nathan Home'),
('Vacante — Paid Tamara','Implementador Paid','Implementador Paid','Mecha','Célula Tamara',2.2,5,5,0,0,0,
  'Fila sin nombre en la planilla',
  'Grupo Fava;Green Deco;Inpro Argentina;Neonix;Full Regalos'),
('Lautaro Leys','Implementador Paid','Implementador Paid','Gasti','Célula Romina, Silvana y Rocío',2.4,6,6,0,0,0,null,
  'Rio Lencería Mayorista;Rio Lencería Minorista;Chemes;Melocotón;Admit One;Farmafull;Nor'),
('Vacante — Paid Romina','Implementador Paid','Implementador Paid','Gasti','Célula Romina, Silvana y Rocío',2.2,0,0,0,0,0,
  'Fila sin nombre ni capacidad en la planilla',
  ''),
('Pato Tewes','Implementador Paid','Implementador Paid','Flor','Célula Delfi Longo',1.2,6,6,0,0,0,null,
  'Todo Visión;Flux;Brujo Sport;Piero;Carmela Achaval;Cloetas'),

-- ── Email ───────────────────────────────────────────────────────────────────
('Tomy','Email','Email','Tomi','Célula Hector - Romi',3.1,5,9,0,0,0,
  'Sobrecargado en la planilla: capacidad 5 con 9 cuentas, y aun así figuraba 0 slots vendibles',
  'Sancor;Tienda Newsan;La Dolfina;Admit One;Atma - Philco - Noblex;Deville;Bridgestone;Farmafull;Vstore'),
('Penny','Email','Email - Strategist','Tomi','Célula Sofia Catera',2.5,5,4,0,0,1,null,
  'Juanita Jo;Santa Clara;Rainbow;Selú'),
('Javi','Email','Email - Implementador','Tomi','Célula Nacho',2.2,5,4,0,0,1,
  'Sin tier declarado en la planilla',
  'King of the Kongo;Sevensport;Chelsea;Juanita Jo;Santa Clara;Rainbow;Selú'),
('Juli','Email','Email - Implementador','Tomi','Célula Delfi - Hector',2.3,5,5,0,0,0,
  'Sin tier declarado en la planilla',
  'Randers;Telas;Telas x metro;Baires4;Cipitria'),

-- ── Diseño ──────────────────────────────────────────────────────────────────
('Wendy','Diseño','Diseño','Pili','Célula Delfi Enrico',2.3,8,7,0,0,1,null,
  'Randers;Telas;Telas x metro;Rosen;Gani;Flux;Bridgestone'),
('Mateo','Diseño','Diseño','Pili','Célula Delfi Longo',2.2,7,4,0,0,3,null,
  'Baires4;Todo Visión;Brujo Sport;Suavegon'),
('Euge','Diseño','Diseño','Pili','Célula Sofia Catera',2.3,6,6,0,0,0,null,
  'Grupo Fava;Rainbow;Vstore;Tienda Newsan;Sancor;HRO'),
('Andre','Diseño','Diseño','Pili','Célula Romina',2.5,6,6,0,0,0,null,
  'Rio Lencería;Chemes;Cannon;Piero;Suavestar;MKT Interno'),

-- ── Redes ───────────────────────────────────────────────────────────────────
('Charlotte','Redes','Redes','Pili','Célula Delfi Enrico',2.3,4,4,0,0,0,null,
  'Randers;Telas;Telas x metro;Smiling'),
('Mora','Redes','Redes','Pili','Célula Sofia Catera',2.3,4,3,0,1,0,null,
  'Rainbow;Saint Chobet;Bridgestone'),
('Alejo','Redes','Redes','Pili','Célula Rocío',2.4,3,2,0,0,1,null,
  'Rio Lencería;Tienda Newsan'),
('Diego','Redes','Redes','Pili','Célula Tito, Célula Delfi Longo',2.4,3,2,0,0,1,null,
  'Baires4;Todo Visión'),
('Agus','Redes','Redes','Pili','Célula Delfi Longo',2.3,4,4,0,0,0,null,
  'Brujo Sport;HV Colon;Firestone;HRO'),

-- ── Marketplace / Operaciones ───────────────────────────────────────────────
('Carla Lovero','Marketplace','Líder Marketplace','Carla','Célula Delfi E. Tamara, Delfi L.',3.1,5,3,0,0,2,null,
  'Telas;Inpro Argentina;Muresco'),
('Sofia','Marketplace','Kam Marketplace','Carla','Célula Tamara, Rocío, Sin Célula, Delfi Enrico',2.2,5,4,1,0,2,null,
  'Neonix;Harvey Willys;Milky Gang;Telas x metro'),
('Maite','Operaciones','Kam Operaciones','Carla','Célula Delfi Longo, Sin célula',2.2,5,3,0,1,1,
  'En la planilla el líder figuraba como "Carla/Andy"',
  'Brujo Sport;Burlot;HRO;Nor'),
('Carla Perez','Operaciones','Analista Operaciones','Carla','Célula Romina, Delfi Longo',1.3,5,3,0,0,2,null,
  'Muresco;Chemes;Operaciones Marketplace'),

-- ── PM ──────────────────────────────────────────────────────────────────────
('Rebe','PM','PM','Andy','Célula Orne, Célula Romina, Célula Rocío',2.3,6,4,1,1,2,null,
  'Mamy Blue;Rio Lencería;Reform;Fibra Humana;Rochas'),
('Dani','PM','PM','Andy','Célula Romina, Sin célula',2.4,6,4,1,0,3,null,
  'Skin Beauty;Admit One;Rainbow;Drinksfood'),
('Pili','PM','PM','Andy','Célula Sofia Catera',4.1,1,1,0,0,0,null,
  'Multipoint'),
('Nahue','PM','PM','Andy','Célula Agostina, Célula Hector, Sin célula',2.2,5,5,2,0,2,null,
  'Melocotón;Cipitria;Leven;Nor;UB Cuarenta'),

-- ── DDD ─────────────────────────────────────────────────────────────────────
('Mecha/Ichu','DDD','DDD',null,'Célula Delfi Longo',2.4,4,3,0,0,1,
  'La planilla anotaba "Feedom (6 cuentas)" — verificar si son seis cuentas separadas',
  'Flux;Feedom;Rocks');

-- ── Células (se crean tal como venían, para no inventar estructura) ──────────
insert into slot_celulas (nombre)
select distinct celula from _equipo where celula is not null
on conflict (nombre) do nothing;

-- ── Cuentas ─────────────────────────────────────────────────────────────────
insert into slot_cuentas (nombre)
select distinct trim(x.raw)
from _equipo e, unnest(string_to_array(e.cuentas, ';')) as x(raw)
where trim(x.raw) <> ''
on conflict (nombre) do nothing;

-- Lo que quedó ambiguo al normalizar, marcado para que alguien decida.
update slot_cuentas set revisar = true, nota = 'La planilla decía solo "Rio Lenceria" sin aclarar si es Minorista o Mayorista'
  where nombre = 'Rio Lencería';
update slot_cuentas set revisar = true, nota = 'No es una cuenta de cliente — es trabajo interno ocupando un slot'
  where nombre in ('MKT Interno','Operaciones Marketplace');
update slot_cuentas set revisar = true, nota = 'Verificar si es una cuenta separada o parte de la cuenta madre'
  where nombre in ('King of the Kongo - Branding','Selú Perfo','Selú Branding');

-- ── Personas ────────────────────────────────────────────────────────────────
insert into slot_personas (nombre, servicio_id, rol, cuartil, cap_max, lider_id, celula_id, nota)
select e.nombre, s.id, e.rol, e.cuartil, e.cap_max, l.id, c.id, e.nota
from _equipo e
join slot_servicios s on s.nombre = e.servicio
left join slot_lideres l on l.nombre = e.lider
left join slot_celulas c on c.nombre = e.celula
on conflict (nombre, servicio_id) do update
  set rol = excluded.rol, cuartil = excluded.cuartil, cap_max = excluded.cap_max,
      lider_id = excluded.lider_id, celula_id = excluded.celula_id, nota = excluded.nota;

-- ── Asignaciones ────────────────────────────────────────────────────────────
insert into slot_asignaciones (persona_id, cuenta_id, servicio_id, estado)
select p.id, cu.id, p.servicio_id, 'activa'
from _equipo e
join slot_servicios s on s.nombre = e.servicio
join slot_personas p on p.nombre = e.nombre and p.servicio_id = s.id
cross join lateral unnest(string_to_array(e.cuentas, ';')) as x(raw)
join slot_cuentas cu on cu.nombre = trim(x.raw)
where trim(x.raw) <> ''
on conflict (persona_id, cuenta_id, servicio_id) do nothing;

-- ── Reconciliación: lo que la planilla declaraba ────────────────────────────
insert into slot_reconciliacion (persona_id, planilla_activas, planilla_bajas, planilla_cierres, planilla_cap, planilla_vendible)
select p.id, e.p_activas, e.p_bajas, e.p_cierres, e.cap_max, e.p_vend
from _equipo e
join slot_servicios s on s.nombre = e.servicio
join slot_personas p on p.nombre = e.nombre and p.servicio_id = s.id
on conflict (persona_id) do update
  set planilla_activas = excluded.planilla_activas,
      planilla_bajas   = excluded.planilla_bajas,
      planilla_cierres = excluded.planilla_cierres,
      planilla_cap     = excluded.planilla_cap,
      planilla_vendible= excluded.planilla_vendible;

drop table _equipo;

-- ── Vista de reconciliación ─────────────────────────────────────────────────
-- Dónde el conteo real difiere de lo que decía la planilla.
create or replace view slot_v_reconciliacion as
select
  o.persona_id, o.nombre, o.servicio, o.lider, o.celula,
  r.planilla_activas, o.cuentas_activas as reales,
  o.cuentas_activas - r.planilla_activas as diferencia,
  r.planilla_bajas, r.planilla_cierres,
  r.planilla_vendible, round(o.vendible, 2) as vendible_calculado,
  r.resuelto
from slot_v_ocupacion o
join slot_reconciliacion r on r.persona_id = o.persona_id
where not r.resuelto
  and (o.cuentas_activas <> r.planilla_activas
       or r.planilla_bajas > 0 or r.planilla_cierres > 0);

-- ── Verificación ────────────────────────────────────────────────────────────
select 'personas' as tabla, count(*) from slot_personas
union all select 'cuentas', count(*) from slot_cuentas
union all select 'asignaciones', count(*) from slot_asignaciones
union all select 'células', count(*) from slot_celulas
union all select 'a reconciliar', count(*) from slot_v_reconciliacion;
