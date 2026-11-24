# AthenianKeys · Οδηγός εγκατάστασης Admin Dashboard

Χρόνος: περίπου 30 λεπτά. Κόστος: 0 € (δωρεάν πλάνα Supabase και Netlify).

## 1. Βάση δεδομένων (Supabase)
1. Λογαριασμός στο https://supabase.com → **New project**.
   - Region: **Central EU (Frankfurt)**, ώστε τα δεδομένα να μένουν στην ΕΕ (GDPR).
   - Κρατήστε τον κωδικό της βάσης σε ασφαλές σημείο.
2. **SQL Editor → New query**: επικολλήστε όλο το `supabase/migrations/20261124000000_admin_dashboard.sql` → **Run**.
   Είναι ασφαλές να τρέξει ξανά· δεν διαγράφει δεδομένα.
3. **Authentication → Sign In / Providers → Email**: απενεργοποιήστε το **Allow new users to sign up**.
4. **Authentication → Users → Add user → Create new user**: το email σας και ισχυρό κωδικό (12+ χαρακτήρες). Τσεκάρετε **Auto Confirm User**.
5. **SQL Editor**, με το δικό σας email:
   ```sql
   insert into public.admins (user_id, email)
   select id, email from auth.users where email = 'YOUR-EMAIL@example.com'
   on conflict (user_id) do nothing;
   ```
6. Προαιρετικά, για επιπλέον ασφάλεια:
   - **Authentication → Hooks → Password verification attempt**: επιλέξτε `public.hook_password_verification_attempt` (αν το προσφέρει το πλάνο σας). Έτσι το κλείδωμα μετά από 5 αποτυχίες γίνεται από τον server του Supabase.
   - **Authentication → Attack Protection**: ενεργοποιήστε CAPTCHA και leaked password protection, όπου διατίθενται.

## 2. Σύνδεση site με τη βάση
**Project Settings → API**: αντιγράψτε το **Project URL** και το κλειδί **anon public** στο `config.js`:
```js
window.AK_BACKEND = { supabaseUrl: "https://xxxx.supabase.co", supabaseAnonKey: "eyJ..." };
```
Ποτέ το κλειδί `service_role`.

## 3. Φιλοξενία (Netlify)
- **Γρήγορα**: https://app.netlify.com/drop → σύρετε όλο τον φάκελο του project.
- **Με αυτόματες ενημερώσεις**: Add new site → Import from GitHub → `Cyber-Saint-G/AthenianKey`, branch `admin-dashboard`, χωρίς build command, publish directory `.`.
- Domain: Site configuration → Domain management → Add domain (π.χ. atheniankeys.gr).

## 4. Χρήση
- Site: `https://<domain>/`
- Dashboard: `https://<domain>/admin/`

## 5. Αλλαγή κωδικού admin
- Μέσα από το dashboard: **Ρυθμίσεις → Αλλαγή κωδικού**.
- Αν τον ξεχάσετε: Supabase → Authentication → Users → ο χρήστης σας → **Send password recovery** (ή ορίστε νέο κωδικό από εκεί).
- Νέος/δεύτερος admin: βήματα 1.4 και 1.5 με το άλλο email.

## 6. Επαναφορά backup κώδικα
Το σημείο πριν το dashboard είναι το commit `d23c3a9`:
```bash
git checkout d23c3a9 -- .      # επαναφέρει όλα τα αρχεία
git commit -m "Restore pre-dashboard version"
```
Για τα δεδομένα: Supabase → Database → Backups (καθημερινά backups στα επί πληρωμή πλάνα· στο δωρεάν, εξαγωγή με `pg_dump` ή CSV από το Table Editor).

## 7. GDPR
- Προσθέστε σελίδα **Πολιτικής Απορρήτου** (ποια στοιχεία κρατάτε, γιατί, για πόσο, πώς ζητά κάποιος διαγραφή).
- Τα στατιστικά δεν χρησιμοποιούν cookies και δεν αποθηκεύουν IP.
- Διαγραφή πελάτη κατόπιν αιτήματος: Supabase → Table Editor → `customers` / `requests`.
