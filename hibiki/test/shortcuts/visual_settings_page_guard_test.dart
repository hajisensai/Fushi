import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-612 source guard for the keyboard-visual surface on the shortcut
/// settings page. The full page mounts a state wired to the live AppModel, so it
/// cannot be pumped in a host unit test (the visual sub-widget is covered
/// behaviourally in visual_keyboard_layout_view_test.dart). This guard pins the
/// page source so the figure stays wired to the SAME write-through path and does
/// not regress the channel-preservation / scope-coverage contracts.
void main() {
  // Shortcut settings refactor: the page is now a library of the page shell +
  // the action_tile / binding_edit_dialog parts, with the localized labels in
  // the shared shortcut_labels extensions. The guarded contracts span all four
  // files, so pin their concatenation.
  final String src = <String>[
    'lib/src/pages/implementations/shortcut_settings_page.dart',
    'lib/src/pages/implementations/shortcut_settings/action_tile.part.dart',
    'lib/src/pages/implementations/shortcut_settings/'
        'binding_edit_dialog.part.dart',
    'lib/src/shortcuts/shortcut_labels.dart',
  ].map((String path) => File(path).readAsStringSync()).join('\n');

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
    // TODO-1088: mouse bindings are now editable. The OK button writes the mouse
    // DRAFT (_mouse), which initState seeds from widget.initial.mouseBindings, so
    // an untouched dialog still carries existing bindings forward (never clears
    // MouseBinding(1)) while user captures/deletes take effect.
    expect(
        src.contains('mouseBindings: List<MouseBinding>.unmodifiable(_mouse)'),
        isTrue,
        reason: 'edit result must write the mouse draft, not drop the channel');
    expect(
      RegExp(r'_mouse\s*=\s*List<MouseBinding>\.of\('
              r'widget\.initial\.mouseBindings\)')
          .hasMatch(src),
      isTrue,
      reason: 'mouse draft must be seeded from the initial bindings so an '
          'untouched dialog preserves them',
    );
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

  test('TODO-1113: brand selector is wired to the persisted preference', () {
    // The selectable brand is loaded from and written to the reader source
    // preference (display-only), so it survives restart and never touches the
    // binding registry.
    expect(
      src.contains('ReaderHibikiSource.instance.gamepadGlyphBrand'),
      isTrue,
      reason: 'brand must be seeded from the persisted display preference',
    );
    expect(
      src.contains('setGamepadGlyphBrand('),
      isTrue,
      reason: 'changing the brand must persist through the source setter',
    );
    expect(
      src.contains("Key('gamepad_brand_select')"),
      isTrue,
      reason: 'the brand SegmentedButton must be test-addressable',
    );
  });

  test('TODO-1113: all three brands are offered as segments', () {
    for (final String brand in <String>[
      'GamepadBrand.xbox',
      'GamepadBrand.playstation',
      'GamepadBrand.nintendoSwitch',
    ]) {
      expect(src.contains(brand), isTrue,
          reason: 'brand selector must offer segment for \$brand');
    }
  });

  test('TODO-942: the visual view-toggle segment uses a controller glyph', () {
    // Discoverability fix: the visual segment opens the gamepad/keyboard layout
    // figure, but its icon used to be Icons.keyboard_outlined so users read it
    // as a plain keyboard view and asked where the controller diagram was. Pin
    // the controller glyph so the entry is self-describing and cannot silently
    // regress back to the keyboard glyph.
    final int toggleStart = src.indexOf("Key('shortcut_view_toggle')");
    expect(toggleStart, greaterThanOrEqualTo(0),
        reason: 'the view-toggle SegmentedButton must stay addressable');
    final int toggleEnd = src.indexOf('onSelectionChanged', toggleStart);
    expect(toggleEnd, greaterThan(toggleStart),
        reason: 'view-toggle block must close with onSelectionChanged');
    final String toggleBlock = src.substring(toggleStart, toggleEnd);
    expect(
      toggleBlock.contains('Icons.keyboard_outlined'),
      isFalse,
      reason: 'visual segment must NOT hide the controller behind a keyboard '
          'glyph (TODO-942 discoverability regression)',
    );
    expect(
      toggleBlock.contains('Icons.sports_esports_outlined'),
      isTrue,
      reason: 'visual segment must advertise the gamepad layout with a '
          'controller glyph',
    );
    // The two segments must also carry describing tooltips (hover / long-press
    // discoverability on desktop) rather than being bare icons.
    expect(toggleBlock.contains('tooltip: t.shortcut_view_list'), isTrue,
        reason: 'list segment must expose a describing tooltip');
    expect(toggleBlock.contains('tooltip: t.shortcut_view_visual'), isTrue,
        reason: 'visual segment must expose a describing tooltip');
  });

  test('TODO-1113: the chosen brand is threaded into the figure + list chips',
      () {
    // The figure re-skins with the selected brand...
    expect(src.contains('gamepadBrand: _gamepadBrand'), isTrue,
        reason: 'KeyboardLayoutView must render with the selected brand');
    // ...and the list-view gamepad chip uses the brand glyph, not the raw label.
    expect(
      src.contains('GamepadGlyphs.glyphFor(b.button, brand).symbol'),
      isTrue,
      reason: 'list-view gamepad chips must render brand glyphs',
    );
  });

  // ── TODO-134 source guard（并自 shortcut_settings_video_scope_guard_test.dart）──
  // The shortcut settings page must list the video scope alongside reader /
  // home / global / audiobook, and it does so by iterating ALL
  // [ShortcutScope.values] (not a hard-coded subset). If someone narrows the
  // scope loop back to a fixed list, or forgets the video scope/action label
  // branches, the video keys silently vanish from the settings UI even though
  // they exist in the registry -- exactly the regression this guards.
  // （ShortcutScope.values 枚举正则与本文件第一个 test 完全重复，按裁决只保留
  // 一份；其余断言逐字搬运。）

  test('settings page expands each scope via actionsForScope(scope) (TODO-134)',
      () {
    // The build loop must expand the per-scope actions via
    // actionsForScope(scope).
    expect(
      src.contains('ShortcutAction.actionsForScope(scope)'),
      isTrue,
      reason: 'settings page must expand each scope via actionsForScope(scope)',
    );
  });

  test('settings page has a label branch for the video scope', () {
    // _scopeLabel must handle ShortcutScope.video (the section header), so the
    // video block renders a real localised title rather than throwing.
    expect(
      src.contains('case ShortcutScope.video:'),
      isTrue,
      reason: 'settings page _scopeLabel must have a video branch',
    );
    expect(
      src.contains('t.shortcut_scope_video'),
      isTrue,
      reason: 'video section header must use shortcut_scope_video',
    );
  });

  test('settings page labels every video action (no missing tile title)', () {
    // Each video action needs a label branch in _actionLabel; spot-check a
    // representative set covering migrated keys. A missing branch would surface
    // as an unlabeled / crashing tile in the video section.
    for (final String label in <String>[
      't.shortcut_action_video_toggle_play_pause',
      't.shortcut_action_video_seek_forward',
      't.shortcut_action_video_screenshot',
      't.shortcut_action_video_toggle_fullscreen',
      't.shortcut_action_video_toggle_subtitle_blur',
      // 「退出视频」不再是 video 组的动作：v8 起它与退书 / 退漫画 / 退设置页共用
      // 唯一的 t.shortcut_action_global_back（universal 组），故这里改核那一个。
      't.shortcut_action_global_back',
    ]) {
      expect(src.contains(label), isTrue,
          reason: 'settings page is missing video action label: $label');
    }
  });

  test('settings page labels reader lookup and card shortcut actions', () {
    for (final String label in <String>[
      't.shortcut_action_reader_lookup_at_cursor',
      't.shortcut_action_reader_shift_lookup',
      't.shortcut_action_reader_create_card_from_popup',
    ]) {
      expect(src.contains(label), isTrue,
          reason: 'settings page is missing reader shortcut label: $label');
    }
  });
}
