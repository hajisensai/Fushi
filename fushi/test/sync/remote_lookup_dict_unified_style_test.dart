import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/fushi_remote_api_handlers.dart';
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart';

/// 守卫：浏览器扩展的查词弹窗跟随 app 的「统一词典样式」开关
/// （`popup_dictionary_unified_style`），与桌面查词窗、书内弹窗一致。
///
/// app 内弹窗由 popup_settings_injection 注入 `window.__fushiDictUnifiedStyle`；扩展跑同一份
/// popup.js，却没有这条注入——此前 popup.js「没注入就当作开」，扩展里永远是统一着色，
/// app 里关掉也没用。现在：`/api/lookup/dictionary` 随响应下发 `dictionaryUnifiedStyle`，
/// 扩展的 dict-media.js `applyFushiPopupCss` 只认 `true` 落到同名全局；popup.js 未注入即关。
class _StubLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async => DictionarySearchResult(searchTerm: term, bestLength: term.length);

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async => null;
}

Future<Map<String, dynamic>> _lookup(
  Map<String, dynamic> body, {
  bool Function()? unified,
}) => buildRemoteDictionaryLookupResponse(
  body,
  lookup: _StubLookup(),
  dictionaryUnifiedStyleProvider: unified,
);

void main() {
  group('「统一词典样式」随查词响应下发给浏览器扩展', () {
    test('app 开着 ⇒ 响应带 dictionaryUnifiedStyle: true', () async {
      final Map<String, dynamic> r = await _lookup(<String, dynamic>{
        'term': '猫',
      }, unified: () => true);
      expect(r['dictionaryUnifiedStyle'], isTrue);
    });

    test('app 关着 ⇒ 字段在且为 false（不是省略）', () async {
      final Map<String, dynamic> r = await _lookup(<String, dynamic>{
        'term': '猫',
      }, unified: () => false);
      expect(r.containsKey('dictionaryUnifiedStyle'), isTrue);
      expect(r['dictionaryUnifiedStyle'], isFalse);
    });

    test('每次查词都现读偏好（改了下次查词即生效，不走 CSS revision 缓存）', () async {
      bool value = false;
      final Map<String, dynamic> first = await _lookup(<String, dynamic>{
        'term': '猫',
        'stylesRevision': 'x',
      }, unified: () => value);
      value = true;
      final Map<String, dynamic> second = await _lookup(<String, dynamic>{
        'term': '猫',
        'stylesRevision': 'x',
      }, unified: () => value);
      expect(first['dictionaryUnifiedStyle'], isFalse);
      expect(second['dictionaryUnifiedStyle'], isTrue);
    });

    test('空 term 的空结果也带该字段', () async {
      final Map<String, dynamic> r = await _lookup(<String, dynamic>{
        'term': '',
      }, unified: () => true);
      expect(r['popupJson'], isNull);
      expect(r['dictionaryUnifiedStyle'], isTrue);
    });

    test('未注入供给器 ⇒ 不带该字段（扩展按关处理）', () async {
      final Map<String, dynamic> r = await _lookup(<String, dynamic>{
        'term': '猫',
      });
      expect(r.containsKey('dictionaryUnifiedStyle'), isFalse);
    });

    test('app 侧接线：app_model → manager → server → handler 读同一个偏好', () {
      final String appModel = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      expect(
        appModel,
        contains(
          'dictionaryUnifiedStyleProvider: () => dictionaryUnifiedStyle',
        ),
        reason: '必须读 app 内弹窗注入用的同一个偏好，不得另存一份',
      );
      final String manager = File(
        'lib/src/sync/yomitan_api_server_manager.dart',
      ).readAsStringSync();
      expect(
        manager,
        contains(
          'dictionaryUnifiedStyleProvider: _dictionaryUnifiedStyleProvider',
        ),
      );
      final String server = File(
        'lib/src/sync/yomitan_api_server.dart',
      ).readAsStringSync();
      expect(
        server,
        contains(
          'dictionaryUnifiedStyleProvider: _dictionaryUnifiedStyleProvider',
        ),
      );
    });

    test('popup.js 未注入即关；扩展两镜像的 dict-media.js 只认 true 落全局', () {
      final String popup = File('assets/popup/popup.js').readAsStringSync();
      expect(
        popup,
        contains('window.__fushiDictUnifiedStyle === true'),
        reason: '宿主没注入（扩展连不上 app）必须按关处理，与 app 默认一致',
      );
      expect(popup, isNot(contains('__fushiDictUnifiedStyle !== false')));
      for (final String root in <String>[
        'assets/browser_extension',
        '../tools/browser-extension',
      ]) {
        final String dictMedia = File(
          '$root/vendor/dict-media.js',
        ).readAsStringSync();
        expect(
          dictMedia,
          contains(
            'window.__fushiDictUnifiedStyle = data.dictionaryUnifiedStyle === true;',
          ),
          reason: '[$root] 扩展没把 app 的开关落到 popup.js 读的全局上',
        );
      }
    });
  });
}
