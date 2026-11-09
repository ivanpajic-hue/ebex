# eBex — rezultati testova

Datum izvršavanja: 9. 11. 2026. · Okruženje: PostgreSQL 16 sa imitacijom Supabase šema `auth` i `storage`, Node.js 22 + jsdom.

Ovi testovi proveravaju poslovna pravila i ekrane. Ne zamenjuju probni krug u stvarnom Supabase projektu (UPUTSTVO.md, korak 9), ni penetracioni test pre produkcije.

## 1. Baza i poslovna pravila (provera: 54, sve prošle)

Oznake T01–T25 odgovaraju scenarijima prihvata iz master prompta (poglavlje 20).

```text
T00 ime sa telefonom zamenjeno: true
T01 telefon verifikovan
T18a neispravan kontrolni broj odbijen
T18b racun drugog lica -> REVIEW
T18c racun istog lica -> PENDING
T01 oglas objavljen: ACTIVE
T02 oglas sa kontaktom: PENDING_REVIEW (["telefon", "fraza: viber"])
T25 automobil odbijen: Automobili nisu u prvom obimu platforme.
T01b isti broj kod drugog naloga odbijen
T-anon vidi: 1
T05/chat poruka sa kontaktom blokirana
T05 kupovina mimo pravila odbijena: Za ovaj oglas se kupovina dogovara kroz poruke i formalnu ponudu.
T03 porudžbina kreirana
T03 iznosi: cena=45000 dostava=450 pouzece=45450 neto=45000 dokaz=true
T-RLS kupac vidi adresu: 1
T-RLS prodavac vidi adresu kupca: 0
T-ver predaja bez verifikacije odbijena: Identitet još nije verifikovan. Isplata je moguća samo verifikovanom prodavcu.
T-MFA admin bez drugog faktora odbijen
T-ver identitet i račun verifikovani
T18d admin ne može odobriti račun trećeg lica
T15 bez dokaza pakovanja: Za ovu vrednost je obavezan dokaz pakovanja. Dodato: 0 od 4 potrebnih fotografija.
T07 ponovljen zahtev ne pravi drugu pošiljku
T07 broj pošiljaka: 1
T-sec korisnik ne može da šalje BEX događaje
T06/T08 duplikati i pogrešan redosled obrađeni
T08 konačno stanje: COMPLETED / COLLECTED / PAID / pošiljka DELIVERED
T06 knjiženja za porudžbinu: 7 stavki, saldo 0
T-mod odobrenje: true
T19 moderator ne može da odmrzne isplatu: Nemate ovlašćenje za ovu radnju ili niste potvrdili dvofaktorsku prijavu (release_hold).
T04 ponuda prihvaćena, porudžbina i pošiljka kreirane (dokaz nije potreban ispod praga)
T12 reklamacija: false
T12 stanje: DISPUTED / PAYOUT_HOLD
T12 BEX zahtev za zadržavanje u outbox-u: 1
T13 simulacija dospelih isplata (zadržana se preskače): 0
T13 isplata uprkos hold-u: PAID
T13 slučajevi usaglašavanja: PAYOUT_DESPITE_HOLD
T09 otkazivanje pre predaje: CANCELLED, oglas ACTIVE
T09 istekle porudžbine: 1
T09 posle isteka: SHIPMENT_EXPIRED / CANCELLED
T-fin finansije vide knjigu: 14
T-4oka isti admin ne može drugi put: Drugo odobrenje mora dati drugi administrator (princip četiri oka).
T-4oka drugo odobrenje: RELEASED
T20 audit zapisa za zadržavanja: 3, sa razlogom: 2
T22 isplata za naplatu 24.10.2026 23:30 UTC (DST noć): 2026-10-26
T22 isplata za naplatu u petak 13.11.2026: 2026-11-16
T-ukupni saldo glavne knjige: 0
T-ledger izmena knjiženja zabranjena
T-anon pretraga "andric" (bez dijakritika): 1
T-anon pretraga sa greškom "knjge andirc": 1
T-anon prodat iPhone se ne prikazuje: 0
T-anon pretraga bez dijakritika "sabac" grad: 1
T-anon vidi adrese: 0
T-anon vidi profile_private: 0
T-anon kupovina zabranjena: permission denied for function place_order
```

Ključni nalazi:

- **Iznosi (T03):** cena 45.000 RSD + BEX dostava 450 RSD = pouzeće 45.450 RSD; prodavcu 45.000 RSD.
- **Idempotentnost (T06, T07):** ponovljen BEX događaj vraća `DUPLICATE`; ponovljen zahtev za pošiljku ne pravi drugu.
- **Pogrešan redosled (T08):** isplata stigla pre naplate je odložena i primenjena posle naplate; konačno stanje je ispravno.
- **Knjiga:** posle svih scenarija saldo glavne knjige je 0; izmena knjiženja je zabranjena na nivou baze.
- **Letnje/zimsko vreme (T22):** naplata u noći promene vremena daje ispravan datum isplate.

## 2. Ekrani (provera: 32, sve prošle)

Svaka stranica je otvorena sa simuliranim podacima; proverava se da nema JavaScript greške, prikaza „undefined” ili „NaN” i da se tekst koji unese korisnik ne izvršava kao HTML.

```text
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
--- anonimni posetilac
ok
ok
ok
ok
--- admin
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
ok
```

## 3. Šta nije testirano automatski

- Stvarna Supabase prijava, dvofaktorska potvrda i otpremanje fotografija (proverava se u probnom krugu).
- Izgled na stvarnim telefonima (iPhone Safari, Android Chrome).
- Opterećenje, penetracioni test i oporavak iz rezervne kopije (Faza 4).
