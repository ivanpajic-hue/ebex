# eBex — Faza 1 (test okruženje)

Digitalno tržište za prodaju robe između fizičkih lica u Srbiji, sa plaćanjem pouzećem i dostavom isključivo preko BEX-a.

**Za postavljanje pročitaj [UPUTSTVO.md](UPUTSTVO.md).** Ne treba ništa da instaliraš.

## Sadržaj

| Fajl | Namena |
|---|---|
| `index.html` | Korisnička aplikacija (web i instalacija na telefon) |
| `admin.html` | Administratorski portal (obavezna dvofaktorska prijava) |
| `config.js` | **Jedini fajl koji menjaš:** adresa Supabase projekta i javni ključ |
| `supabase/ebex_schema.sql` | Cela baza: tabele, poslovna pravila, bezbednost, revizija |
| `supabase/postavi_admina.sql` | Dodela uloge glavnog administratora |
| `docs/registar-odluka.md` | Pretpostavke, odstupanja i pitanja koja blokiraju produkciju |
| `docs/testovi.md` | Rezultati automatskih testova |
| `manifest.webmanifest`, `sw.js`, ikone | Instalacija na telefon |

## Važno

- Ovo je **test okruženje**. BEX, SMS i provera identiteta su simulirani. Ne koristi ga za stvarnu prodaju.
- U `config.js` ide samo **publishable** (ili legacy **anon**) ključ. Secret i service_role ključ nikada ne idu u repozitorijum.
- Sva poslovna pravila (cene, rokovi, pragovi) menjaju se u admin portalu → Podešavanja. Zaključane odluke (lično preuzimanje, drugi kuriri, online plaćanje, automobili, nekretnine) ne mogu se uključiti iz portala.
