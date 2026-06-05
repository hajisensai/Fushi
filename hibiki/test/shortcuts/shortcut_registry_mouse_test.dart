import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

void main() {
  test('resolveMouse maps default middle button to seek action', () {
    final reg = HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(
      reg.resolveMouse(1, scope: ShortcutScope.audiobook),
      ShortcutAction.audiobookSeekToClickedSentence,
    );
  });

  test('resolveMouse returns null for unbound button', () {
    final reg = HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(reg.resolveMouse(2, scope: ShortcutScope.audiobook), isNull);
  });

  test('resolveMouse respects scope', () {
    final reg = HibikiShortcutRegistry()..loadDefaults(TargetPlatform.windows);
    expect(reg.resolveMouse(1, scope: ShortcutScope.reader), isNull);
  });
}
