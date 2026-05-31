# The Ledger — Roadmap

## Vision
Grow The Ledger from a personal, single-user inventory/sales tool into a product
that small businesses, stores, and companies can all use — each with their own
private data, staff accounts, and (eventually) subscriptions.

## Why today's code is the right choice (Phase 1)
The app is a single HTML file (HTML + CSS + JavaScript) hosted free on GitHub Pages
and installable as a PWA. For a single-user, on-device tool this is close to ideal:

- ✅ Free forever (no server to rent)
- ✅ Works offline (lives on the phone)
- ✅ Installs to the home screen like a native app
- ✅ Instant updates (push to GitHub → users get it in seconds)
- ✅ Private (data stays on the device in localStorage)

Going multi-business does NOT throw this away. **The current app becomes the
front-end**; we bolt a back-end underneath it. The screens, logic, and design all
carry forward.

## The 5 new pieces needed to go multi-business
1. **Accounts / authentication** — users sign in; the app knows who they are.
2. **Cloud database** — data moves off a single phone into the cloud, so an owner
   and their staff share the same inventory, synced live across devices.
3. **Multi-tenancy** — each business's data is fully isolated from every other
   business's (critical for trust/privacy).
4. **Roles / permissions** — e.g. owner = full access; cashier = record sales only.
5. **Billing / subscriptions** — only if/when we charge businesses to use it (Stripe).

## Low-friction tech approach (no servers to babysit)
Use a Backend-as-a-Service so most backend work is handled for us; the existing
JavaScript talks to it directly:
- **Supabase** (top pick) — Postgres database + auth + per-row data isolation
  (row-level security = clean multi-tenancy), generous free tier.
- **Firebase** (Google) — solid alternative (NoSQL).
- Front-end stays on GitHub Pages / can move to Vercel or Netlify (free tiers).

## Honest tradeoffs when graduating from personal tool → product
- 💸 Stops being free at scale (DB + auth cost money as it grows; free tiers cover early days)
- 🔒 More responsibility — we'd hold other businesses' data: backups, privacy, security
- 🌐 Needs internet for live sync (offline-first is possible but more work)
- 🛠️ More moving parts to maintain than one HTML file
- 💳 If sold: payments (Stripe), basic support, terms of service

## Phased plan
- **Phase 1 — NOW:** polish the single-user app, validate the product with real use. ← current
- **Phase 2:** add accounts + cloud sync (Supabase) so ONE business owner + their staff
  share data across devices. Same UI, same app.
- **Phase 3:** open to MANY businesses (multi-tenant), add roles + billing → a real SaaS.

## What carries over (so Phase 2/3 isn't a rewrite)
- All UI/screens, layout, theming, the icon system
- All business logic (sales, restock, expenses, packs, AI advisor)
- The data shape already lives in one object (`D`) — that maps cleanly to database rows
- The export/sync code is a head start on cloud sync

## Open questions to decide when starting Phase 2
- Supabase vs Firebase
- Free vs paid product (and pricing) — drives whether/when we add billing
- Offline support level (online-only first is simpler)
