# eBex — Registar odluka

Verzija 1.0 · 9. 11. 2026. · Faza 1 (vertikalni presek, test okruženje)

Oznake: **Z** = zaključana poslovna odluka · **P** = pretpostavka do potvrde · **O** = odstupanje od master prompta · **B** = blokira javno puštanje

## 1. Arhitektura i odstupanja od master prompta

| ID | Odluka | Tip | Razlog | Šta treba za produkciju | Vlasnik |
|---|---|---|---|---|---|
| A-01 | Supabase (PostgreSQL, Auth, Storage, RPC) + statične stranice umesto NestJS, Redis, Docker i Terraform | O | Rad bez instalacija. Sva poslovna pravila su u PostgreSQL funkcijama, pa su prenosiva na veći sistem bez prepisivanja logike | ADR sa BEX IT-om: ostanak na Supabase-u ili prelazak na BEX infrastrukturu | Vlasnik proizvoda, BEX IT |
| A-02 | Mobilni pristup je PWA (instalacija sa početnog ekrana), ne aplikacija u App Store i Google Play | O, B | Zaključana odluka traži iOS i Android od početka; PWA to pokriva funkcionalno, ali ne i prisustvo u prodavnicama | Saglasnost vlasnika za pilot; kasnije omotač iste aplikacije (npr. Capacitor) i objava u prodavnicama | Vlasnik proizvoda |
| A-03 | Hosting: GitHub Pages, javni repozitorijum | P, B | Najjednostavnije postavljanje. Javni kod nije bezbednosni rizik jer bazu štite RLS pravila, ali po mom znanju uslovi GitHub Pages ne dozvoljavaju korišćenje za komercijalnu prodaju (proveriti pre pilota sa stvarnim korisnicima) | Komercijalni hosting (BEX server, Vercel Pro, Cloudflare Pages) | BEX IT |
| A-04 | Supabase region Frankfurt (EU) | P, B | Najbliži region za test | Pravna procena prenosa podataka o ličnosti van Srbije | Pravna služba |
| A-05 | Modularni monolit u bazi: 17 domena iz master prompta su razdvojeni po tabelama i funkcijama (identitet, oglasi, chat, narudžbine, pouzeće, isplate, BEX, reklamacije, rizik, admin, revizija) | Z | Master prompt traži modularni monolit, ne mikroservise | — | — |

## 2. Integracije (sve simulirane)

| ID | Odluka | Tip | Stanje | Šta blokira produkciju |
|---|---|---|---|---|
| I-01 | BEX dostava, naplata pouzeća i isplata | B | Simulator u admin portalu. Funkcija `process_bex_event` je idempotentna i spremna za BEX webhook (preko servisnog ključa) | Zvanična BEX API dokumentacija, test pristup, potvrda da BEX isplaćuje C2C prodavcima na njihov račun i da podržava zadržavanje isplate |
| I-02 | SMS verifikacija telefona | O, B | Kod se prikazuje na ekranu u test režimu; prijava je e-adresom i lozinkom, a telefon se obavezno potvrđuje posebnim korakom | SMS provajder i prijava telefonom (master prompt 6.1) |
| I-03 | Provera identiteta (KYC) i vlasništva računa | B | Ručna potvrda administratora, sa obaveznim obrazloženjem i revizijskim tragom | KYC provajder ili ugovoreni postupak sa BEX-om/bankom |
| I-04 | E-pošta | P | Potvrda e-adrese isključena u testu | Sopstveni SMTP servis, uključena potvrda e-adrese |
| I-05 | Push, SMS i e-mail obaveštenja | P | Samo obaveštenja u aplikaciji | Faza 2 |

## 3. Poslovne vrednosti (menjaju se u adminu → Podešavanja)

| Parametar | Trenutna vrednost | Tip | Potvrđuje |
|---|---|---|---|
| Cene BEX dostave | 450 / 550 / 700 / 950 / 1.250 RSD do 2 / 5 / 10 / 20 / 30 kg | P | BEX (ovo nije BEX cenovnik) |
| Ko plaća dostavu | kupac | P | Vlasnik proizvoda |
| Maksimalna masa i dimenzije | 30 kg, najduža stranica 120 cm | P | BEX |
| Obavezan dokaz pakovanja | od 20.000 RSD, najmanje 4 fotografije | P | Vlasnik proizvoda |
| Rok predaje pošiljke | 3 dana | P | Vlasnik proizvoda, BEX |
| Rok za reklamaciju | 7 dana od uručenja | P | Pravna služba |
| Isplata prodavcu | naredni radni dan, vikendi preskočeni, lista neradnih dana | P | BEX ugovor |
| Važenje ponude u porukama | 48 sati | P | Vlasnik proizvoda |
| Minimalna starost korisnika | 18 godina | P | Pravna služba |
| Princip četiri oka za deblokadu isplate | isključen | P | Vlasnik proizvoda, finansije |
| Za objavu potreban račun za isplatu | da | P | Vlasnik proizvoda |
| Lično preuzimanje, drugi kuriri, online plaćanje, provizija, automobili, nekretnine, B2C, B2B | isključeno, zaključano u bazi | Z | Menja se samo SQL-om, uz saglasnost vlasnika |

## 4. Poznati nedostaci Faze 1

| ID | Nedostatak | Plan |
|---|---|---|
| N-01 | Telefon ili tekst na fotografiji se ne prepoznaje automatski (scenario 2 iz master prompta pokriven samo za tekst oglasa) | Ručna moderacija sada; automatska provera slika u Fazi 2 |
| N-02 | Pretraga ne zna sinonime (npr. „ajfon” → „iPhone”) | Tabela sinonima u Fazi 2 |
| N-03 | Povrat robe i povraćaj pouzeća otvaraju slučaj usaglašavanja i rešavaju se ručno | BEX povratna pošiljka u Fazi 2, posle potvrde BEX procesa |
| N-04 | Video dokazi: bez uklanjanja metapodataka i bez skeniranja na zlonamerni sadržaj | Faza 3 |
| N-05 | Ocene, premium oglasi, sačuvane pretrage, omiljeni oglasi, blokiranje korisnika, žalba na odluku | Faza 2 |
| N-06 | Analitički dashboardi: samo osnovni pregled u adminu | Faza 3 |
| N-07 | Periodični poslovi (dospele isplate, istekli rokovi) se pokreću dugmetom | Automatski raspored (pg_cron) pre pilota |
| N-08 | Uslovi korišćenja i politika privatnosti su nacrt | Pravna služba pre pilota |

## 5. Pitanja koja blokiraju produkciju

1. Zvanična BEX API dokumentacija, test pristup i potvrda koja osnovna adresa pripada kom okruženju.
2. Da li BEX isplaćuje pouzeće pojedinačnim fizičkim licima na njihov račun i da li potvrđuje vlasništvo računa?
3. Da li BEX ima API za zadržavanje isplate pre narednog dana i za njeno ukidanje, sa potvrdom?
4. Koje pravno lice upravlja platformom (BEX ili novo preduzeće) i kakav je ugovorni model naplate?
5. BEX cenovnik za C2C pošiljke i ko plaća dostavu.
6. SMS provajder za verifikaciju i prijavu telefonom.
7. KYC nivo i provajder pre prve isplate.
8. Pravno dozvoljena lokacija podataka.
9. Saglasnost vlasnika proizvoda na PWA umesto prodavnica aplikacija u pilotu.
