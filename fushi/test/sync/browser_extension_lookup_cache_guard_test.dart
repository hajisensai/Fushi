// BUG-1525：浏览器扩展查词的 popupOnly 快路径不得先物化完整 DictionaryEntry。
//
// FFI 原始结果缓存命中后，useCache:false 仍会重新构造全部 DictionaryEntry 并再次
// buildPopupJsonFromLookup；复杂词首查后每次仍有可感知延迟。词典与排序设置的变更路径
// 已统一 clearDictionaryResultsCache，因此扩展专用本机 HTTP 查询应保持 useCache:true。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('browser extension remote lookup reuses the materialized result cache',
      () {
    final String source =
        File('lib/src/models/app_model.dart').readAsStringSync();
    expect(
      source,
      matches(RegExp(
        r'searchWithWildcards:\s*wildcards,\s*'
        r'overrideMaximumTerms:\s*maximumTerms,\s*'
        r'useCache:\s*true,\s*'
        r'allowRemoteLookup:\s*false,',
      )),
      reason: '扩展本机查词不得绕过 AppModel 的已物化结果缓存',
    );
    expect(source, contains('scrollPosition: 0,'),
        reason: '远端快照必须重置唯一可变的滚动位置，不能泄漏缓存对象别名');
    expect(source, contains('result.popupJson = source.popupJson;'),
        reason: '浅快照仍必须复用缓存的 popupJson，不能重新物化弹框内容');
  });

  test('popupOnly fast path builds directly from cached FFI results', () {
    final String source =
        File('lib/src/models/app_model.dart').readAsStringSync();
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
    expect(fastPath, contains('getCachedFfiLookup'));
    expect(fastPath, contains('buildPopupJsonFromLookup'));
    expect(fastPath, isNot(contains('buildResultFromLookup')),
        reason: 'popupOnly 不能再为每条 glossary 构造完整 DictionaryEntry/extra');
  });
}
