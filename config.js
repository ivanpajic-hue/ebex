// ================================================================
// eBex · podešavanje veze sa bazom
// Ovo je JEDINI fajl koji menjaš. Zameni dve vrednosti između navodnika
// podacima iz Supabase → Project Settings → API Keys (uputstvo, korak 4).
//
// U ovaj fajl NIKADA ne upisuj "secret" ili "service_role" ključ.
// Ovde ide samo javni ključ (publishable / anon), koji je bezbedan za
// pregledač jer bazu štite pravila pristupa (RLS).
// ================================================================
window.EBEX_CONFIG = {
  SUPABASE_URL: "https://OVDE-UPISI-PROJEKAT.supabase.co",
  SUPABASE_ANON_KEY: "OVDE-NALEPI-PUBLISHABLE-ILI-ANON-KLJUC"
};
