# The Ledger

**A general-purpose inventory, sales & business-management app for any type of business — big or small.**

The Ledger is built for small store owners, retailers, service providers, entrepreneurs, and
companies of any kind. It is **business-type-agnostic** — not tied to any specific industry or
product category.

## What it does

- **Inventory / stock** — track products, stock levels, restocks, and internal use
- **Sales & expenses** — record every sale and expense; monitor profit in real time
- **Customers** — track who owes you money and record partial or full payments
- **Invoices** — create and export professional PDF invoices
- **Reports** — per-product and whole-business history (earnings, expenses, net profit, sales)
- **AI advisor** — optional business advice based on your real numbers
- **Multi-device & teams** — optional free cloud sync and staff accounts with roles

## Tech

- **Front end:** a single self-contained HTML file (installable PWA), hosted on GitHub Pages.
  Third-party libraries are self-hosted under `vendor/` (no CDN in the load path).
- **Back end (optional):** Supabase (Postgres + Auth) with per-business row-level security for
  clean multi-tenant data isolation. See [`supabase/`](supabase/).

## A note on naming

For legacy reasons the internal data model keys each product under `D.strains` (an early working
name). This is plain **generic product inventory** — read `strain` as "product" throughout the
code. The user-facing UI everywhere says "product."
