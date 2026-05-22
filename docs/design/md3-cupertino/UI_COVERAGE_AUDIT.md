# UI coverage audit

This audit checks whether the MD3 + Cupertino design boards cover current UI-building Dart files, not only pages under `pages/implementations`.

## Scan command

```powershell
rg -l "(Widget\s+build\s*\(|extends\s+(StatelessWidget|StatefulWidget|ConsumerWidget|ConsumerStatefulWidget|BasePage|BaseSourcePage|BaseTabPage)|showDialog\s*\(|showModal|AlertDialog\s*\(|BottomSheet|ListTile\s*\()" hibiki/lib -g "*.dart" -g "!*.g.dart"
```

## Current scan result

- Total non-generated Dart files under `hibiki/lib`: 197
- UI-building files matched by scan: 81
- Entry UI files mapped in `COVERAGE.md`: 3
- Page implementation files mapped in `COVERAGE.md`: 53
- Shared/base/support UI files mapped in `COVERAGE.md`: 25
- Unmapped UI-building files after this audit: 0

## Entry files covered by this audit

| File | Why it matters | Board mapping |
| --- | --- | --- |
| `main.dart` | Main `MaterialApp`, loading shell, initialization error surface, global theme and app entry behavior. | `01-home-navigation.svg`, `16-empty-loading-error-states.svg` |
| `popup_main.dart` | Android process-text dictionary popup app, transparent loading/error shell, popup dictionary entry. | `03-dictionary.svg`, `16-empty-loading-error-states.svg` |
| `floating_dict_main.dart` | Floating dictionary overlay app, transparent loading shell, floating dictionary entry. | `03-dictionary.svg`, `18-component-system.svg` |

## New non-page files covered by this audit

| File | Why it matters | Board mapping |
| --- | --- | --- |
| `app_model.dart` | Builds the app theme, context-menu selection object, Anki warning dialogs, toasts, and update-related preferences. | `18-component-system.svg`, `14-profile-language-system.svg` |
| `base_history_page.dart` | Base media history layout and placeholder behavior. | `02-reader-shelf.svg`, `16-empty-loading-error-states.svg` |
| `sasayaki_rematch.dart` | Audiobook rematch dialog, bottom sheet, sliders, and toast feedback. | `06-import-and-modals.svg`, `04-reader.svg` |
| `profile_selector.dart` | Inline active-profile selector. | `14-profile-language-system.svg`, `18-component-system.svg` |
| `jidoujisho_divider.dart` | Shared divider token. | `18-component-system.svg`, `05-settings.svg` |
| `jidoujisho_marquee.dart` | Shared overflow title/text behavior. | `18-component-system.svg`, `12-media-and-sentences.svg` |
| `jidoujisho_text_selection_controls.dart` | Text-selection toolbar and search/stash/share actions. | `18-component-system.svg`, `03-dictionary.svg` |
| `hibiki_toast.dart` | Desktop and mobile toast surface. | `18-component-system.svg`, `15-logs-and-debug.svg` |
| `platform_utils.dart` | Desktop content constraints and adaptive layout utilities. | `18-component-system.svg`, `01-home-navigation.svg` |
| `swipe_dismiss_wrapper.dart` | Shared gesture dismissal wrapper for transient surfaces. | `18-component-system.svg`, `06-import-and-modals.svg` |
| `update_checker.dart` | Update dialogs, download overlay, and snackbar failures. | `14-profile-language-system.svg`, `15-logs-and-debug.svg` |
| `blur_options.dart` | Resizable blur/overlay edit handles. | `11-reader-customization.svg`, `18-component-system.svg` |

## Interpretation

No new design board is needed for these files. They are not independent screens; they are shared surfaces or helpers whose visual decisions are controlled by the existing component, modal, reader customization, system, debug, shelf, and dictionary boards.

The next gate is still user choice. Once A/B/C directions are selected, the implementation spec must translate the selected boards into concrete Flutter tokens/components and route-by-route behavior.
