// BUG-1525：浏览器扩展查词的 popupOnly 快路径不得先物化完整 DictionaryEntry。
//
// FFI 原始结果缓存命中后，useCache:false 仍会重新构造全部 DictionaryEntry 并再次
// buildPopupJsonFromLookup；复杂词首查后每次仍有可感知延迟。词典与排序设置的变更路径
// 已统一 clearDictionaryResultsCache，因此扩展专用本机 HTTP 查询应保持 useCache:true。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'browser extension remote lookup reuses the materialized result cache',
    () {
      final String source = File(
        'lib/src/models/app_model.dart',
      ).readAsStringSync();
      // 原写法用一条只允许空白的正则串联四个参数，而实现里这四行中间夹着三行
      // 中文注释，`\s` 匹配不到 `//` —— 断言恒为假，既永久红又零防护。改成与下方
      // 第二条同形的「先取方法切片再逐项 contains」，注释怎么改都不影响判据。
      final int remoteStart = source.indexOf(
        // 公开的 searchDictionary / searchDictionaryInLanguage 都委托给这一份私有实现。
        'Future<DictionarySearchResult?> _searchDictionary({',
      );
      expect(
        remoteStart,
        greaterThanOrEqualTo(0),
        reason: '找不到扩展本机查词的 searchDictionary 实现',
      );
      final int remoteEnd = source.indexOf('\n  @override', remoteStart + 1);
      expect(remoteEnd, greaterThan(remoteStart));
      final String remoteSearch = source.substring(remoteStart, remoteEnd);
      for (final String needle in const <String>[
        'searchWithWildcards: wildcards,',
        'overrideMaximumTerms: maximumTerms,',
        'useCache: true,',
        'allowRemoteLookup: false,',
      ]) {
        expect(
          remoteSearch,
          contains(needle),
          reason: '扩展本机查词不得绕过 AppModel 的已物化结果缓存（缺 $needle）',
        );
      }
      expect(
        source,
        contains('scrollPosition: 0,'),
        reason: '远端快照必须重置唯一可变的滚动位置，不能泄漏缓存对象别名',
      );
      expect(
        source,
        contains('result.popupJson = source.popupJson;'),
        reason: '浅快照仍必须复用缓存的 popupJson，不能重新物化弹框内容',
      );
    },
  );

  test('popupOnly fast path builds popup JSON only, in the background', () {
    final String source = File(
      'lib/src/models/app_model.dart',
    ).readAsStringSync();
    final int start = source.indexOf(
      'Future<RemoteDictionaryPopupLookup?> searchDictionaryPopup(',
    );
    final int end = source.indexOf(
      'Future<RemoteAudioLookup?> lookupAudio(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final String fastPath = source.substring(start, end);
    expect(fastPath, contains('getCachedPopupSearch'));
    // 原始结果缓存与构建都在后台查词 isolate：请求必须声明 popupOnly，后台据此
    // 只跑 buildPopupJsonFromLookup（background_lookup.dart 的 popupOnly 分支）。
    expect(fastPath, contains('lookupInBackground('));
    expect(fastPath, contains('popupOnly: true,'));
    expect(
      fastPath,
      isNot(contains('buildResultFromLookup')),
      reason: 'popupOnly 不能再为每条 glossary 构造完整 DictionaryEntry/extra',
    );
    final String worker = File(
      '../packages/fushi_dictionary/lib/src/engine/background_lookup.dart',
    ).readAsStringSync();
    final int popupBranch = worker.indexOf('if (request.popupOnly) {');
    expect(popupBranch, greaterThanOrEqualTo(0));
    final int branchEnd = worker.indexOf('\n  }\n', popupBranch);
    final String branch = worker.substring(popupBranch, branchEnd);
    expect(branch, contains('buildPopupJsonFromLookup('));
    expect(
      branch,
      isNot(contains('buildResultFromLookup(')),
      reason: 'popupOnly 分支不能物化 DictionaryEntry',
    );
  });
}
