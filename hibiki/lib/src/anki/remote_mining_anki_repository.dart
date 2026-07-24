import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_dictionary/hibiki_dictionary.dart';

import 'package:hibiki/src/sync/forwarded_mine_payload.dart';
import 'package:hibiki/src/sync/hibiki_remote_mining_client.dart';
import 'package:hibiki/src/sync/sync_backend.dart';

/// 加载一条词典媒体（外字/内嵌图）的字节。默认走 `HoshiDicts.getMediaFile`。
typedef DictMediaByteLoader = Uint8List? Function(
    String dictionary, String path);

/// 读取本地文件字节（封面/音频临时文件）。默认走 `dart:io File`；文件缺失返回 null。
typedef LocalFileByteLoader = Future<Uint8List?> Function(String path);

/// 「制卡到服务端」的 Anki 仓库包装：把 [mineEntry]/[isDuplicate] 经互联链路转发给已配对
/// 主机（主机用它自己的 Anki 后端 + 字段映射/牌组落卡），其余**配置类**方法
/// （[fetchConfiguration]/[createDeck]/[createNoteType]）委派给包装的本地仓库 [_local]，
/// 以便设置页在开关开启时仍能正常配置本地 Anki（供开关关闭时使用）。
///
/// 覆盖/查看类方法（[updateMinedNote]/[findOverwriteTargetNoteId]/[findMatchingNotes]/
/// [noteFields]/[openNoteInAnki]）保留基类降级默认（不委派本地——那会在远端制卡时错误地
/// 操作**本机** Anki 的卡片；远端 note id 本就为 null，本会话覆写第三态不激活，与 AnkiDroid
/// 现状一致）。
///
/// 媒体的四个来源在客户端就地读成字节再随请求发出（服务端未必装同款词典/无法访问本机文件）：
/// 封面 ← `context.coverPath`；句子音频 ← `context.sasayakiAudioPath`；单词音频 ←
/// `fields['audio']`（仅本地文件搬字节，`http` URL 留给服务端下载）；词典外字 ←
/// `HoshiDicts.getMediaFile`。
class RemoteMiningAnkiRepository extends BaseAnkiRepository {
  RemoteMiningAnkiRepository({
    required BaseAnkiRepository local,
    required RemoteMineSender client,
    DictMediaByteLoader? dictMediaLoader,
    LocalFileByteLoader? fileByteLoader,
  })  : _local = local,
        _client = client,
        _dictMediaLoader = dictMediaLoader ?? _defaultDictMediaLoader,
        _fileByteLoader = fileByteLoader ?? _defaultFileByteLoader;

  final BaseAnkiRepository _local;
  final RemoteMineSender _client;
  final DictMediaByteLoader _dictMediaLoader;
  final LocalFileByteLoader _fileByteLoader;

  static Uint8List? _defaultDictMediaLoader(String dictionary, String path) =>
      HoshiDicts.instance.getMediaFile(dictionary, path);

  static Future<Uint8List?> _defaultFileByteLoader(String path) async {
    final File file = File(path);
    if (!file.existsSync()) return null;
    try {
      return await file.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    final ForwardedMinePayload payload = await _buildForwardedPayload(
      rawPayloadJson: rawPayloadJson,
      context: context,
    );
    try {
      final Map<String, dynamic>? json = await _client.mineForward(payload);
      return _outcomeFromResponse(json);
    } on SyncAuthError {
      return MineOutcome.failure(
        'The paired device rejected the interconnect token. Re-pair the device.',
        errorCode: AnkiErrorCode.connectionUnknown,
      );
    } catch (e, st) {
      return MineOutcome.failure(
        'Failed to forward the card to the paired device: $e',
        errorCode: AnkiErrorCode.connectionUnknown,
        error: e,
        stackTrace: st,
      );
    }
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) {
    // fail-soft：客户端已在 client 层吞异常回 false，绝不让远端查重阻断查词。
    return _client.isDuplicate(expression: expression, reading: reading);
  }

  Future<ForwardedMinePayload> _buildForwardedPayload({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    // 封面 + 句子音频：context 里是本地文件路径，读成字节。
    final Uint8List? coverBytes = await _readPath(context.coverPath);
    final Uint8List? sentenceAudioBytes =
        await _readPath(context.sasayakiAudioPath);

    // 单词音频 + 词典外字：从 rawPayloadJson 解析。解析失败不致命——仍转发文本卡。
    Uint8List? wordAudioBytes;
    String? wordAudioExt;
    List<ForwardedDictMedia> dictMedia = const <ForwardedDictMedia>[];
    try {
      final AnkiMiningPayload parsed = AnkiMiningPayload.fromJson(
          jsonDecode(rawPayloadJson) as Map<String, dynamic>);
      final AnkiAudioRefKind audioKind = AnkiAudioRef.classify(parsed.audio);
      if (audioKind == AnkiAudioRefKind.localFile) {
        final String localPath = AnkiAudioRef.localPath(parsed.audio);
        wordAudioBytes = await _readPath(localPath);
        wordAudioExt = _extOf(localPath);
      } else if (audioKind == AnkiAudioRefKind.dataUri) {
        // BUG-1050：`data:` 内联单词发音（本地音频库命中）——解码成字节转发给主机，
        // 否则互联「制卡到服务端」丢单词音频（与本地落卡同一根因）。
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
      bookTitleTag: context.bookTitleTag,
      coverBytes: coverBytes,
      coverExt: _extOf(context.coverPath),
      sentenceAudioBytes: sentenceAudioBytes,
      sentenceAudioExt: _extOf(context.sasayakiAudioPath),
      wordAudioBytes: wordAudioBytes,
      wordAudioExt: wordAudioExt,
      dictionaryMedia: dictMedia,
    );
  }

  List<ForwardedDictMedia> _collectDictionaryMedia(
      List<DictionaryMedia> media) {
    final List<ForwardedDictMedia> out = <ForwardedDictMedia>[];
    for (final DictionaryMedia m in media) {
      if (m.dictionary.isEmpty || m.path.isEmpty) continue;
      final Uint8List? bytes = _dictMediaLoader(m.dictionary, m.path);
      if (bytes == null || bytes.isEmpty) continue;
      out.add(ForwardedDictMedia(
          dictionary: m.dictionary, path: m.path, bytes: bytes));
    }
    return out;
  }

  Future<Uint8List?> _readPath(String? path) async {
    if (path == null || path.isEmpty) return null;
    return _fileByteLoader(path);
  }

  static String? _extOf(String? path) {
    if (path == null || path.isEmpty) return null;
    final String base = path.split(RegExp(r'[/\\]')).last;
    final int dot = base.lastIndexOf('.');
    if (dot < 0 || dot == base.length - 1) return null;
    return base.substring(dot + 1);
  }

  MineOutcome _outcomeFromResponse(Map<String, dynamic>? json) {
    if (json == null) {
      return MineOutcome.failure(
        'No paired device is reachable for server-side mining.',
        errorCode: AnkiErrorCode.connectionUnknown,
      );
    }
    final String result = json['result']?.toString() ?? MineResult.error.name;
    final String? message = json['message'] as String?;
    final String? detail = json['detail'] as String?;
    if (result == MineResult.success.name) {
      return MineOutcome.success(audioWarning: message);
    }
    if (result == MineResult.duplicate.name) {
      return const MineOutcome.duplicate();
    }
    if (result == MineResult.notConfigured.name) {
      return const MineOutcome.notConfigured();
    }
    return MineOutcome.failure(
      message ?? detail ?? 'The paired device failed to create the card.',
    );
  }

  // ---- 配置类：委派本地仓库，保持设置页可配置本地 Anki ----

  @override
  Future<AnkiFetchResult> fetchConfiguration() => _local.fetchConfiguration();

  @override
  Future<bool> createDeck(String name) => _local.createDeck(name);

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      _local.createNoteType(template);
}
