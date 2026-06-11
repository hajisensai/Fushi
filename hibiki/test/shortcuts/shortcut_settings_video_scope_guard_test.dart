import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-134 source guard: the shortcut settings page must list the video scope
/// alongside reader / home / global / audiobook, and it does so by iterating
/// ALL [ShortcutScope.values] (not a hard-coded subset). If someone narrows the
/// scope loop back to a fixed list, or forgets the video scope/action label
/// branches, the video keys silently vanish from the settings UI even though
/// they exist in the registry -- exactly the regression this guards.
///
/// The full page mounts a ConsumerState wired to the live AppModel, so it cannot
/// be pumped in a host unit test; the enumeration logic itself is covered
/// behaviourally in video_shortcut_registry_test.dart. This guard pins the page
/// source to that enumeration so it cannot quietly drop the video scope.
void main() {
  final String src = File(
    'lib/src/pages/implementations/shortcut_settings_page.dart',
  ).readAsStringSync();

  test('settings page iterates ShortcutScope.values (all scopes, incl. video)',
      () {
    // The build loop must walk every scope; a hard-coded subset would exclude
    // video. Allow whitespace/newlines between the loop keyword and the values.
    expect(
      RegExp(r'for\s*\(\s*final\s+ShortcutScope\s+scope\s+in\s+'
              r'ShortcutScope\.values')
          .hasMatch(src),
      isTrue,
      reason: 'settings page must iterate ShortcutScope.values (incl. video), '
          'not a hard-coded scope subset',
    );
    // And it must expand the per-scope actions via actionsForScope(scope).
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
      't.shortcut_action_video_escape',
    ]) {
      expect(src.contains(label), isTrue,
          reason: 'settings page is missing video action label: $label');
    }
  });
}
