import 'dart:typed_data';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';

abstract class HibikiRemoteLookupService {
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
  });

  Future<RemoteAudioLookup?> lookupAudio({
    required String expression,
    required String reading,
  });
}

/// 浏览器扩展挖词的窄接口（与查词分离，避免 server 直接依赖 AnkiRepository）。
abstract class HibikiRemoteMiningService {
  /// 返回 MineResult.name（'success'|'duplicate'|'notConfigured'|'error'）。
  Future<String> mineEntry({
    required Map<String, String> fields,
    required String sentence,
  });
}

/// 把一次查词结果写入 Hibiki 查词历史（无 UI 副作用）。浏览器扩展 record 用。
abstract class HibikiRemoteHistoryService {
  void recordHistory(DictionarySearchResult result);
}

class RemoteAudioLookup {
  const RemoteAudioLookup({
    required this.bytes,
    required this.contentType,
  });

  final Uint8List bytes;
  final String contentType;
}
