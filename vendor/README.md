# vendor/ — self-hosted third-party libraries

These are the app's runtime dependencies, vendored from npm and served **same-origin**
instead of from a CDN. Rationale:

- **Security** — `supabase.js` runs with full page access (it holds the auth session).
  Loading it from a third-party CDN meant a CDN compromise could steal every user's
  session token. Same-origin removes that supply-chain risk entirely.
- **Privacy** — no user IP / traffic is exposed to a CDN on every app load.
- **Offline** — the PWA is fully self-contained; nothing in the load path depends on a
  third party. These files are precached by the service worker (`sw.js` → `SHELL`).

## Pinned versions

| file | package | version | source |
|------|---------|---------|--------|
| `supabase.js`         | `@supabase/supabase-js` | 2.110.0 | `dist/umd/supabase.js` |
| `jspdf.umd.min.js`    | `jspdf`                 | 2.5.2   | `dist/jspdf.umd.min.js` |
| `html2canvas.min.js`  | `html2canvas`           | 1.4.1   | `dist/html2canvas.min.js` |

## Updating

Re-vendor a **pinned** version (never a floating tag like `@2`):

```sh
npm pack @supabase/supabase-js@<version>
tar xzf supabase-supabase-js-<version>.tgz
cp package/dist/umd/supabase.js vendor/supabase.js
```

Then bump `APP_VER` in `index.html` and the `CACHE` constant in `sw.js` so installed
PWAs pick up the new files.
