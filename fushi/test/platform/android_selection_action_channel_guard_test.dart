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

  test('web search targets the default browser, then falls back (BUG-2491)', () {
    // ACTION_WEB_SEARCH is resolved independently of the default-browser role;
    // a bare intent lands on the OEM stock browser no matter what the user
    // picked. Resolve the VIEW-https holder and aim the search at it first.
    expect(
      native,
      contains('new Intent(Intent.ACTION_VIEW, Uri.parse(BROWSER_PROBE_URL))'),
    );
    expect(native, contains('.addCategory(Intent.CATEGORY_BROWSABLE)'));
    expect(
      native,
      contains('.resolveActivity(probe, PackageManager.MATCH_DEFAULT_ONLY)'),
    );
    // No default chosen → resolver activity reports the "android" package;
    // treat that as "no browser" instead of targeting the resolver.
    expect(
      native,
      contains('return "android".equals(packageName) ? null : packageName;'),
    );
    expect(
      native,
      contains('context.startActivity(new Intent(intent).setPackage(browser))'),
    );
    // The probe URL is only ever resolved, never launched.
    expect(native, isNot(contains('startActivity(probe')));
  });

  test('web search keeps the bare-intent fallback when targeting fails', () {
    // Browser without ACTION_WEB_SEARCH → ActivityNotFoundException on the
    // targeted attempt → bare intent (previous behaviour) → false only when
    // nothing handles it at all.
    expect(native, contains('context.startActivity(intent)'));
    expect(
      native,
      contains(
        'catch (ActivityNotFoundException error) {\n'
        '            return false;\n'
        '        }',
      ),
    );
    expect(
      'catch (ActivityNotFoundException error)'.allMatches(native).length,
      1,
    );
    // The targeted attempt also has to swallow SecurityException: a default
    // browser that registers ACTION_WEB_SEARCH on a non-exported activity
    // (targetSdk 31+) must fall through to the bare intent, not crash the
    // method channel.
    expect(
      native,
      contains('catch (ActivityNotFoundException | SecurityException error)'),
    );
  });

  test('manifest declares the VIEW-https query the browser probe needs', () {
    // Android 11+ package visibility: without this, resolveActivity() sees no
    // browser and every search silently degrades to the bare intent.
    final String manifest = File(
      'android/app/src/main/AndroidManifest.xml',
    ).readAsStringSync();
    final int queries = manifest.indexOf('<queries>');
    final int queriesEnd = manifest.indexOf('</queries>');
    expect(queries, greaterThan(-1));
    final String block = manifest.substring(queries, queriesEnd);
    expect(
      block,
      contains('<action android:name="android.intent.action.VIEW" />'),
    );
    expect(
      block,
      contains('<category android:name="android.intent.category.BROWSABLE" />'),
    );
    expect(block, contains('<data android:scheme="https" />'));
  });

  test('web search has no URL or vendor fallback', () {
    // The only URL in the file is the never-launched browser probe.
    expect(native, contains('BROWSER_PROBE_URL = "https://example.com/"'));
    expect('https://'.allMatches(lower).length, 1);
    expect(lower, isNot(contains('http://')));
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
    expect(
      main,
      contains('SelectionActionChannel.registerWith(flutterEngine, this)'),
    );
    expect(
      popup,
      contains(
        'SelectionActionChannel.registerWith(engine, context.applicationContext)',
      ),
    );
    expect(
      registrant,
      contains('new dev.fluttercommunity.plus.share.SharePlusPlugin()'),
    );
  });
}
