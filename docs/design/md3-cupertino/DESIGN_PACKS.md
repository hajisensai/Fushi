# MD3 + Cupertino design packs

These packs give a fast first choice before reviewing all 84 individual surfaces. Open [pack-selection-index.html](pack-selection-index.html) when you want every pack expanded across all mapped interfaces, [interface-pack-comparison.html](interface-pack-comparison.html) when you want A/B/C images and pack defaults side by side per interface, or [design-pack-gallery.html](design-pack-gallery.html) when you want a representative-image comparison first. Pick one pack as the baseline, then override any interface in [interface-images/index.html](interface-images/index.html) or [INTERFACE_PICKS.md](INTERFACE_PICKS.md).

The canonical pack data lives in [design-packs.json](design-packs.json). `generate-implementation-spec.mjs` and `generate-design-pack-gallery.mjs` both read that file, so pack choices have one source of truth.

You can generate a spec directly from any pack:

```powershell
node .\generate-implementation-spec.mjs --pack hibiki-balanced --output .\IMPLEMENTATION_SPEC_DRAFT.md
```

You can regenerate the per-pack 84-surface selection pages and the interface comparison with:

```powershell
node .\generate-recommended-selection.mjs --all-packs
```

## Pack A: MD3 Practical

Best when the priority is Android-native clarity, predictable controls, and low-risk implementation.

```text
01: A
02: A
03: A
04: A
05: A
06: A
07: A
08: A
09: A
10: A
11: A
12: A
13: A
14: A
15: A
16: A
18: A
Notes:
- Baseline: MD3 Practical.
- Use Material 3 components as the visible default.
- Keep workflows direct and avoid decorative reader chrome.
```

Why pick it:

- Lowest implementation risk because it maps to standard MD3 widgets.
- Best for import, dictionary management, settings, and debug predictability.
- Good if the current priority is making every screen coherent quickly.

Trade-off:

- The reader and preference-heavy screens will feel less calm than the Cupertino-leaning pack.

## Pack B: Reading Calm

Best when the priority is a quiet reader, grouped settings, and soft navigation rhythm.

```text
01: B
02: B
03: B
04: B
05: B
06: B
07: B
08: B
09: B
10: B
11: B
12: B
13: B
14: B
15: B
16: B
18: B
Notes:
- Baseline: Reading Calm.
- Prefer grouped settings, large-title rhythm, and translucent reader/accessory chrome.
- Keep dictionary results readable instead of input-focused.
```

Why pick it:

- Best fit for Hibiki as a reading app rather than a generic utility app.
- Makes reader, dictionary, and settings feel calmer and more cohesive.
- Good for mobile-first usage and long reading sessions.

Trade-off:

- Management-heavy surfaces may need explicit overrides to stay dense enough.

## Pack C: Adaptive Power

Best when the priority is dense workflows, desktop/tablet readiness, and power-user controls.

```text
01: C
02: C
03: C
04: C
05: C
06: C
07: C
08: C
09: C
10: C
11: C
12: C
13: C
14: C
15: C
16: C
18: C
Notes:
- Baseline: Adaptive Power.
- Favor navigation rail/sidebar, split panes, inspectors, persistent previews, and compact shared components.
- Keep mobile layouts usable by collapsing dense panels into sheets.
```

Why pick it:

- Best for dictionary management, creator/Anki mapping, tag operations, and diagnostics.
- Makes desktop and tablet layouts first-class instead of stretched mobile screens.
- Good if Hibiki should feel like a serious study workstation.

Trade-off:

- Can feel too operational for casual mobile reading unless reader surfaces are overridden.

## Recommended Hybrid: Hibiki Balanced

This is the current recommended default. It preserves MD3 for operational flows, Cupertino calm for reading and settings, and adaptive density for shared components and power surfaces.

```text
01: C
02: A
03: B
04: B
05: B
06: A
07: C
08: A
09: C
10: C
11: B
12: A
13: C
14: A
15: A
16: A
18: C
Notes:
- Baseline: Hibiki Balanced.
- Reader stays calm; management surfaces stay dense.
- Shared components use hybrid density so pages do not drift.
```

Why pick it:

- Matches the existing default matrix in [IMPLEMENTATION_SPEC_DRAFT.md](IMPLEMENTATION_SPEC_DRAFT.md).
- Avoids making every screen either too soft or too dense.
- Gives the cleanest path to implementation because each board family keeps the behavior it is best at.

Trade-off:

- It is less visually uniform than a pure A/B/C pack, so component tokens must be strict.

## How to use a pack

1. Copy one pack block into `my-picks.txt` in this folder.
2. Or use `--pack md3-practical`, `--pack reading-calm`, `--pack adaptive-power`, or `--pack hibiki-balanced`.
3. Add any surface-level exceptions below the board choices, or in a separate picks file, for example:

   ```text
   reader_hoshi_page.dart: B
   dictionary_dialog_page.dart: C
   ```

4. Generate the draft:

   ```powershell
   node .\generate-implementation-spec.mjs --picks .\my-picks.txt --output .\IMPLEMENTATION_SPEC_DRAFT.md
   ```

   Or combine a pack with exceptions:

   ```powershell
   node .\generate-implementation-spec.mjs --pack hibiki-balanced --picks .\my-exceptions.txt --output .\IMPLEMENTATION_SPEC_DRAFT.md
   ```

5. Review the generated spec before runtime implementation begins.
