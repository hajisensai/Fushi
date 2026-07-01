import 'dart:typed_data';

import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/src/sync/immersion_mine_payload.dart';

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

  /// TODO-1000：沉浸制卡（截图/GIF/音频 + 不回放）。实现方持 AnkiRepository，可调后台软解
  /// 实例（2B）；server 只解析 body 成 [ImmersionMinePayload] 后转发，不 new 引擎、不碰 repo。
  /// 返回 MineResult.name。
  Future<String> mineImmersion(ImmersionMinePayload payload);
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
