# Cuadra Fabric — Shopify site (theme source)

Source for the custom Cuadra Fabric files in the cuadrafabrics.com theme (Horizon base).
Only Cuadra files live here; the rest of the theme is stock Horizon.

## Multi-page SaaS site (draft theme `189270196473`, "Cuadra Fabric SaaS – multi-page (draft, from live)")

Copied from the live theme on 2026-10-18 so it carries the current Horizon version.

- `layout/cuadra.liquid` — standalone site shell (SEO title/description, OG tags, favicon, skip link,
  site nav, site footer). Used only by templates that set `"layout": "cuadra"`. Store templates
  (product, collection, cart, …) keep `layout/theme.liquid`.
- Pages and templates:

  | URL | Template | Sections |
  |---|---|---|
  | `/` | `index.json` | hero, how, auditor, platform, connectors, pricing, final |
  | `/pages/platform` | `page.platform.json` | page hero, how, available-today/coming-next, platform, connectors, final |
  | `/pages/store-auditor` | `page.store-auditor.json` | page hero, report, steps, auditor (offer + form), FAQ, final |
  | `/pages/pricing` | `page.pricing.json` | page hero, pricing, FAQ, final |
  | `/pages/how-it-works` | `page.how-it-works.json` | page hero, steps, report, how, FAQ, final |
  | `/pages/demo` | `page.demo.json` | page hero, contact form |
  | 404 | `404.json` | page hero |

  The five Shopify pages exist with matching `templateSuffix` values and short fallback body text.
- New sections: `cuadra-site-nav`, `cuadra-site-footer` (legal links only for policies that exist),
  `cuadra-page-hero` (optional status label), `cuadra-audit-steps`, `cuadra-report`, `cuadra-faq`
  (editable question blocks), `cuadra-available` (Available today vs Coming next), `cuadra-contact`.
- `assets/cuadra-site.css` — styles for the new sections, font fallbacks, spacing after page heroes.
- `assets/cuadra.js` — pricing toggle; exits early on pages without the pricing section.

**Keep `cuadra-available.liquid` honest:** move an item to "Available today" only after it works for customers.

Forms use Shopify's native contact form, so submissions email the store's sender address.
Audit purchases go to https://cuadra-audit-flow.base44.app.

## 2026-10-17 accuracy update (homepage, now live)

- Hero/final CTA: removed "Free store audit" / "Results in minutes"; now "$297 one-time", "Report within 48 hours".
- Store Auditor: $297 audit offer with "Start my audit" → https://cuadra-audit-flow.base44.app; contact form kept
  as "Questions first?"; example findings labelled; 13 areas listed.
- How it works / Platform / Connectors: status labels (Available today / In development / Coming next / Planned).
- Pricing: $297 audit shown as available today; Foundation/Growth/Scale labelled "Early access · not yet
  available" with "Join early access" (email) instead of purchase CTAs.
- Nav: removed dead "Log in"; added a no-JS mobile menu.
- `assets/cuadra.css` = the original stylesheet + `assets/cuadra-additions.css` appended (exact copy of the theme file).
