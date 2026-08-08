import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:fushi/creator.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart'
    show LocalAudioUnavailableError;
import 'package:fushi/src/utils/misc/lookup_audio_playback.dart'
    show kLocalAudioQueryBudget, resolveLookupAudioUrl;
import 'package:fushi/utils.dart';

/// BUG-1005：把 [resolveLookupAudioUrl] 解析出的单词音频 ref 物化成本地 [File] 供 Anki 落
/// 媒体。ref 可能是远端 `http(s)://` URL（forvo/jpod101/fushiRemote 等远程发音源）或本地
/// 文件路径（本地音频库命中）：前者下载到 [dir] 临时文件（扩展名按 URL/Content-Type 推断，
/// 默认 mp3——单词音频主流格式），后者存在即直接包 [File]。失败 / 非 2xx / 空体返回 null。
/// [client] 仅供测试注入（默认自建、用完关闭）。纯逻辑无全局依赖，可单测。
@visibleForTesting
Future<File?> materializeWordAudioRef(
  String ref, {
  required Directory dir,
  http.Client? client,
}) async {
  if (ref.isEmpty) return null;
  if (!ref.startsWith('http')) {
    final String path =
        ref.startsWith('file://') ? Uri.parse(ref).toFilePath() : ref;
    final File f = File(path);
    return f.existsSync() ? f : null;
  }
  final http.Client c = client ?? http.Client();
  try {
    final Uri uri = Uri.parse(ref);
    final http.Response res = await c.get(uri);
    if (res.statusCode < 200 || res.statusCode >= 300) return null;
    if (res.bodyBytes.isEmpty) return null;
    final String ext = wordAudioExtFor(uri, res.headers['content-type']);
    await dir.create(recursive: true);
    final File out = File('${dir.path}/word_audio_remote.$ext');
    await out.writeAsBytes(res.bodyBytes, flush: true);
    return out;
  } catch (_) {
    return null;
  } finally {
    if (client == null) c.close();
  }
}

/// 单词音频物化文件的扩展名：优先按 [uri] 路径末段的已知音频后缀，其次按 [contentType]，
/// 都不认时回退 `mp3`（单词音频主流格式）。纯函数，便于单测。
@visibleForTesting
String wordAudioExtFor(Uri uri, String? contentType) {
  const Set<String> known = <String>{
    'mp3',
    'opus',
    'ogg',
    'oga',
    'm4a',
    'aac',
    'wav',
    'flac',
    'webm',
  };
  final String last = uri.pathSegments.isEmpty ? '' : uri.pathSegments.last;
  final int dot = last.lastIndexOf('.');
  if (dot >= 0 && dot < last.length - 1) {
    final String ext = last.substring(dot + 1).toLowerCase();
    if (known.contains(ext)) return ext;
  }
  final String ct = (contentType ?? '').toLowerCase();
  if (ct.contains('mpeg') || ct.contains('mp3')) return 'mp3';
  if (ct.contains('opus')) return 'opus';
  if (ct.contains('ogg')) return 'ogg';
  if (ct.contains('mp4') || ct.contains('m4a') || ct.contains('aac')) {
    return 'm4a';
  }
  if (ct.contains('wav')) return 'wav';
  if (ct.contains('flac')) return 'flac';
  if (ct.contains('webm')) return 'webm';
  return 'mp3';
}

/// Fetches term audio from local Yomitan audio DB, online sources, or TTS.
class LocalAudioEnhancement extends AudioEnhancement {
  LocalAudioEnhancement({required super.field})
      : super(
          uniqueKey: key,
          label: 'Local Audio',
          description:
              'Fetch audio from the local database, online sources, or TTS.',
          icon: Icons.audio_file_outlined,
        );

  static const String key = 'local_audio';

  @override
  String getLocalisedLabel(AppModel appModel) =>
      t.creator_enhancement_local_audio;

  @override
  Future<void> enhanceCreatorParams({
    required BuildContext context,
    required WidgetRef ref,
    required AppModel appModel,
    required CreatorModel creatorModel,
    required EnhancementTriggerCause cause,
  }) async {
    final audioField = field as AudioExportField;

    String term =
        creatorModel.getFieldController(TermField.instance).text.trim();
    String reading =
        creatorModel.getFieldController(ReadingField.instance).text.trim();

    if (term.isEmpty) return;

    await audioField.setAudio(
      cause: cause,
      appModel: appModel,
      creatorModel: creatorModel,
      newAutoCannotOverride: true,
      searchTerm: term,
      generateAudio: () => _generateAudio(appModel, term, reading),
    );
  }

  /// 本地音频库这次没应答（撞锁 / 查询预算耗尽）时记一条用户可见的错误日志
  /// （设置 → 诊断 → 错误日志），而不是静默把它当成「这个词没有发音」。
  static void _logLocalAudioSkipped(
    String term,
    Object error,
    StackTrace stack,
  ) {
    ErrorLogService.instance.log(
      'LocalAudioEnhancement 本地音频库未能应答（$term）：'
      '本次落远端音源 / TTS 兜底，这不代表库里没有这个词的发音',
      error,
      stack,
    );
  }

  Future<File?> _generateAudio(
      AppModel appModel, String term, String reading) async {
    // 1. Local audio database (Yomitan SQLite): query metadata, then extract
    //    the blob. Native handler on Android; pure-Dart sqlite3 on desktop —
    //    both behind TtsChannel, so this call site is platform-agnostic.
    // 删了 master 总开关后无条件先查本地音频库（Yomitan SQLite）；native 只持有
    // 已启用的库，无启用库时返回空，行为与之前一致。
    try {
      final info = await TtsChannel.instance
          .queryLocalAudio(term, reading)
          .timeout(kLocalAudioQueryBudget);
      if (info != null) {
        final int dbIndex = (info['dbIndex'] as int?) ?? 0;
        final path = await TtsChannel.instance.extractLocalAudio(
          info['file']! as String,
          info['source']! as String,
          dbIndex: dbIndex,
        );
        if (path != null && path.isNotEmpty) {
          final file = File(path);
          if (file.existsSync()) return file;
        }
      }
    } on TimeoutException catch (e, stack) {
      // BUG-1413：预算耗尽＝本地库**没答上**，不是「这个词没有发音」。仍旧落到
      // step 2 / step 3 兜底（行为不变），但必须留痕：旧实现这里是整条制卡链上
      // 最静默的一处——音频字段空且无任何提示，用户与开发者都看不出库当时在忙。
      _logLocalAudioSkipped(term, e, stack);
    } on LocalAudioUnavailableError catch (e, stack) {
      // 库明确报了撞锁（BUG-1413）：同样只是这次没取到，继续兜底而不是崩制卡。
      _logLocalAudioSkipped(term, e, stack);
    }

    // 2. BUG-1005：配置的音频源（含**远程发音源** forvo/jpod101/fushiRemote）——与查词
    //    **播放**路径统一走 resolveLookupAudioUrl（尊重用户源顺序/开关，单一真相）。这是
    //    BUG-631「播放侧已修、制卡器侧仍 local-only」的孪生修复：制卡自动填充此前只查本地
    //    库(step 1)+TTS(step 3)、**完全忽略远程发音源**，只配了远程源的用户（多数日语学习者）
    //    制卡恒无单词音频。解析出 ref（远端 URL 或本地路径）后物化成本地文件供 Anki 落媒体；
    //    失败落到 TTS 兜底。
    try {
      final String? ref = await resolveLookupAudioUrl(appModel, term, reading);
      if (ref != null && ref.isNotEmpty) {
        final Directory remoteDir = await getApplicationSupportDirectory();
        final File? materialized =
            await materializeWordAudioRef(ref, dir: remoteDir);
        if (materialized != null) return materialized;
      }
    } catch (_) {
      // best-effort：解析/下载失败不阻断，落到 TTS 兜底。
    }

    // 3. TTS to file
    final dir = await getApplicationSupportDirectory();
    final outPath = '${dir.path}/tts_term_audio.wav';
    final word = reading.isNotEmpty ? reading : term;
    final result = await TtsChannel.instance.ttsToFile(word, outPath);
    if (result != null) {
      final file = File(result);
      if (file.existsSync()) return file;
    }

    return null;
  }

  @override
  Future<File?> fetchAudio({
    required AppModel appModel,
    required BuildContext context,
    required String term,
    required String reading,
  }) async {
    return _generateAudio(appModel, term, reading);
  }
}
