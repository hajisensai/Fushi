import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_api_handlers.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_service.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 守卫：`/api/lookup/dictionary` 必须把「查词后自动朗读」偏好（`autoReadOnLookup`）随查词
/// 响应下发给浏览器扩展。
///
/// 背景：同一个全局偏好在 app 内弹窗、app 外瞬态浮窗、剪贴板面板三个表面早就生效
/// （BUG-1210 就是为「一个表面接了线、另一个完全无效」收的口），浏览器扩展是最后一个漏掉
/// 的表面——用户在扩展里查词必须手动点 ♪。扩展侧不另立开关，只认这个字段，所以这条通道断
/// 了就等于自动朗读在扩展里整个不存在。
class _StubLookup implements FushiRemoteLookupService {
  @override
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  }) async =>
      DictionarySearchResult(searchTerm: term, bestLength: term.length);

  @override
  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  }) async =>
      null;
}

Future<Map<String, dynamic>> _lookup(
  Map<String, dynamic> body, {
  bool Function()? autoRead,
}) =>
    buildRemoteDictionaryLookupResponse(
      body,
      lookup: _StubLookup(),
      autoReadOnLookupProvider: autoRead,
    );

void main() {
  group('查词后自动朗读偏好下发', () {
    test('偏好开着 ⇒ 响应带 autoReadOnLookup: true', () async {
      final Map<String, dynamic> r =
          await _lookup(<String, dynamic>{'term': '猫'}, autoRead: () => true);
      expect(r['autoReadOnLookup'], isTrue,
          reason: '扩展只认这个字段，不下发等于自动朗读在扩展里不存在');
    });

    test('偏好关着 ⇒ 字段在且为 false（不是省略）', () async {
      final Map<String, dynamic> r =
          await _lookup(<String, dynamic>{'term': '猫'}, autoRead: () => false);
      expect(r.containsKey('autoReadOnLookup'), isTrue);
      expect(r['autoReadOnLookup'], isFalse);
    });

    test('空 term 的空结果也带该字段（扩展的门控不因空查询漂移）', () async {
      final Map<String, dynamic> r =
          await _lookup(<String, dynamic>{'term': ''}, autoRead: () => true);
      expect(r['popupJson'], isNull);
      expect(r['autoReadOnLookup'], isTrue);
    });

    test('未注入供给器（sync host / 老部署）⇒ 完全不带该字段（向后兼容）', () async {
      final Map<String, dynamic> r =
          await _lookup(<String, dynamic>{'term': '猫'});
      expect(r.containsKey('autoReadOnLookup'), isFalse);
    });

    test('app 侧把偏好接到扩展 server 上（app_model → manager → server → handler）', () {
      final String appModel =
          File('lib/src/models/app_model.dart').readAsStringSync();
      expect(appModel, contains('autoReadOnLookupProvider:'),
          reason: 'app_model 没把 autoReadOnLookupProvider 交给 YomitanApiServerManager');
      expect(appModel, contains('ReaderFushiSource.instance.autoReadOnLookup'),
          reason: '必须读 app 内自动朗读的同一个真相源，不得在扩展这条线上另存一份');
      final String manager =
          File('lib/src/sync/yomitan_api_server_manager.dart').readAsStringSync();
      expect(manager, contains('autoReadOnLookupProvider'),
          reason: 'manager 没把供给器透传给 YomitanApiServer');
      final String server =
          File('lib/src/sync/yomitan_api_server.dart').readAsStringSync();
      expect(server, contains('autoReadOnLookupProvider: _autoReadOnLookupProvider'),
          reason: 'YomitanApiServer 没把供给器交给共享 handler');
    });

    test('扩展两镜像都按这个字段接了自动朗读（页面弹窗与侧边栏共用一份实现）', () {
      const Map<String, String> mirrors = <String, String>{
        'assets': 'assets/browser_extension',
        'tools': '../tools/browser-extension',
      };
      mirrors.forEach((String name, String root) {
        final String autoRead = File('$root/auto-read.js').readAsStringSync();
        expect(autoRead, contains('window.fushiAutoReadFirstEntry'),
            reason: '[$name] 缺共享的自动朗读实现');
        expect(autoRead, contains("callHandler('resolveWordAudio'"),
            reason: '[$name] 自动朗读没走点 ♪ 的同一条解析路径');
        for (final String surface in <String>['content.js', 'side-panel.js']) {
          final String code = File('$root/$surface').readAsStringSync();
          expect(code, contains('fushiAutoReadFirstEntry'),
              reason: '[$name] $surface 没接自动朗读——两个表面行为漂开正是 BUG-1210 那个病');
          expect(code, contains('autoReadOnLookup'),
              reason: '[$name] $surface 没读 app 下发的偏好');
        }
      });
    });
  });
}
