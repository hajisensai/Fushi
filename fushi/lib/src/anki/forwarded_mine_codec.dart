/// 一次制卡请求（`mineEntry` 的 rawPayloadJson + [AnkiMiningContext]）与
/// [ForwardedMinePayload] 之间的双向转换。
///
/// 两个方向各有一个消费方以外的第二个用户，所以抽在这里而不是各写一份：
/// * **打包**（[ForwardedMinePayloadBuilder]）：互联「制卡到已配对设备」把请求发给
///   主机前要把所有本地媒体读成字节；待发制卡队列入队时要趁调用方清理临时文件前
///   把同样的东西冻结下来。
/// * **还原**（[withMaterializedMiningContext]）：主机收到转发请求、待发队列补发时，
///   都要把字节落回本机文件、重建 context，再走本地 `mineEntry` 渲染链路。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';

// 还原方向在 fushi_engine（无头服务端当落地设备也用）；转导出，既有 import 不变。
export 'package:fushi_engine/sync/forwarded_mine_materialize.dart';

/// 加载一条词典媒体（外字/内嵌图）的字节。默认走 `FushiDicts.getMediaFile`。
typedef DictMediaByteLoader =
    Uint8List? Function(String dictionary, String path);

/// 读取本地文件字节（封面/音频临时文件）。默认走 `dart:io File`；文件缺失返回 null。
typedef LocalFileByteLoader = Future<Uint8List?> Function(String path);

/// 把一次制卡请求打包成 [ForwardedMinePayload]，媒体全部读成字节。
///
/// 媒体的四个来源：封面 ← `context.coverPath`；句子音频 ←
/// `context.sentenceAudioPath`；单词音频 ← `fields['audio']`（仅本地文件与
/// `data:` URI 搬字节，`http` URL 原样留在 rawPayloadJson）；词典外字 ←
/// `FushiDicts.getMediaFile`。任何一样读不到只当缺失，不影响其余。
class ForwardedMinePayloadBuilder {
  ForwardedMinePayloadBuilder({
    DictMediaByteLoader? dictMediaLoader,
    LocalFileByteLoader? fileByteLoader,
  }) : _dictMediaLoader = dictMediaLoader ?? _defaultDictMediaLoader,
       _fileByteLoader = fileByteLoader ?? _defaultFileByteLoader;

  final DictMediaByteLoader _dictMediaLoader;
  final LocalFileByteLoader _fileByteLoader;

  static Uint8List? _defaultDictMediaLoader(String dictionary, String path) =>
      FushiDicts.instance.getMediaFile(dictionary, path);

  static Future<Uint8List?> _defaultFileByteLoader(String path) async {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<ForwardedMinePayload> build({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    // 封面 + 句子音频：context 里是本地文件路径，读成字节。
    final Uint8List? coverBytes = await _readPath(context.coverPath);
    final Uint8List? sentenceAudioBytes = context.synchronizedVideo
        ? null
        : await _readPath(context.sentenceAudioPath);

    // 单词音频 + 词典外字：从 rawPayloadJson 解析。解析失败不致命——仍保留文本卡。
    Uint8List? wordAudioBytes;
    String? wordAudioExt;
    List<ForwardedDictMedia> dictMedia = const <ForwardedDictMedia>[];
    try {
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(
        jsonDecode(rawPayloadJson) as Map<String, dynamic>,
      );
      final AnkiAudioRefKind audioKind = AnkiAudioRef.classify(parsed.audio);
      if (audioKind == AnkiAudioRefKind.localFile) {
        final String localPath = AnkiAudioRef.localPath(parsed.audio);
        wordAudioBytes = await _readPath(localPath);
        wordAudioExt = fileExtensionOf(localPath);
      } else if (audioKind == AnkiAudioRefKind.dataUri) {
        // BUG-1050：`data:` 内联单词发音（本地音频库命中）——解码成字节带走，
        // 否则转发 / 补发的卡丢单词音频（与本地落卡同一根因）。
        final AnkiAudioData? data = AnkiAudioRef.decodeDataUri(parsed.audio);
        if (data != null) {
          wordAudioBytes = data.bytes;
          wordAudioExt = data.extension;
        }
      }
      dictMedia = _collectDictionaryMedia(parsed.dictionaryMedia);
    } catch (_) {
      // 非结构化 payload（视频等直接传 fields）——无词典外字/本地音频要搬。
    }

    return ForwardedMinePayload(
      rawPayloadJson: rawPayloadJson,
      sentence: context.sentence,
      cueSentence: context.cueSentence,
      documentTitle: context.documentTitle,
      sentenceOffset: context.sentenceOffset,
      source: context.source?.name,
      sourceLink: context.sourceLink,
      bookTitleTag: context.bookTitleTag,
      collectionTag: context.collectionTag,
      charPositionTag: context.charPositionTag,
      clipStartMs: context.clipStartMs,
      clipEndMs: context.clipEndMs,
      coverBytes: coverBytes,
      coverExt: fileExtensionOf(context.coverPath),
      sentenceAudioBytes: sentenceAudioBytes,
      sentenceAudioExt: fileExtensionOf(context.sentenceAudioPath),
      synchronizedVideo: context.synchronizedVideo,
      wordAudioBytes: wordAudioBytes,
      wordAudioExt: wordAudioExt,
      dictionaryMedia: dictMedia,
    );
  }

  List<ForwardedDictMedia> _collectDictionaryMedia(
    List<DictionaryMedia> media,
  ) {
    final List<ForwardedDictMedia> out = <ForwardedDictMedia>[];
    for (final DictionaryMedia m in media) {
      if (m.dictionary.isEmpty || m.path.isEmpty) continue;
      final Uint8List? bytes = _dictMediaLoader(m.dictionary, m.path);
      if (bytes == null || bytes.isEmpty) continue;
      out.add(
        ForwardedDictMedia(
          dictionary: m.dictionary,
          path: m.path,
          bytes: bytes,
        ),
      );
    }
    return out;
  }

  Future<Uint8List?> _readPath(String? path) async {
    if (path == null || path.isEmpty) return null;
    return _fileByteLoader(path);
  }
}

/// 路径的扩展名（不含点）；没有扩展名返回 null。
String? fileExtensionOf(String? path) {
  if (path == null || path.isEmpty) return null;
  final String base = path.split(RegExp(r'[/\\]')).last;
  final int dot = base.lastIndexOf('.');
  if (dot < 0 || dot == base.length - 1) return null;
  return base.substring(dot + 1);
}
