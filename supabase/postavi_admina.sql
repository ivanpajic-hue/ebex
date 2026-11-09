-- eBex: dodela uloge glavnog administratora
-- 1) Prvo se registruj u aplikaciji (Prijava → Novi nalog).
-- 2) Zameni e-adresu ispod svojom i pokreni u Supabase → SQL Editor.
-- 3) Rezultat mora prikazati jedan red.
insert into public.admin_users (user_id, role)
select id, 'super_admin' from auth.users where email = 'ivan@balkanavto.si'
on conflict (user_id) do update set role = 'super_admin', active = true
returning user_id;
