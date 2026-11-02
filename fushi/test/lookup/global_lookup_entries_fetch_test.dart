import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/global_lookup_render.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 应用外宿主（桌面全局查词窗 / 游戏内查词卡片）的大结果词条取回——in-app 弹窗
/// P1-B 在裸 WebView2 上的同一做法。
void main() {
  group('GlobalLookupEntriesStore', () {
    test('同一个结果对象的令牌稳定，不同结果不同', () {
      final GlobalLookupEntriesStore store = GlobalLookupEntriesStore();
      final DictionarySearchResult a = DictionarySearchResult(searchTerm: 'a');
      final DictionarySearchResult b = DictionarySearchResult(searchTerm: 'b');
      expect(store.tokenFor(a), store.tokenFor(a));
      expect(store.tokenFor(a), isNot(store.tokenFor(b)));
    });

    test('只有达到阈值的结果才登记取回，字节按地址原样取回', () {
      final GlobalLookupEntriesStore store = GlobalLookupEntriesStore();
      expect(store.register(1, '[]'), isNull, reason: '小结果仍走字面量');

      final String big = jsonEncode(<String>['x' * kPopupEntriesFetchMinChars]);
      final String? url = store.register(7, big);
      expect(url, '${GlobalLookupEntriesStore.urlPrefix}desktop/7.json');
      expect(utf8.decode(store.bytesFor(url!)!), big);
      expect(
        store.bytesFor('${GlobalLookupEntriesStore.urlPrefix}desktop/8.json'),
        isNull,
      );
      expect(store.bytesFor('image://x.png'), isNull);
    });

    test('只保留仍在栈里的帧的字节', () {
      final GlobalLookupEntriesStore store = GlobalLookupEntriesStore();
      final String big = 'y' * kPopupEntriesFetchMinChars;
      final String url1 = store.register(1, big)!;
      final String url2 = store.register(2, big)!;
      store.retain(<int>[2]);
      expect(store.bytesFor(url1), isNull);
      expect(store.bytesFor(url2), isNotNull);
    });

    test('取回失败过之后一律走字面量', () {
      final GlobalLookupEntriesStore store = GlobalLookupEntriesStore()
        ..fetchUnavailable = true;
      expect(store.register(3, 'z' * kPopupEntriesFetchMinChars), isNull);
    });

    // PR #2763 审查：桌面窗与游戏卡片是两个 WebView2 宿主，共用一份 store 时桌面的
    // retain 会删掉游戏卡片还没取走的字节，对面 404 又把回退置成全进程永久生效。
    test('每个宿主一份：一方 retain / 回退不影响另一方，地址互不相认', () {
      final GlobalLookupEntriesStore desktop = GlobalLookupEntriesStore();
      final GlobalLookupEntriesStore card = GlobalLookupEntriesStore(
        hostKey: 'gal:1234',
      );
      final String big = 'w' * kPopupEntriesFetchMinChars;
      final String cardUrl = card.register(5, big)!;
      final String desktopUrl = desktop.register(6, big)!;
      desktop.retain(<int>[6]);
      expect(card.bytesFor(cardUrl), isNotNull, reason: '桌面渲染不得删游戏卡片的字节');
      expect(desktop.bytesFor(cardUrl), isNull);
      expect(card.bytesFor(desktopUrl), isNull);
      desktop.fetchUnavailable = true;
      expect(desktop.register(7, big), isNull);
      expect(card.register(8, big), isNotNull, reason: '回退只作用于取回失败的宿主');
    });
  });

  group('接线', () {
    final String controller = File(
      'lib/src/lookup/global_lookup_controller.dart',
    ).readAsStringSync();
    final String native = File(
      'windows/runner/global_lookup_window.cpp',
    ).readAsStringSync();

    test('原生拦截的地址前缀与 Dart 一致，并回 JSON + 跨源头', () {
      expect(
        native,
        contains(
          'kGlobalLookupEntriesUrlPrefix[] =\n'
          '    "${GlobalLookupEntriesStore.urlPrefix}";',
        ),
      );
      expect(
        native,
        contains('const bool is_entries = IsGlobalLookupEntriesUrl(url);'),
      );
      expect(native, contains('!is_image && !is_dictmedia && !is_entries'));
      expect(native, contains('Access-Control-Allow-Origin: *'));
    });

    test('媒体解析先查词条取回，渲染后只留在栈帧的字节', () {
      final int resolve = controller.indexOf(
        'Future<Uint8List> _resolveMedia(String url) async {',
      );
      expect(resolve, isNonNegative);
      expect(
        controller.indexOf('store.bytesFor(url)', resolve),
        greaterThan(resolve),
      );
      expect(
        controller,
        contains(
          'final GlobalLookupEntriesStore entriesStore = _entriesStoreFor(hostKey);',
        ),
      );
      expect(controller, contains('entriesStore: entriesStore,'));
      expect(controller, contains('entriesStore.retain('));
    });

    test('异步取回的帧在描述里标明，宿主据此等根卡渲染完再报尺寸', () {
      final String render = File(
        'lib/src/lookup/global_lookup_render.dart',
      ).readAsStringSync();
      expect(
        render,
        contains("if (settings.entriesAsync) map['entriesAsync'] = true;"),
      );
      expect(render, contains('entriesAsync: true,'));
      final String host = File(
        'assets/popup/global_lookup_host.js',
      ).readAsStringSync();
      expect(
        host,
        contains('record.awaitingAsyncEntries = d.entriesAsync === true;'),
      );
    });

    test('取回失败回退到字面量并重渲', () {
      final int start = controller.indexOf(
        "if (handler == 'popupEntriesFetchFailed') {",
      );
      expect(start, isNonNegative);
      final String body = controller.substring(
        start,
        controller.indexOf('return;', start),
      );
      expect(body, contains('failedStore.fetchUnavailable = true'));
      expect(body, contains('_entriesStoreFor('), reason: '只回退取回失败的那个宿主');
      expect(body, contains('unawaited(_renderStack())'));
    });
  });
}
