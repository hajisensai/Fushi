import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-612 source guard for the keyboard-visual surface on the shortcut
/// settings page. The full page mounts a state wired to the live AppModel, so it
/// cannot be pumped in a host unit test (the visual sub-widget is covered
/// behaviourally in visual_keyboard_layout_view_test.dart). This guard pins the
/// page source so the figure stays wired to the SAME write-through path and does
/// not regress the channel-preservation / scope-coverage contracts.
void main() {
  final String src = File(
    'lib/src/pages/implementations/shortcut_settings_page.dart',
  ).readAsStringSync();

  test('page still iterates ShortcutScope.values for the visual surface too',
      () {
    expect(
      RegExp(r'for\s*\(\s*final\s+ShortcutScope\s+scope\s+in\s+'
              r'ShortcutScope\.values')
          .hasMatch(src),
      isTrue,
      reason:
          'visual + list must both walk every scope, not a hard-coded subset',
    );
  });

  test('figure renders KeyboardLayoutView wired to the registry and onKeyTap',
      () {
    expect(src.contains('KeyboardLayoutView('), isTrue,
        reason: 'visual mode must render the KeyboardLayoutView');
    expect(src.contains('onKeyTap: _onKeyboardKeyTap'), isTrue,
        reason: 'figure taps must route through the page handler');
  });

  test('figure key tap routes to the existing _editBinding write-through path',
      () {
    // _onKeyboardKeyTap must delegate to _editBinding (no new write API): that
    // is the reused updateBindingWithReassignments + saveShortcutRegistry path.
    final RegExp handler = RegExp(
      r'_onKeyboardKeyTap[\s\S]*?await\s+_editBinding\(',
    );
    expect(handler.hasMatch(src), isTrue,
        reason: 'figure tap must reuse _editBinding, not a bespoke write');
  });

  test('the list view stays available as the off-figure fallback', () {
    // must-fix 3/4: keys not on the figure must remain editable via the list
    // (_ActionTile + _editBinding). The else branch keeps the action tiles.
    expect(src.contains('_ActionTile('), isTrue,
        reason: 'list-view action tiles must remain as the fallback surface');
    expect(src.contains('if (_visualMode)'), isTrue,
        reason: 'view toggle must gate visual vs list, keeping list fallback');
  });

  test('edit dialog construction preserves the mouse channel (must-fix 1)', () {
    // The single write-construction site is the edit dialog OK button; it must
    // carry mouseBindings forward so figure edits never clear MouseBinding(1).
    expect(src.contains('mouseBindings: widget.initial.mouseBindings'), isTrue,
        reason: 'edit result must preserve existing mouseBindings');
  });

  test('TODO-1050b: the list view renders mouse bindings (not data-only)', () {
    // _ActionTile must iterate bindings.mouseBindings so the mouse channel is
    // visible in the list, not silently passed through.
    expect(
      RegExp(r'for\s*\(\s*final\s+MouseBinding\s+\w+\s+in\s+'
              r'bindings\.mouseBindings')
          .hasMatch(src),
      isTrue,
      reason: 'action tile must render each mouse binding',
    );
  });

  test('TODO-1060: empty keycaps route to the empty-key assignment handler',
      () {
    // Un-defer: the figure wires onEmptyKeyTap to _onEmptyKeyboardKeyTap, which
    // picks an action then reuses _editBinding with a prefillKey (no bespoke
    // write path). This pins the un-defer so it cannot silently regress back to
    // "empty keys are not tappable".
    expect(src.contains('onEmptyKeyTap:'), isTrue,
        reason: 'figure must pass an onEmptyKeyTap to KeyboardLayoutView');
    expect(src.contains('_onEmptyKeyboardKeyTap('), isTrue,
        reason: 'empty tap must route through the empty-key handler');
    final RegExp emptyHandler = RegExp(
      r'_onEmptyKeyboardKeyTap[\s\S]*?await\s+_editBinding\(',
    );
    expect(emptyHandler.hasMatch(src), isTrue,
        reason:
            'empty-key assignment must reuse _editBinding, not a new write');
  });

  test('TODO-1050a: the figure renders gamepad brand glyphs via the panel', () {
    // The visual surface must wire gamepad taps so the GamepadGlyphs data layer
    // is actually rendered (previously zero UI references).
    expect(src.contains('onGamepadTap:'), isTrue,
        reason: 'figure must wire gamepad taps to render the gamepad panel');
    expect(src.contains('onEmptyGamepadTap:'), isTrue,
        reason: 'figure must allow assigning unbound gamepad buttons');
  });
}
