import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/net/app_network_bindings.dart';
import 'package:fushi/src/utils/net/app_proxy.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:http/http.dart' as http;

import '../../helpers/source_guard.dart';

void main() {
  setUp(() {
    final previousMedia = ankiRemoteMediaHttpClientFactory;
    final previousAddon = ankiAddonDownloadHttpClientFactory;
    final previousDictionary = dictionaryDioFactory;
    final previousUrls = dictionaryUrlCandidatesResolver;
    final previousMode = appUserProxyModeReader;
    final previousProxy = appUserProxyReader;
    addTearDown(() {
      ankiRemoteMediaHttpClientFactory = previousMedia;
      ankiAddonDownloadHttpClientFactory = previousAddon;
      dictionaryDioFactory = previousDictionary;
      dictionaryUrlCandidatesResolver = previousUrls;
      appUserProxyModeReader = previousMode;
      appUserProxyReader = previousProxy;
    });
    ankiRemoteMediaHttpClientFactory = null;
    ankiAddonDownloadHttpClientFactory = null;
    dictionaryDioFactory = null;
    dictionaryUrlCandidatesResolver = null;
  });

  test('network readiness waits for system proxy discovery', () async {
    final Completer<void> discovery = Completer<void>();
    bool ready = false;
    final Future<void> installing = installAppNetworkBindings(
      primeProxy: () => discovery.future,
    ).then((_) => ready = true);
    await Future<void>.delayed(Duration.zero);
    expect(ready, isFalse);
    expect(ankiRemoteMediaHttpClientFactory, isNotNull);
    expect(ankiAddonDownloadHttpClientFactory, isNotNull);
    expect(dictionaryDioFactory, isNotNull);
    expect(dictionaryUrlCandidatesResolver, isNotNull);
    discovery.complete();
    await installing;
    expect(ready, isTrue);
  });

  test(
    'installed package factories route first public request through proxy',
    () async {
      final HttpServer proxy = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      addTearDown(() => proxy.close(force: true));
      final List<String> receivedHosts = <String>[];
      proxy.listen((HttpRequest request) {
        receivedHosts.add(request.uri.host);
        request.response.write('proxied');
        unawaited(request.response.close());
      });
      appUserProxyModeReader = () => kProxyModeManual;
      appUserProxyReader = () => '127.0.0.1:${proxy.port}';
      await installAppNetworkBindings(primeProxy: () async {});

      final HttpClient media = createAnkiRemoteMediaHttpClient();
      addTearDown(() => media.close(force: true));
      final HttpClientResponse mediaResponse = await (await media.getUrl(
        Uri.parse('http://media.invalid/voice'),
      )).close();
      await mediaResponse.drain<void>();
      final http.Client addon = ankiAddonDownloadHttpClientFactory!();
      addTearDown(addon.close);
      expect(
        (await addon.get(Uri.parse('http://addon.invalid/package'))).body,
        'proxied',
      );
      final Dio dictionary = await createDictionaryDio();
      addTearDown(() => dictionary.close(force: true));
      expect(
        (await dictionary.get<String>('http://dictionary.invalid/index')).data,
        'proxied',
      );
      expect(receivedHosts, <String>[
        'media.invalid',
        'addon.invalid',
        'dictionary.invalid',
      ]);
    },
  );

  test('both production entry points await bindings before network services', () {
    final String source = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    for (final String entry in <String>[
      'Future<void> _initialiseOnce() async',
      'Future<void> initialiseForDictionaryPopup() async',
    ]) {
      final String body = methodBody(source, entry);
      final int bindings = body.indexOf('await installAppNetworkBindings();');
      expect(bindings, greaterThanOrEqualTo(0), reason: entry);
      expect(
        bindings,
        lessThan(body.indexOf('MediaTrackingService(')),
        reason:
            '$entry must configure outbound clients before constructing services',
      );
      expect(body, isNot(contains('unawaited(primeAppProxy(')));
    }
  });
}
