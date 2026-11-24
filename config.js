/* ════════════════════════════════════════════════════════════════════
   AthenianKeys · Σύνδεση με τη βάση (Supabase)

   Τα δύο στοιχεία βρίσκονται στο Supabase → Project Settings → API:
     • Project URL           → supabaseUrl
     • Project API keys: "anon public" → supabaseAnonKey

   Το "anon public" κλειδί είναι σχεδιασμένο να είναι δημόσιο. Η ασφάλεια
   γίνεται μέσα στη βάση (Row Level Security). ΠΟΤΕ μην βάλετε εδώ το
   κλειδί "service_role".

   Όσο τα πεδία είναι κενά, το site δουλεύει όπως πριν (αιτήματα μόνο
   μέσω WhatsApp/email) και το dashboard προσφέρει μόνο δοκιμαστική προβολή.
   ════════════════════════════════════════════════════════════════════ */
window.AK_BACKEND = {
  supabaseUrl: "",
  supabaseAnonKey: "",
};
