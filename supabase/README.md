# The Ledger — Supabase backend (Phase 2)

Multi-tenant backend: accounts + per-business data isolation via Postgres Row-Level Security.

## Setup (one time)
1. In the Supabase dashboard → **SQL Editor** → **+ New query**.
2. Paste the entire contents of [`migrations/0001_init.sql`](migrations/0001_init.sql).
3. Click **Run**.
4. The script ends with an assertion that returns **zero rows** if every table is correctly locked down (ENABLE + FORCE RLS). If it returns rows, something's off — don't ship.

## Security model
- The app ships the **publishable (anon) key** — it is public by design. **RLS is the only wall.**
- Every business-owned table has `ENABLE` + `FORCE ROW LEVEL SECURITY`; every write policy has `WITH CHECK`; child tables verify the parent's tenant; `anon` has zero table/function grants.
- Designed multi-tenant from day one (Phase 3 = many businesses + roles is nearly free).
- Launch = **document mode**: the whole `D` object lives in `businesses.data` (jsonb); normalized tables exist but aren't on the live path yet (Phase 2b).

Never commit or paste the **`sb_secret_…`** key or the database password anywhere. The app only needs the **`sb_publishable_…`** key + the project URL.
