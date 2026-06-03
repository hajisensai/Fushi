import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String manifestPath = 'android/app/src/main/AndroidManifest.xml';

  String activityBlock(String src, String activityName) {
    final int start = src.indexOf('android:name="$activityName"');
    expect(start, isNonNegative, reason: '缺少 activity $activityName');
    final int open = src.lastIndexOf('<activity', start);
    final int close = src.indexOf('</activity>', start);
    expect(open, isNonNegative);
    expect(close, greaterThan(open));
    return src.substring(open, close);
  }

  test('external lookup intent-filters point to PopupDictFlutterActivity', () {
    final String src = File(manifestPath).readAsStringSync();
    final String flutterBlock = activityBlock(src, '.PopupDictFlutterActivity');

    expect(flutterBlock, contains('android.intent.action.PROCESS_TEXT'));
    expect(flutterBlock, contains('android.intent.action.SEND'));
    expect(flutterBlock, contains('android.intent.action.TRANSLATE'));
    expect(flutterBlock, contains('android:scheme="hibiki"'));
    expect(flutterBlock, contains('android:host="lookup"'));
    expect(flutterBlock, contains('android:process=":popup"'));
    expect(flutterBlock, contains('@style/PopupDictTheme'));
    expect(flutterBlock, contains('android:launchMode="singleTop"'));
  });

  test('legacy native PopupDictActivity no longer holds intent-filters', () {
    final String src = File(manifestPath).readAsStringSync();
    final String nativeBlock = activityBlock(src, '.PopupDictActivity');
    expect(nativeBlock, isNot(contains('<intent-filter>')),
        reason: '原生 Activity 应失活（暂留定义，无 filter）');
  });
}
