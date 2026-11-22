import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

void main() {
  final String activity = maskComments(
    File(
      'android/app/src/main/java/app/fushi/reader/PopupDictFlutterActivity.kt',
    ).readAsStringSync(),
  );
  final String engine = maskComments(
    File(
      'android/app/src/main/java/app/fushi/reader/PopupEngineHolder.kt',
    ).readAsStringSync(),
  );

  test(
    'cold and warm activity entries read this request visibility with a false default',
    () {
      expect(
        activity,
        contains('EXTRA_SOURCE_TEXT_COLLAPSED: String = "sourceTextCollapsed"'),
      );
      for (final String entry in <String>[
        'override fun onCreate(',
        'override fun onNewIntent(',
      ]) {
        final String body = methodBody(activity, entry);
        expect(body, contains('sourceTextCollapsed = intent'));
        expect(
          body,
          contains('getBooleanExtra(EXTRA_SOURCE_TEXT_COLLAPSED, false)'),
        );
      }
    },
  );

  test(
    'both empty and nonempty clipboard requests keep their initial visibility',
    () {
      final String body = methodBody(
        activity,
        'private fun consumeClipboardRequest()',
      );
      expect(
        RegExp(r'sourceTextCollapsed = intent').allMatches(body),
        hasLength(2),
      );
      expect(body, contains('clip,'));
      expect(body, contains('allowBlank = true'));
    },
  );

  test(
    'cached engine carries visibility in both initial and warm payloads',
    () {
      expect(
        engine,
        contains('map["sourceTextCollapsed"] = pendingSourceTextCollapsed'),
      );
      final String pending = methodBody(engine, 'fun setPendingText(');
      final String pushed = methodBody(engine, 'fun pushProcessText(');
      for (final String body in <String>[pending, pushed]) {
        expect(body, contains('sourceTextCollapsed: Boolean = false'));
        expect(
          body,
          contains('pendingSourceTextCollapsed = sourceTextCollapsed'),
        );
      }
      expect(
        pushed,
        contains('args["sourceTextCollapsed"] = sourceTextCollapsed'),
      );
    },
  );
}
