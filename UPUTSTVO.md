# eBex — uputstvo za postavljanje (samo pregledač, bez instalacija)

Ukupno vreme: oko 30 minuta. Koristi **Google Chrome** (prevlačenje foldera na GitHub najpouzdanije radi u njemu).

Potrebno: GitHub nalog, Supabase nalog, telefon sa aplikacijom **Google Authenticator** ili **Microsoft Authenticator** (za administratorsku prijavu).

Nazivi dugmadi na GitHub-u i Supabase-u su na engleskom, pa su ovde navedeni tačno kako ih vidiš na ekranu.

---

## Korak 1 — Raspakuj ZIP

1. Dvaput klikni na `ebex.zip` u folderu Downloads.
2. Nastaje folder `ebex`. Otvori ga. Unutra su `index.html`, `admin.html`, `config.js`, folderi `supabase` i `docs` i nekoliko ikona.

## Korak 2 — Postavi fajlove na GitHub

1. Otvori github.com i prijavi se.
2. Gore desno klikni **+** → **New repository**.
3. **Repository name:** `ebex`. Izaberi **Public**. Ne štikliraj ništa drugo. Klikni **Create repository**.
4. Na stranici koja se otvori klikni link **uploading an existing file**.
5. U Finder-u, u folderu `ebex`, pritisni **Cmd + A** (označi sve) i prevuci sve u prozor pregledača.
   Važno: prevlačiš **sadržaj** foldera, ne sam folder `ebex`. Fajl `index.html` mora biti na vrhu repozitorijuma.
6. Sačekaj da se svi fajlovi učitaju, pa klikni zeleno dugme **Commit changes**.

## Korak 3 — Uključi web adresu (GitHub Pages)

1. U repozitorijumu klikni **Settings** (gore) → levo **Pages**.
2. Pod **Build and deployment**: **Source** = **Deploy from a branch**, **Branch** = **main**, folder **/ (root)** → **Save**.
3. Posle 1–2 minuta osveži stranicu. Gore piše adresa oblika `https://TVOJE-IME.github.io/ebex/`. Zapiši je.
   Ako otvoriš adresu sada, videćeš poruku „Aplikacija još nije povezana sa bazom”. To je očekivano.

## Korak 4 — Napravi bazu u Supabase-u

1. Otvori supabase.com → **Sign in** (može preko GitHub naloga).
2. **New project** → ime `ebex-test` → **Database Password**: klikni **Generate a password** i sačuvaj lozinku → **Region**: Central EU (Frankfurt) → **Create new project**. Sačekaj 1–2 minuta.
   - Ako Supabase javi da si dostigao limit besplatnih projekata, ne koristi postojeći BALKAN HUB projekat (javni korisnici ne smeju deliti bazu sa internim aplikacijama). Pauziraj neki neaktivan projekat ili napravi novu organizaciju.
3. **Isključi potvrdu e-pošte (samo za test):** levo **Authentication** → **Sign In / Providers** → **Email** → isključi **Confirm email** → **Save**.
   Ako se meni zove drugačije, traži prekidač „Confirm email”. Razlog: ugrađeni Supabase servis za e-poštu ne šalje poruke spoljnim adresama.

## Korak 5 — Pokreni SQL skriptu (pravi sve tabele i pravila)

1. Vrati se na GitHub, u svoj repozitorijum → otvori folder `supabase` → klikni `ebex_schema.sql`.
2. Gore desno iznad teksta klikni ikonicu **Copy raw file** (dva pravougaonika).
3. U Supabase-u levo klikni **SQL Editor** → **+** (New query).
4. Klikni u prazno polje, pritisni **Cmd + V**, pa **Run** (ili Cmd + Enter).
5. Ako iskoči upozorenje o „destructive operations”, klikni **Run this query**. Skripta ne briše podatke; upozorenje se javlja zbog reči `drop policy`, kojima se pravila osvežavaju.
6. Ispravan rezultat: **Success. No rows returned.**
   Ako vidiš crvenu grešku, kopiraj mi njen tekst. Skriptu je bezbedno pokrenuti ponovo.

## Korak 6 — Poveži aplikaciju sa bazom (config.js)

1. U Supabase-u levo dole **Project Settings** → **API Keys**.
2. Kopiraj **Publishable key** (počinje sa `sb_publishable_`).
   - Ako ga nema, klikni dugme za pravljenje novog API ključa, ili privremeno koristi **anon public** ključ sa kartice **Legacy API Keys**.
   - **Nikada ne kopiraj Secret ni service_role ključ.**
3. Adresu projekta vidiš kada klikneš dugme **Connect** na vrhu projekta. Oblik je `https://abcdefgh.supabase.co`.
4. Na GitHub-u otvori fajl `config.js` → gore desno ikonica **olovke** (Edit this file).
5. Zameni dve vrednosti između navodnika:
   - `OVDE-UPISI-PROJEKAT` → ceo deo adrese, tako da red izgleda ovako: `SUPABASE_URL: "https://abcdefgh.supabase.co",`
   - `OVDE-NALEPI-PUBLISHABLE-ILI-ANON-KLJUC` → ključ iz tačke 2.
6. Klikni **Commit changes…** → u prozoru ponovo **Commit changes**.
7. Sačekaj 1 minut i otvori svoju adresu iz koraka 3. Treba da vidiš početnu stranu eBex-a.

## Korak 7 — Napravi svoj nalog i postani administrator

1. Na eBex adresi klikni **Prijava** → **Novi nalog**. Upiši ime, svoju e-adresu i lozinku. Štikliraj obavezna polja → **Napravi nalog**.
2. U Supabase-u → **SQL Editor** → **+** → nalepi tekst ispod, **zameni e-adresu svojom** → **Run**:

```sql
insert into public.admin_users (user_id, role)
select id, 'super_admin' from auth.users where email = 'ivan@balkanavto.si'
on conflict (user_id) do update set role = 'super_admin', active = true
returning user_id;
```

3. Rezultat mora pokazati **jedan red**. Ako je prazan, e-adresa se ne poklapa sa onom iz registracije.
4. Otvori `https://TVOJE-IME.github.io/ebex/admin.html` → prijavi se istom e-adresom i lozinkom.
5. Skeniraj QR kod aplikacijom Authenticator na telefonu → upiši šestocifreni kod → **Potvrdi i uključi**.
   Od sada se u administraciju ulazi lozinkom i kodom sa telefona.

**Ako izgubiš telefon sa Authenticator-om:** u SQL Editoru pokreni (sa svojom e-adresom):

```sql
delete from auth.mfa_factors
where user_id = (select id from auth.users where email = 'ivan@balkanavto.si');
```

Pri sledećoj prijavi u administraciju ponovo skeniraš novi QR kod.

## Korak 8 — Instalacija na telefon

- **iPhone (Safari):** otvori adresu → dugme **Podeli** → **Dodaj na početni ekran**.
- **Android (Chrome):** otvori adresu → meni ⋮ → **Instaliraj aplikaciju** (ili **Dodaj na početni ekran**).

---

## Korak 9 — Probni krug (oko 15 minuta)

Trebaju ti dva korisnika: **prodavac** (to si ti) i **kupac**. Kupca otvori u privatnom prozoru (Chrome: **Cmd + Shift + N**) sa drugom e-adresom koju kontrolišeš.
U test režimu SMS se ne šalje: kod se prikazuje na ekranu. Brojevi telefona mogu biti izmišljeni, ali moraju biti različiti. Na primer: prodavac `060 000 0001`, kupac `060 000 0002`.

**Prodavac (ti):**
1. **Profil** → **Mobilni telefon** → upiši broj → **Pošalji kod** → upiši prikazani kod → **Potvrdi**.
2. **Podaci za isplatu** → ime i prezime → **Sačuvaj ime**.
3. **Račun za isplatu** → test račun `260-0056010016113-79`, vlasnik isto ime i prezime → **Dodaj račun**.
4. **Adresa preuzimanja** → popuni → **Sačuvaj**.
5. **Objavi** → dodaj bilo koju fotografiju, naslov, kategoriju, cenu **25000**, „Kupi odmah”, paket „Mali” → štikliraj potvrdu → **Objavi oglas**.

**Administrator (ti, u admin.html):**
6. **Korisnici i računi** → kod svog naloga klikni **Identitet ✓**, pa **Račun ✓** (upiši kratko obrazloženje).

**Kupac (privatni prozor):**
7. Registracija → **Profil** → potvrdi telefon `060 000 0002`.
8. Otvori oglas → **Kupi — plaćam pouzećem** → popuni adresu → **Potvrdi porudžbinu**.
9. Probaj i blokadu kontakta: na oglasu klikni **Postavi pitanje prodavcu** i napiši „pozovi me na 064 123 4567”. Poruka neće biti isporučena.

**Prodavac:**
10. **Porudžbine** → **Prodaje** → otvori porudžbinu. Zbog vrednosti od 20.000 RSD i više traže se 4 fotografije pakovanja: dodaj ih, pa klikni **Paket je spakovan — prijavi BEX-u**.

**Administrator → Porudžbine i BEX → otvori porudžbinu:**
11. BEX simulator: **BEX preuzeo paket**, zatim **Uručeno i naplaćeno pouzeće**.
12. Klikni **Pošalji poslednji događaj ponovo**. Rezultat mora biti `DUPLICATE`, bez nove stavke u knjizi.

**Kupac:**
13. Otvori porudžbinu → **Prijavi problem sa pošiljkom** → razlog i opis → **Pošalji reklamaciju**. Isplata prodavcu prelazi u „Zadržana”.

**Administrator:**
14. **Reklamacije i zadržavanja** → **U korist prodavca** → obrazloženje. Isplata je deblokirana.
15. Otvori porudžbinu → **BEX izvršio isplatu**. Status postaje `COMPLETED`.
    Dugme **Simuliraj dospele BEX isplate** u sekciji **Poslovi** isplaćuje tek kada stigne očekivani datum (naredni radni dan), zato ovde koristiš dugme u porudžbini.
16. **Usaglašavanje i knjiga** → „Ukupno (mora biti 0)” mora biti **0 RSD**.
17. **Revizijski trag** → vidiš ko je šta uradio, kada i zašto.

Ako se negde zaglaviš, pošalji mi sliku ekrana i broj koraka.

---

## Šta je simulirano (ne sme u javnu upotrebu)

- BEX dostava, naplata pouzeća i isplata (simulator u admin portalu)
- SMS kod (prikazuje se na ekranu)
- Provera identiteta i računa (ručno, od strane administratora)
- Cene dostave (pretpostavljene, nisu BEX cenovnik)
- Uslovi korišćenja i politika privatnosti (nacrt)

Detalji su u `docs/registar-odluka.md`.
