-- ═══════════════════════════════════════════════════════════════════════════
-- WE ARE — Calendario de Owned Media (Email · Push · WhatsApp)
--
-- Armado mensual del calendario de envíos por marca, con memoria de lo que
-- pasó: cada envío queda guardado con su estado final (enviado / cancelado),
-- y cada marca-mes guarda el foco y los aprendizajes para usar en el siguiente.
--
-- Las marcas y las células salen del semáforo (sem_marcas / sem_celulas):
-- correr DESPUÉS de semaforo-schema.sql y semaforo-v2.sql.
-- Todo con prefijo cal_. Se puede correr más de una vez.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── USUARIOS ────────────────────────────────────────────────────────────────
-- Mismo criterio que slots y semáforo: se autoriza el mail y la cuenta se
-- vincula sola en el primer login. Accesos propios porque quien arma
-- calendarios (equipo de Owned) no es la misma gente que carga el semáforo.
--   admin  : ve y edita todo
--   editor : ve y edita solo las marcas que tiene asignadas
--   lector : ve (sin editar) solo los calendarios de las marcas asignadas
create table if not exists cal_usuarios (
  id             serial primary key,
  email          text not null,
  nombre         text,
  rol            text not null default 'lector'
                 check (rol in ('admin','editor','lector')),
  activo         boolean not null default true,
  user_id        uuid,
  ultimo_ingreso timestamptz
);
-- El rol 'analista' pasó a llamarse 'editor' (07/10/2026). Si la tabla ya existía
-- con el check viejo, esto lo actualiza sin perder a nadie.
alter table cal_usuarios drop constraint if exists cal_usuarios_rol_check;
update cal_usuarios set rol = 'editor' where rol = 'analista';
alter table cal_usuarios add constraint cal_usuarios_rol_check
  check (rol in ('admin','editor','lector'));

create unique index if not exists cal_usuarios_email_idx on cal_usuarios (lower(email));
create unique index if not exists cal_usuarios_uid_idx   on cal_usuarios (user_id)
  where user_id is not null;

-- Qué marcas ve cada editor o lector. Los admin ven todas.
create table if not exists cal_usuario_marcas (
  usuario_id int not null references cal_usuarios(id) on delete cascade,
  marca_id   int not null references sem_marcas(id)   on delete cascade,
  primary key (usuario_id, marca_id)
);

-- Ojo: el mail tiene que ser el de Supabase Auth (@we-are.com.ar).
insert into cal_usuarios (email, nombre, rol) values
  ('tdeluca@we-are.com.ar', 'Tomás De Luca', 'admin')
on conflict do nothing;

-- ── CONFIGURACIÓN POR MARCA ─────────────────────────────────────────────────
-- Canales que tiene la marca y reglas fijas que hay que respetar al armar
-- (días que no se envía, quién aprueba, frecuencia pactada, etc.).
create table if not exists cal_marca_config (
  marca_id       int primary key references sem_marcas(id) on delete cascade,
  canales        text[] not null default '{email,push,wpp}',
  reglas         text,
  actualizado_at timestamptz not null default now()
);

-- ── MARCA × MES ─────────────────────────────────────────────────────────────
-- El estado del calendario del mes y la memoria para el mes siguiente.
create table if not exists cal_meses (
  id              serial primary key,
  marca_id        int  not null references sem_marcas(id) on delete cascade,
  periodo         date not null check (extract(day from periodo) = 1),  -- siempre día 1
  estado          text not null default 'borrador'
                  check (estado in ('borrador','revision','aprobado','cerrado')),
  foco            text,   -- objetivo / foco comercial del mes
  funciono        text,   -- qué funcionó
  no_funciono     text,   -- qué no funcionó
  repetir         text,   -- qué repetir o probar el mes que viene
  actualizado_por text,
  actualizado_at  timestamptz not null default now(),
  unique (marca_id, periodo)
);
create index if not exists cal_meses_periodo_idx on cal_meses (periodo desc);

-- ── ENVÍOS ──────────────────────────────────────────────────────────────────
create table if not exists cal_envios (
  id             serial primary key,
  marca_id       int  not null references sem_marcas(id) on delete cascade,
  fecha          date not null,
  hora           text,                 -- 'HH:MM', opcional
  canal          text not null check (canal in ('email','push','wpp')),
  tipo           text,                 -- promo, newsletter, lanzamiento…
  titulo         text not null,        -- tema / nombre de la campaña
  asunto         text,                 -- asunto o copy
  segmento       text,
  notas          text,                 -- internas, no salen en la vista cliente
  estado         text not null default 'planificado'
                 check (estado in ('idea','planificado','aprobado','enviado','cancelado')),
  copiado_de     int references cal_envios(id) on delete set null,
  creado_por     text,
  creado_at      timestamptz not null default now(),
  actualizado_at timestamptz not null default now()
);
create index if not exists cal_envios_marca_fecha_idx on cal_envios (marca_id, fecha);
create index if not exists cal_envios_fecha_idx       on cal_envios (fecha);

-- Bandeja (07/10/2026): envíos del mes que todavía no tienen día. La fecha
-- queda en el mes al que pertenecen; bandeja = true los saca de la grilla.
alter table cal_envios add column if not exists bandeja boolean not null default false;

-- Orden dentro del día (07/10/2026): lo arma el usuario arrastrando en la lista.
alter table cal_envios add column if not exists orden int;

-- ── FECHAS CLAVE ────────────────────────────────────────────────────────────
-- marca_id null = fecha general (aparece en todas las marcas).
-- anual = se repite todos los años el mismo día (Navidad, San Valentín…).
create table if not exists cal_fechas (
  id        serial primary key,
  marca_id  int references sem_marcas(id) on delete cascade,
  fecha     date not null,
  hasta     date,
  nombre    text not null,
  anual     boolean not null default false,
  notas     text,
  creado_at timestamptz not null default now()
);
create index if not exists cal_fechas_fecha_idx on cal_fechas (fecha);

-- Tipo de acción (07/10/2026): bancaria, always on, comercial o microevento.
-- Las fechas generales (Navidad, Día de la Madre…) quedan sin categoría.
alter table cal_fechas add column if not exists categoria text;
alter table cal_fechas drop constraint if exists cal_fechas_categoria_check;
alter table cal_fechas add constraint cal_fechas_categoria_check
  check (categoria is null or categoria in ('bancaria','always_on','comercial','microevento'));

-- Fechas generales de arranque (solo si la tabla está vacía).
-- Las de fecha móvil van calculadas para 2026 y 2027; CyberMonday y Hot Sale
-- de Argentina cambian cada año: cargarlas cuando la CACE las anuncie.
insert into cal_fechas (fecha, nombre, anual)
select v.fecha::date, v.nombre, v.anual from (values
  ('2026-01-01', 'Año Nuevo',          true),
  ('2026-01-06', 'Reyes',              true),
  ('2026-02-14', 'San Valentín',       true),
  ('2026-07-20', 'Día del Amigo',      true),
  ('2026-12-24', 'Nochebuena',         true),
  ('2026-12-25', 'Navidad',            true),
  ('2026-06-21', 'Día del Padre',      false),
  ('2026-08-16', 'Día del Niño',       false),
  ('2026-10-18', 'Día de la Madre',    false),
  ('2026-11-27', 'Black Friday',       false),
  ('2026-11-30', 'Cyber Monday (US)',  false),
  ('2027-06-20', 'Día del Padre',      false),
  ('2027-08-15', 'Día del Niño',       false),
  ('2027-10-17', 'Día de la Madre',    false),
  ('2027-11-26', 'Black Friday',       false),
  ('2027-11-29', 'Cyber Monday (US)',  false)
) as v(fecha, nombre, anual)
where not exists (select 1 from cal_fechas);

-- ── IDENTIDAD Y PERMISOS ────────────────────────────────────────────────────
create or replace function cal_email() returns text
  language sql stable security definer set search_path = public, auth as $$
  select lower(email) from auth.users where id = auth.uid()
$$;

create or replace function cal_rol() returns text
  language sql stable security definer set search_path = public as $$
  select rol from cal_usuarios
   where activo and (user_id = auth.uid() or lower(email) = cal_email())
   limit 1
$$;

create or replace function cal_uid() returns int
  language sql stable security definer set search_path = public as $$
  select id from cal_usuarios
   where activo and (user_id = auth.uid() or lower(email) = cal_email())
   limit 1
$$;

-- Ver una marca: admin, o editor/lector que la tenga asignada.
create or replace function cal_puede_ver(m int) returns boolean
  language sql stable security definer set search_path = public as $$
  select cal_rol() = 'admin'
      or (cal_rol() is not null and exists (
            select 1 from cal_usuario_marcas um
             where um.usuario_id = cal_uid() and um.marca_id = m))
$$;

create or replace function cal_puede_editar(m int) returns boolean
  language sql stable security definer set search_path = public as $$
  select cal_rol() = 'admin'
      or (cal_rol() = 'editor' and exists (
            select 1 from cal_usuario_marcas um
             where um.usuario_id = cal_uid() and um.marca_id = m))
$$;

create or replace function cal_vincular()
  returns setof cal_usuarios
  language plpgsql security definer set search_path = public as $$
begin
  update cal_usuarios
     set user_id = auth.uid(), ultimo_ingreso = now()
   where activo and lower(email) = cal_email()
     and (user_id is null or user_id = auth.uid());

  return query
    select * from cal_usuarios
     where activo and (user_id = auth.uid() or lower(email) = cal_email())
     limit 1;
end $$;

grant execute on function cal_email(), cal_rol(), cal_uid(),
                          cal_puede_ver(int), cal_puede_editar(int), cal_vincular() to authenticated;

-- ── RLS ─────────────────────────────────────────────────────────────────────
alter table cal_usuarios       enable row level security;
alter table cal_usuario_marcas enable row level security;
alter table cal_marca_config   enable row level security;
alter table cal_meses          enable row level security;
alter table cal_envios         enable row level security;
alter table cal_fechas         enable row level security;

-- Lo que es de una marca: lo ve el admin o quien la tiene asignada; edita admin o su editor.
do $$
declare t text;
begin
  foreach t in array array['cal_marca_config','cal_meses','cal_envios'] loop
    execute format('drop policy if exists %I on %I', t || '_read', t);
    execute format('create policy %I on %I for select to authenticated
                    using (cal_puede_ver(marca_id))', t || '_read', t);
    execute format('drop policy if exists %I on %I', t || '_write', t);
    execute format('create policy %I on %I for all to authenticated
                    using (cal_puede_editar(marca_id)) with check (cal_puede_editar(marca_id))',
                   t || '_write', t);
  end loop;
end $$;

-- Fechas: las generales solo las toca el admin; las de marca, quien edita la marca.
drop policy if exists cal_fechas_read on cal_fechas;
create policy cal_fechas_read on cal_fechas for select to authenticated
  using (case when marca_id is null then cal_rol() is not null else cal_puede_ver(marca_id) end);

drop policy if exists cal_fechas_write on cal_fechas;
create policy cal_fechas_write on cal_fechas for all to authenticated
  using      (case when marca_id is null then cal_rol() = 'admin' else cal_puede_editar(marca_id) end)
  with check (case when marca_id is null then cal_rol() = 'admin' else cal_puede_editar(marca_id) end);

-- Usuarios: cada uno se ve a sí mismo; el admin ve y edita todo.
drop policy if exists cal_usuarios_self on cal_usuarios;
create policy cal_usuarios_self on cal_usuarios for select to authenticated
  using (user_id = auth.uid() or lower(email) = cal_email() or cal_rol() = 'admin');

drop policy if exists cal_usuarios_admin on cal_usuarios;
create policy cal_usuarios_admin on cal_usuarios for all to authenticated
  using (cal_rol() = 'admin') with check (cal_rol() = 'admin');

drop policy if exists cal_um_read on cal_usuario_marcas;
create policy cal_um_read on cal_usuario_marcas for select to authenticated
  using (cal_rol() = 'admin' or usuario_id = cal_uid());

drop policy if exists cal_um_admin on cal_usuario_marcas;
create policy cal_um_admin on cal_usuario_marcas for all to authenticated
  using (cal_rol() = 'admin') with check (cal_rol() = 'admin');

-- Las marcas y células son del semáforo: se suma una política de lectura para
-- que un usuario del calendario que no está en el semáforo también las vea.
-- (Las políticas se suman con OR; no cambia nada para el semáforo.)
drop policy if exists sem_marcas_cal_read on sem_marcas;
create policy sem_marcas_cal_read on sem_marcas for select to authenticated
  using (cal_puede_ver(id));

drop policy if exists sem_celulas_cal_read on sem_celulas;
create policy sem_celulas_cal_read on sem_celulas for select to authenticated
  using (cal_rol() is not null);

-- ── OPCIONAL: traer los accesos del semáforo ────────────────────────────────
-- insert into cal_usuarios (email, nombre, rol)
-- select email, nombre, rol from sem_usuarios where activo
-- on conflict do nothing;
