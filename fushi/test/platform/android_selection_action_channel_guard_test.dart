import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String native = File(
    'android/app/src/main/java/app/fushi/reader/SelectionActionChannel.java',
  ).readAsStringSync();
  final String lower = native.toLowerCase();

  test('web search uses Android ACTION_WEB_SEARCH and SearchManager.QUERY', () {
    expect(native, contains('Intent.ACTION_WEB_SEARCH'));
    expect(native, contains('SearchManager.QUERY'));
    expect(native, contains('intent.putExtra(SearchManager.QUERY, query)'));
    expect(native, contains('result.success(launchWebSearch(context, query))'));
  });

  test('web search launches directly despite package visibility filtering', () {
    expect(native, isNot(contains('resolveActivity(')));
    expect(native, contains('context.startActivity(intent)'));
    expect(native, contains('catch (ActivityNotFoundException error)'));
    expect(
      native,
      contains(
        'catch (ActivityNotFoundException error) {\n'
        '            return false;\n'
        '        }',
      ),
    );
  });

  test('web search has no URL or vendor fallback', () {
    expect(native, isNot(contains('Intent.ACTION_VIEW')));
    expect(native, isNot(contains('Uri.parse')));
    expect(lower, isNot(contains('http://')));
    expect(lower, isNot(contains('https://')));
    expect(lower, isNot(contains('google.')));
    expect(lower, isNot(contains('bing.')));
  });

  test('main and popup engines register the same channel seam', () {
    final String main = File(
      'android/app/src/main/java/app/fushi/reader/MainActivity.java',
    ).readAsStringSync();
    final String popup = File(
      'android/app/src/main/java/app/fushi/reader/PopupEngineHolder.kt',
    ).readAsStringSync();
    final String registrant = File(
      'android/app/src/main/java/app/fushi/reader/'
      'FloatingDictPluginRegistrant.java',
    ).readAsStringSync();
    expect(main,
        contains('SelectionActionChannel.registerWith(flutterEngine, this)'));
    expect(
      popup,
      contains(
        'SelectionActionChannel.registerWith(engine, context.applicationContext)',
      ),
    );
    expect(registrant,
        contains('new dev.fluttercommunity.plus.share.SharePlusPlugin()'));
  });
}
