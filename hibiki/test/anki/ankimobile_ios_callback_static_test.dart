import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('iOS declares Hibiki and Anki URL schemes for AnkiMobile callbacks', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();

    expect(plist, contains('<string>fushi</string>'));
    expect(plist, contains('<key>LSApplicationQueriesSchemes</key>'));
    expect(plist, contains('<string>anki</string>'));
  });

  test('AppDelegate exposes AnkiMobile pasteboard and URL callbacks', () {
    final src = File('ios/Runner/AppDelegate.swift').readAsStringSync();

    expect(src, contains('app.fushi.reader/ankimobile'));
    expect(src, contains('consumeInfoForAddingPasteboard'));
    expect(src, contains('net.ankimobile.json'));
    expect(src, contains('app.fushi.reader/url_events'));
    expect(src, contains('override func application('));
    expect(src, contains('open url: URL'));
  });

  test('Dart startup consumes the AnkiMobile info callback', () {
    final main = File('lib/main.dart').readAsStringSync();
    final vm = File('lib/src/anki/anki_view_model.dart').readAsStringSync();

    expect(main, contains('IosUrlEventChannel'));
    expect(main, contains('hibikiAnkiFetchCallback'));
    expect(main, contains('consumeInfoForAddingPasteboard'));
    expect(main, contains('ankiViewModelProvider.notifier'));
    expect(vm, contains('Future<void> reloadSettings()'));
  });
}
