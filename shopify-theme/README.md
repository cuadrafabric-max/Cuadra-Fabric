# Cuadra Fabric — Shopify homepage sections

Source for the custom `cuadra-*` sections in the cuadrafabrics.com theme (Horizon base).
`templates/index.json` renders: nav, hero, how, auditor, platform, connectors, pricing, final, footer.

2026-10-17 accuracy update (draft theme `189269573881`, "Cuadra Fabric – accuracy fixes (draft 2026-10-17)"):
- Hero/final CTA: removed "Free store audit" / "Results in minutes"; now "$297 one-time", "Report within 48 hours".
- Store Auditor: $297 audit offer with "Start my audit" → https://cuadra-audit-flow.base44.app; contact form kept
  as "Questions first?"; example findings labelled; 13 areas listed.
- How it works / Platform / Connectors: status labels (Available today / In development / Coming next / Planned).
- Pricing: $297 audit shown as available today; Foundation/Growth/Scale labelled "Early access · not yet
  available" with "Join early access" (email) instead of purchase CTAs.
- Nav: removed dead "Log in"; added a no-JS mobile menu. Demo buttons now email cuadrafabric@gmail.com.
- `assets/cuadra.css` = the original stylesheet + `assets/cuadra-additions.css` appended.
