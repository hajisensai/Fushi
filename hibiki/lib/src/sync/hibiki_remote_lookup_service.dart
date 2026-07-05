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

  /// TODO-1176：浏览器扩展查词弹窗制卡按钮真查重（`+`→`✓`，与 app 内一致）。经 Anki 后端
  /// （AnkiConnect `findNotes` / AnkiDroid `findDuplicateNotes`）判断 [expression]/[reading]
  /// 是否已在当前牌组+笔记类型存在。与 app 内 `dictionary_page_mixin.checkDuplicate` 同一
  /// `repo.isDuplicate` 路径，fail-soft（后端不可用/未配置 → false，绝不让查重探测阻断查词）。
  Future<bool> isDuplicate({
    required String expression,
    required String reading,
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
