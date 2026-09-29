/// [ForwardedMinePayload] 的「还原」方向：把搬来的媒体字节落回本机文件、重建
/// [AnkiMiningContext]，再交给本机的制卡链路渲染。
///
/// 主机收到互联转发、待发队列补发、无头服务端当落地设备，三处共用这一份（零 Flutter）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';

/// 把 [payload] 的媒体字节落成本机临时文件 / 词典缓存、重建 [AnkiMiningContext]，
/// 交给 [action]（通常是 `repo.mineEntry`）；[action] 结束后回收临时文件。
///
/// 走的是与 app 内本地制卡**完全同一**的渲染链路：字段映射、牌组都用执行这一步的
/// 那台设备自己的 Anki 配置。
///
/// [bundledMediaOnly]：载荷来自跨设备中转（任何能写同步后端的一方都能放进来）时
/// 必须为 true。此时 rawPayloadJson 里凡不是本载荷随附字节的媒体引用一律剥掉——
/// 单词音频只能指向这里刚写出的临时文件，否则置空；词典外字只留随附了字节的条目。
/// 绝不透传对端给的本地路径 / URL：下游 `materializeAnkiWordAudio` 会读本地文件、
/// 对任意 URL 发 GET（BUG-2778）。rawPayloadJson 不是 JSON 对象时抛
/// [FormatException]（无法剥离就不落）。
Future<T> withMaterializedMiningContext<T>(
  ForwardedMinePayload payload,
  Future<T> Function(String rawPayloadJson, AnkiMiningContext context) action, {
  bool bundledMediaOnly = false,
}) async {
  // 先剥离再落文件：剥不了就不必建临时目录。
  String rawPayloadJson = bundledMediaOnly
      ? _stripUnbundledMedia(payload)
      : payload.rawPayloadJson;
  final Directory tmp = Directory.systemTemp.createTempSync('fushi_fwd_mine_');
  try {
    // ① 封面 → 临时文件 → context.coverPath
    String? coverPath;
    if (payload.coverBytes != null) {
      final File f = File('${tmp.path}/cover.${_ext(payload.coverExt)}');
      await f.writeAsBytes(payload.coverBytes!, flush: true);
      coverPath = f.path;
    }
    // ② 句子音频 → 临时文件 → context.sentenceAudioPath
    String? sentenceAudioPath = payload.synchronizedVideo ? coverPath : null;
    if (payload.sentenceAudioBytes != null && !payload.synchronizedVideo) {
      final File f = File(
        '${tmp.path}/sentence_audio.${_ext(payload.sentenceAudioExt)}',
      );
      await f.writeAsBytes(payload.sentenceAudioBytes!, flush: true);
      sentenceAudioPath = f.path;
    }
    // ③ 单词音频（本地文件）→ 临时文件 → 改写 rawPayloadJson 的 audio 字段为本机路径
    if (payload.wordAudioBytes != null) {
      final File f = File(
        '${tmp.path}/word_audio.${_ext(payload.wordAudioExt)}',
      );
      await f.writeAsBytes(payload.wordAudioBytes!, flush: true);
      rawPayloadJson = _rewriteAudioField(rawPayloadJson, f.path);
    }
    // ④ 词典外字 → 落到 repo 会读取的共享缓存目录（按 path 派生同名，与 repo 读取对齐）
    await _materializeDictionaryMedia(payload.dictionaryMedia);
    // ⑤ 重建 context
    final AnkiMiningContext context = AnkiMiningContext(
      sentence: payload.sentence,
      cueSentence: payload.cueSentence,
      documentTitle: payload.documentTitle,
      coverPath: coverPath,
      sentenceAudioPath: sentenceAudioPath,
      synchronizedVideo: payload.synchronizedVideo,
      sentenceOffset: payload.sentenceOffset,
      source: miningSourceFromName(payload.source),
      sourceLink: payload.sourceLink,
      bookTitleTag: payload.bookTitleTag,
      collectionTag: payload.collectionTag,
      charPositionTag: payload.charPositionTag,
      // 片段时间窗原样透传，有效性由 formatClipTimestamp 单点判定——非视频来源
      // 两端为 null，渲染成空串。
      clipStartMs: payload.clipStartMs,
      clipEndMs: payload.clipEndMs,
    );
    return await action(rawPayloadJson, context);
  } finally {
    // 临时封面/音频在 action 落卡（读+storeMedia）完成后回收；词典缓存目录是共享的
    // （与本地 writeDictionaryMediaCache 同址），下次覆盖即可，不在此删。
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {
      // best-effort：卡已经落下（或已失败），临时目录删不掉（Windows 上被占用）
      // 只是留一点系统临时目录垃圾，不能把落卡结果变成异常。
    }
  }
}

/// 临时文件扩展名：再过一遍 [ForwardedMinePayload.sanitizeExt]（载荷也可能不经
/// `fromJson` 直接构造），缺失 / 非法退回 `bin`。
String _ext(String? ext) => ForwardedMinePayload.sanitizeExt(ext) ?? 'bin';

/// 跨设备中转载荷的媒体剥离：`audio` 置空（有随附字节时稍后改写成临时文件），
/// `dictionaryMedia` 只留随附了字节的 `(dictionary, path)`。
String _stripUnbundledMedia(ForwardedMinePayload payload) {
  final Object? decoded;
  try {
    decoded = jsonDecode(payload.rawPayloadJson);
  } on FormatException {
    throw const FormatException('forwarded mine fields are not a JSON object');
  }
  if (decoded is! Map) {
    throw const FormatException('forwarded mine fields are not a JSON object');
  }
  final Map<String, dynamic> map = Map<String, dynamic>.from(decoded);
  if (map.containsKey('audio')) map['audio'] = '';

  final Set<String> bundled = <String>{
    for (final ForwardedDictMedia m in payload.dictionaryMedia)
      if (m.bytes != null && m.bytes!.isNotEmpty)
        _dictKey(m.dictionary, m.path),
  };
  final Object? dmRaw = map['dictionaryMedia'];
  if (dmRaw != null) {
    Object? list = dmRaw;
    final bool encoded = dmRaw is String;
    if (dmRaw is String) {
      try {
        list = dmRaw.isEmpty ? const <Object?>[] : jsonDecode(dmRaw);
      } on FormatException {
        list = const <Object?>[];
      }
    }
    final List<Map<String, dynamic>> kept = <Map<String, dynamic>>[
      if (list is List)
        for (final Object? e in list)
          if (e is Map &&
              bundled.contains(
                _dictKey('${e['dictionary'] ?? ''}', '${e['path'] ?? ''}'),
              ))
            Map<String, dynamic>.from(e),
    ];
    map['dictionaryMedia'] = encoded ? jsonEncode(kept) : kept;
  }
  return jsonEncode(map);
}

String _dictKey(String dictionary, String path) => '$dictionary\u0000$path';

/// 把 rawPayloadJson 里的 `audio` 字段改写成本机文件路径。
String _rewriteAudioField(String rawJson, String newAudioPath) {
  try {
    final Map<String, dynamic> map =
        jsonDecode(rawJson) as Map<String, dynamic>;
    map['audio'] = newAudioPath;
    return jsonEncode(map);
  } catch (_) {
    return rawJson;
  }
}

/// 把词典外字字节落到 [ankiDictionaryMediaCacheDirPath]，命名与 repo 读取对齐
/// （[ankiDictionaryMediaCacheFilename]）。执行方未必装同款词典，故必须用搬来的字节。
Future<void> _materializeDictionaryMedia(List<ForwardedDictMedia> media) async {
  if (media.isEmpty) return;
  final Directory dir = Directory(ankiDictionaryMediaCacheDirPath());
  if (!dir.existsSync()) dir.createSync(recursive: true);
  for (final ForwardedDictMedia m in media) {
    final Uint8List? bytes = m.bytes;
    if (bytes == null || bytes.isEmpty || m.path.isEmpty) continue;
    final String fname = ankiDictionaryMediaCacheFilename(m.dictionary, m.path);
    // 防御：文件名扩展名派生自对端提供的 path，理论上可含分隔符。落在缓存目录之外 /
    // 嵌套子目录是不可接受的——直接跳过该条（外字缺失即降级），绝不写出目录。
    if (fname.contains('/') || fname.contains('\\')) continue;
    final File f = File('${dir.path}/$fname');
    await f.writeAsBytes(bytes, flush: true);
  }
}

/// [AnkiMiningSource.name] 的反解；未知 / null 返回 null（不追加分类标签）。
AnkiMiningSource? miningSourceFromName(String? name) {
  for (final AnkiMiningSource s in AnkiMiningSource.values) {
    if (s.name == name) return s;
  }
  return null;
}
