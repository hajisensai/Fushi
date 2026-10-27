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
    expect(flutterBlock, contains('android:scheme="fushi"'));
    expect(flutterBlock, contains('android:host="lookup"'));
    expect(flutterBlock, contains('android:process=":popup"'));
    expect(flutterBlock, contains('@style/PopupDictTheme'));
    expect(flutterBlock, contains('android:launchMode="singleTop"'));
  });

  test('the removed native PopupDictActivity is not declared any more', () {
    // 原生 WebView 弹窗（含它独占的 JNI 查词入口）已删除；`:popup` 只剩 Flutter 弹窗。
    final String src = File(manifestPath).readAsStringSync();
    expect(src, isNot(contains('android:name=".PopupDictActivity"')));
  });
}
