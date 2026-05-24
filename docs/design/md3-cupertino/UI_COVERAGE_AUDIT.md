# UI coverage audit

This audit checks whether the MD3 + Cupertino design boards cover current UI-building Dart files, not only pages under `pages/implementations`.

## Scan command

```powershell
rg -l "(Widget\s+build\s*\(|extends\s+(StatelessWidget|StatefulWidget|ConsumerWidget|ConsumerStatefulWidget|BasePage|BaseSourcePage|BaseTabPage)|showDialog\s*\(|showModal|AlertDialog\s*\(|BottomSheet|ListTile\s*\()" hibiki/lib -g "*.dart" -g "!*.g.dart"
```

## Verification command

```powershell
node docs\design\md3-cupertino\verify-interface-coverage.mjs
```

Latest verifier output:

```text
nonGeneratedDart=221
uiMatched=89
broadUiAdjacentMatched=125
coverageRows=95
gallerySurfaces=84
manifestSurfaces=84
decisionMatrixRows=84
svgImages=252
unmappedUiFiles=0
interfaceCoverage=ok
```

## Current scan result

- Total non-generated Dart files under `hibiki/lib`: 221
- UI-building files matched by scan: 89
- Broad UI-adjacent files matched by scan: 125
- Entry UI files mapped in `COVERAGE.md`: 3
- Page implementation files mapped in `COVERAGE.md`: 56
- Shared/base/support UI files mapped in `COVERAGE.md`: 36
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
| `adaptive_navigation.dart` | Shared MD3 NavigationBar and CupertinoTabBar/AppBar selection helpers. | `18-component-system.svg`, `01-home-navigation.svg` |
| `adaptive_widgets.dart` | Shared dialog, switch, slider, modal sheet, segmented control, and page-route grammar. | `18-component-system.svg`, `06-import-and-modals.svg` |
| `hibiki_divider.dart` | Shared divider token. | `18-component-system.svg`, `05-settings.svg` |
| `hibiki_marquee.dart` | Shared overflow title/text behavior. | `18-component-system.svg`, `12-media-and-sentences.svg` |
| `hibiki_text_selection_controls.dart` | Text-selection toolbar and search/stash/share actions. | `18-component-system.svg`, `03-dictionary.svg` |
| `hibiki_toast.dart` | Desktop and mobile toast surface. | `18-component-system.svg`, `15-logs-and-debug.svg` |
| `cupertino_settings_renderer.dart` | Cupertino grouped settings renderer for schema-defined settings. | `05-settings.svg`, `18-component-system.svg` |
| `material_settings_renderer.dart` | Material 3 settings renderer for schema-defined settings. | `05-settings.svg`, `18-component-system.svg` |
| `settings_actions.dart` | Shared settings action rows, theme controls, profile selector row, dialogs, and reader side effects. | `05-settings.svg`, `14-profile-language-system.svg` |
| `settings_detail_page.dart` | Platform-routed detail page for a selected settings destination. | `05-settings.svg`, `18-component-system.svg` |
| `settings_home_page.dart` | Schema-driven settings home, destination list, and wide master-detail layout. | `05-settings.svg`, `01-home-navigation.svg` |
| `settings_shared.dart` | Legacy/shared settings scaffold and row controls used by secondary settings pages. | `05-settings.svg`, `18-component-system.svg` |
| `platform_utils.dart` | Desktop content constraints and adaptive layout utilities. | `18-component-system.svg`, `01-home-navigation.svg` |
| `swipe_dismiss_wrapper.dart` | Shared gesture dismissal wrapper for transient surfaces. | `18-component-system.svg`, `06-import-and-modals.svg` |
| `update_checker.dart` | Update dialogs, download overlay, and snackbar failures. | `14-profile-language-system.svg`, `15-logs-and-debug.svg` |
| `blur_options.dart` | Resizable blur/overlay edit handles. | `11-reader-customization.svg`, `18-component-system.svg` |

## Interpretation

No new design board is needed for these files. They are not independent screens; they are shared surfaces or helpers whose visual decisions are controlled by the existing component, modal, reader customization, system, debug, shelf, and dictionary boards.

## Wider candidate audit

The strict verifier intentionally matches files that build concrete Flutter surfaces. A wider heuristic also flags files that merely carry `BuildContext`, icons, media-source factories, or field fragments. These are not all independent screens. They are still documented here so the coverage claim does not hide UI-adjacent code.

| Candidate family | Files | Decision |
| --- | --- | --- |
| Creator quick actions | `creator/actions/add_to_stash_action.dart`, `copy_to_clipboard_action.dart`, `play_audio_action.dart`, `share_action.dart`, `creator/quick_action.dart` | Not standalone screens. Their visible shape is the dictionary/creator quick-action icon grammar covered by `07-creator-anki.svg`, `03-dictionary.svg`, `12-media-and-sentences.svg`, and `18-component-system.svg`. |
| Creator enhancement commands | `creator/enhancement.dart`, `audio_enhancement.dart`, `enhancements/audio_recorder_enhancement.dart`, `camera_enhancement.dart`, `clear_field_enhancement.dart`, `crop_image_enhancement.dart`, `local_audio_enhancement.dart`, `pick_audio_enhancement.dart`, `pick_from_stash_enhancement.dart`, `pick_image_enhancement.dart`, `pop_from_stash_enhancement.dart`, `save_tags_enhancement.dart`, `search_dictionary_enhancement.dart`, `sentence_picker_enhancement.dart`, `text_segmentation_enhancement.dart` | Mostly command objects. Dialog-launching cases delegate to already mapped dialog pages such as `audio_recorder_page.dart`, `crop_image_dialog_page.dart`, `open_stash_dialog_page.dart`, and `text_segmentation_dialog_page.dart`; toast/error feedback inherits `18-component-system.svg` and `16-empty-loading-error-states.svg`. |
| Creator visible fields | `creator/audio_export_field.dart`, `creator/fields/base_audio_field.dart`, `creator/image_export_field.dart`, `creator/fields/image_field.dart` | Visible creator fragments, but not routes. They are governed by the Creator/Anki and media-dialog boards: `07-creator-anki.svg`, `12-media-and-sentences.svg`, and `18-component-system.svg`. Implementation must treat audio/image field previews as shared creator components, not page-local decoration. |
| Media source factories | `media/media_source.dart`, `media/media_type.dart`, `media/source_types/reader_media_source.dart`, `media/types/dictionary_media_type.dart`, `media/types/reader_media_type.dart` | They return already mapped homes/history pages and define icons/source metadata. Covered through `home_dictionary_page.dart`, `home_reader_page.dart`, `history_reader_page.dart`, `reader_hoshi_history_page.dart`, and `18-component-system.svg`. |
| Hoshi reader source actions | `media/sources/reader_hoshi_source.dart`, `media/sources/reader_hibiki_source.dart` | Source-level import/tweaks buttons and history factories. Current reader remains Hoshi/Hibiki path; visual decisions are covered by `reader_hoshi_page.dart`, `reader_hibiki_page.dart`, their history pages, `book_import_dialog.dart`, `04-reader.svg`, `02-reader-shelf.svg`, and `06-import-and-modals.svg`. |
| Settings schema helpers | `settings_context.dart`, `settings_destination.dart`, `settings_renderer.dart` | Schema and renderer contracts, not independent screens. Runtime surfaces are mapped through `settings_home_page.dart`, `settings_detail_page.dart`, `material_settings_renderer.dart`, and `cupertino_settings_renderer.dart`. |
| Adaptive platform helpers | `utils/adaptive/adaptive_platform.dart` | Platform detection only. Visible surfaces are mapped through `adaptive_navigation.dart`, `adaptive_widgets.dart`, `settings_shared.dart`, and page-level callers. |
| Dialog helper | `utils/misc/show_app_dialog.dart` | Wrapper around `showDialog`. Not a surface by itself; governed by `06-import-and-modals.svg` and shared component tokens. |

Verifier rule: if the wider heuristic finds new UI-adjacent files, either map them in `COVERAGE.md` when they are independent surfaces, or add them to this wider candidate audit with a concrete parent board decision.

The next gate is still user choice. Once A/B/C directions are selected, the implementation spec must translate the selected boards into concrete Flutter tokens/components and route-by-route behavior.
