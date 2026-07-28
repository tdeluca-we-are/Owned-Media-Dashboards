-- ═══════════════════════════════════════════════════════════════════════════
-- WE ARE — Accesos por mail
-- Correr DESPUÉS de slots-schema.sql, slots-seed.sql y slots-comercial.sql.
--
-- Antes slot_usuarios se apoyaba en el id de auth.users, así que no se podía
-- habilitar a alguien que nunca había entrado. Ahora la autorización se
-- guarda contra el mail y se vincula sola en el primer login.
-- ═══════════════════════════════════════════════════════════════════════════

-- ── Reestructura de slot_usuarios ───────────────────────────────────────────
alter table slot_usuarios add column if not exists id serial;
alter table slot_usuarios add column if not exists activo boolean not null default true;
alter table slot_usuarios add column if not exists invitado_por uuid;
alter table slot_usuarios add column if not exists ultimo_ingreso timestamptz;

-- user_id pasa a ser opcional: se completa cuando la persona entra por primera vez
alter table slot_usuarios drop constraint if exists slot_usuarios_pkey;
alter table slot_usuarios alter column user_id drop not null;
alter table slot_usuarios add primary key (id);

-- el mail es ahora la identidad
update slot_usuarios set email = lower(trim(email)) where email is not null;
alter table slot_usuarios alter column email set not null;

create unique index if not exists slot_usuarios_email_idx on slot_usuarios (lower(email));
create unique index if not exists slot_usuarios_uid_idx   on slot_usuarios (user_id) where user_id is not null;

-- ── Identidad del que está pidiendo ─────────────────────────────────────────
create or replace function slot_email() returns text
  language sql stable security definer set search_path = public, auth as $$
  select lower(email) from auth.users where id = auth.uid()
$$;

-- Ahora se resuelve por user_id o por mail, así el permiso funciona desde el
-- primer segundo aunque todavía no se haya vinculado la cuenta.
create or replace function slot_rol() returns text
  language sql stable security definer set search_path = public as $$
  select rol from slot_usuarios
   where activo and (user_id = auth.uid() or lower(email) = slot_email())
   limit 1
$$;

create or replace function slot_mi_lider() returns int
  language sql stable security definer set search_path = public as $$
  select lider_id from slot_usuarios
   where activo and (user_id = auth.uid() or lower(email) = slot_email())
   limit 1
$$;

-- ── Vinculación en el primer ingreso ────────────────────────────────────────
-- La app la llama después de loguear. Devuelve la fila del usuario.
create or replace function slot_vincular()
  returns setof slot_usuarios
  language plpgsql security definer set search_path = public as $$
begin
  update slot_usuarios
     set user_id = auth.uid(), ultimo_ingreso = now()
   where activo and lower(email) = slot_email()
     and (user_id is null or user_id = auth.uid());

  return query
    select * from slot_usuarios
     where activo and (user_id = auth.uid() or lower(email) = slot_email())
     limit 1;
end $$;

grant execute on function slot_vincular() to authenticated;
grant execute on function slot_email()    to authenticated;

-- ── Políticas ───────────────────────────────────────────────────────────────
drop policy if exists slot_usuarios_self on slot_usuarios;
create policy slot_usuarios_self on slot_usuarios for select to authenticated
  using (user_id = auth.uid() or lower(email) = slot_email() or slot_rol() = 'admin');

drop policy if exists slot_usuarios_admin on slot_usuarios;
create policy slot_usuarios_admin on slot_usuarios for all to authenticated
  using (slot_rol() = 'admin') with check (slot_rol() = 'admin');

-- ── Quién entró y quién no ──────────────────────────────────────────────────
create or replace view slot_v_accesos as
select u.id, u.email, u.nombre, u.rol, u.activo, u.lider_id,
       l.nombre as lider,
       (u.user_id is not null)                    as tiene_cuenta,
       (a.id is not null)                         as existe_en_auth,
       u.ultimo_ingreso,
       case
         when not u.activo                then 'desactivado'
         when a.id is null                then 'falta crear la cuenta'
         when u.user_id is null           then 'nunca entró'
         else 'activo'
       end as estado
  from slot_usuarios u
  left join slot_lideres l on l.id = u.lider_id
  left join auth.users   a on lower(a.email) = lower(u.email)
 -- la vista toca auth.users, así que corre elevada y hay que filtrar acá:
 -- sin esto cualquier logueado vería el padrón entero
 where slot_rol() = 'admin';

grant select on slot_v_accesos to authenticated;

select email, nombre, rol, estado from slot_v_accesos order by rol, nombre;
