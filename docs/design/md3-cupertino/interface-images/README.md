# Hibiki interface image pack

This folder contains generated A/B/C image choices for every mapped MD3 + Cupertino UI surface.

- `index.html` shows all 84 surfaces with three standalone images each, saves picks in the browser, and copies a complete `Interface image picks` result.
- `manifest.json` records the surface-to-file mapping.
- `*-A.svg`, `*-B.svg`, and `*-C.svg` are the direct image choices.

Regenerate from the design folder with:

```powershell
node .\generate-interface-images.mjs
```

The generator reads `interface-gallery.html`, so the gallery remains the source of truth for surface mappings and defaults.
