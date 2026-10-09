# Fushi local changes

Upstream: `flutter_colorpicker` 1.1.0, https://github.com/mchome/flutter_colorpicker.
The complete published package is retained, including its MIT license and examples.

## Material UI migration (HBK-AUDIT-053)

Fushi uses the Flutter 3.47 `material_ui` package. SDK Material and package Material
have separate themes and widget types. The upstream color picker's SDK TextField
lost Fushi's input decoration through the limited root compatibility bridge and
read the root light theme inside the video's locally dark dialog.

- Change only the Material imports in `block_picker.dart`, `colorpicker.dart`,
  `material_picker.dart` and `palette.dart` to `material_ui/material_ui.dart`.
- Add `material_ui: ^1.5.0` and require Flutter >=3.47.0.
- Keep the color conversion, picker state, input behavior and public API unchanged.

The upstream examples and unit tests are preserved as published. Fushi's behavior
regressions are in `fushi/test/widgets/design_widgets_migration_test.dart`; they
cover picker input, direct ColorPickerInput, input decoration, theme changes and
the actual video color dialog. Upstream `test/utils_test.dart` covers conversions.

Remove this fork and the workspace path override when an upstream release uses
the same design packages as Fushi and passes these regression tests.
