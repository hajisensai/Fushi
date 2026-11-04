/// 收集一集视频身边的字幕证据（spec §2）：外挂文字字幕、内嵌文字轨、内嵌图形轨 OCR。
///
/// - 排除本管线自己的产物（[SubtitleEvidenceLoadRequest.isOwnOutput]）。
/// - 外挂文件不保证与这份视频同步（别的压制版本、带片头的 BD 版、文件名配错集…）：
///   把识别稿的开始时刻当参考轨，交上游 `decideSubtitleSync` 判偏移（不在本仓写对齐
///   算法）。**只有判 `autoApply` 的外挂轨才收**（按对齐结果改写时间）；判
///   `needsConfirmation` / `refused`、参考行数不够没法判、或字幕本身读不出可对齐的行，
///   一律丢掉——证据的下游（缺口补齐、校对的同时段原文、歌词段检测）全按时间取行，
///   时间轴不可信的轨会把别处的台词确定性地插进字幕稿。内嵌轨与视频同容器，本来就同步。
/// - 图形轨的 OCR 由宿主注入（[SubtitleGraphicTrackRecognizer]）：引擎没有 OCR 推理，
///   无头服务端不注入 = 跳过图形轨。只识别标成目标语言或没标语言的图形轨（OCR 模型
///   只认日文）。
/// - 任何单个来源读不了只记诊断日志并跳过：证据只能让字幕更好，不能让生成失败。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_asr_subtitles/asr_subtitles.dart'
    show
        SubtitleReferenceTrack,
        SubtitleRetimeOutcome,
        SubtitleSyncDecisionKind,
        kMinReferenceCues,
        uniqueCueStarts;
import 'package:fushi_audio/fushi_audio_core.dart' show readTextWithEncoding;
import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_ass_style_transfer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart'
    show
        isNetworkMediaPath,
        syncSubtitleBytesToReferences,
        referenceTrackLabel,
        EmbeddedReferenceSyncResult;
import 'package:fushi_engine/media/video/subtitle/subtitle_language_preference.dart'
    show normalizeSubtitleLanguageCode;
import 'package:fushi_engine/media/video/video_member_file.dart';
import 'package:fushi_engine/media/video/video_sidecar.dart'
    show listSidecarSubtitles;
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:path/path.dart' as p;

/// 宿主注入的图形轨 OCR：把 [track]（图形字幕轨）整轨识别成文字行；不支持 / 失败 → null。
typedef SubtitleGraphicTrackRecognizer =
    Future<List<SubtitleEvidenceCue>?> Function({
      required String videoPath,
      required EmbeddedSubtitleTrack track,
      required SubtitleCancelToken cancel,
    });

/// 一次收集的输入。
class SubtitleEvidenceLoadRequest {
  const SubtitleEvidenceLoadRequest({
    required this.videoPath,
    required this.drafts,
    required this.isOwnOutput,
    required this.targetLanguage,
    this.cancel = const SubtitleNeverCancel(),
  });

  final String videoPath;

  /// 识别稿：外挂字幕对时间轴的参考。
  final List<SubtitleDraftCue> drafts;
  final bool Function(String path) isOwnOutput;

  /// 管线的目标语言（字幕后缀，通常 `ja`）。
  final String targetLanguage;
  final SubtitleCancelToken cancel;
}

/// 管线的证据注入点。
abstract interface class SubtitleEvidenceSource {
  /// 本集证据来源的身份（不读内容）：变了 `evidence.json` 就要重收。
  Future<String> sourceKey(
    String videoPath, {
    required bool Function(String path) isOwnOutput,
  });

  /// 收集本集的证据轨。
  Future<List<SubtitleEvidenceTrack>> load(SubtitleEvidenceLoadRequest request);
}

/// 一个证据来源的身份（缓存键用）：路径 + 字节数 + 修改时间（内嵌轨用视频本身）。
class SubtitleEvidenceSourceStamp {
  const SubtitleEvidenceSourceStamp(this.path, this.bytes, this.modifiedMs);

  final String path;
  final int bytes;
  final int modifiedMs;

  @override
  String toString() => '$path|$bytes|$modifiedMs';
}

/// 生产实现。
class SubtitleEvidenceCollector implements SubtitleEvidenceSource {
  const SubtitleEvidenceCollector({
    this.graphicRecognizer,
    this.extraSubtitleFiles,
  });

  final SubtitleGraphicTrackRecognizer? graphicRecognizer;

  /// 宿主登记过、但不在视频旁的字幕文件（app 文档目录里的手动导入 / 在线下载 /
  /// 播放时图形字幕 OCR 出的 SRT）。按外挂文件同一套规矩处理（对时间轴、判语言）。
  final Future<List<String>> Function(String videoPath)? extraSubtitleFiles;

  /// 外挂 + 宿主登记的字幕文件（去重，保持顺序）。
  Future<List<String>> _subtitleFiles(String videoPath) async {
    final List<String> out = <String>[...await sidecarSubtitleFiles(videoPath)];
    final Future<List<String>> Function(String)? extra = extraSubtitleFiles;
    if (extra != null) {
      for (final String path in await extra(videoPath)) {
        if (subtitleFormatForPath(path) == null) continue;
        if (out.any((String o) => p.equals(o, path))) continue;
        if (!File(path).existsSync()) continue;
        out.add(path);
      }
    }
    return out;
  }

  @override
  Future<String> sourceKey(
    String videoPath, {
    required bool Function(String path) isOwnOutput,
  }) async =>
      (await sourceStamps(videoPath, isOwnOutput: isOwnOutput)).join('\n');

  /// 本集证据来源的身份：管线据此判 `evidence.json` 缓存是否还新鲜（不读内容）。
  Future<List<SubtitleEvidenceSourceStamp>> sourceStamps(
    String videoPath, {
    required bool Function(String path) isOwnOutput,
  }) async {
    final List<SubtitleEvidenceSourceStamp> out =
        <SubtitleEvidenceSourceStamp>[];
    for (final String path in await _subtitleFiles(videoPath)) {
      if (isOwnOutput(path)) continue;
      out.add(await _stamp(path));
    }
    if (!isNetworkMediaPath(videoPath) && await hasLocalMediaFile(videoPath)) {
      out.add(await _stamp(videoPath));
    }
    // 宿主有没有 OCR 也影响产物（同一视频装上 OCR 后应重收）。
    if (graphicRecognizer != null) {
      out.add(const SubtitleEvidenceSourceStamp('ocr', 1, 0));
    }
    return out;
  }

  Future<SubtitleEvidenceSourceStamp> _stamp(String path) async {
    try {
      final FileStat stat = await File(path).stat();
      return SubtitleEvidenceSourceStamp(
        path,
        stat.size,
        stat.modified.millisecondsSinceEpoch,
      );
    } on FileSystemException {
      return SubtitleEvidenceSourceStamp(path, 0, 0);
    }
  }

  @override
  Future<List<SubtitleEvidenceTrack>> load(
    SubtitleEvidenceLoadRequest request,
  ) async {
    final List<SubtitleEvidenceTrack> tracks = <SubtitleEvidenceTrack>[];
    final String video = request.videoPath;
    final List<SubtitleReferenceTrack> asrReference = <SubtitleReferenceTrack>[
      SubtitleReferenceTrack(
        label: 'asr',
        starts: uniqueCueStarts(<double>[
          for (final SubtitleDraftCue c in request.drafts) c.startMs / 1000,
        ]),
      ),
    ];

    for (final String path in await _subtitleFiles(video)) {
      throwIfSubtitleCancelled(request.cancel);
      if (request.isOwnOutput(path)) continue;
      try {
        final SubtitleEvidenceTrack? t = await _sidecarTrack(
          path,
          video,
          asrReference,
        );
        if (t != null) tracks.add(t);
      } catch (e) {
        fushiDebugPrint('[SubtitleEvidence] skip sidecar "$path": $e');
      }
    }

    // 内嵌轨要整片 demux：只对本机文件做（同样式参考的规矩）。
    if (!isNetworkMediaPath(video) && await hasLocalMediaFile(video)) {
      try {
        final EmbeddedSubtitleTrackProbeResult probe =
            await probeEmbeddedSubtitleTracks(video);
        for (final EmbeddedSubtitleTrack track in probe.tracks) {
          throwIfSubtitleCancelled(request.cancel);
          final SubtitleEvidenceTrack? t =
              subtitleFormatForCodec(track.codec) != null
              ? await _embeddedTextTrack(video, track)
              : await _embeddedGraphicTrack(video, track, request);
          if (t != null) tracks.add(t);
        }
      } on SubtitlePipelineCancelled {
        rethrow;
      } catch (e) {
        fushiDebugPrint('[SubtitleEvidence] embedded probe failed: $e');
      }
    }
    return <SubtitleEvidenceTrack>[
      for (final SubtitleEvidenceTrack t in tracks)
        if (t.cues.isNotEmpty) t,
    ];
  }

  Future<SubtitleEvidenceTrack?> _sidecarTrack(
    String path,
    String videoPath,
    List<SubtitleReferenceTrack> asrReference,
  ) async {
    final SubtitleFormat? format = subtitleFormatForPath(path);
    if (format == null) return null;
    // 参考太少（短片）判不出可靠偏移：上游要求参考轨至少 kMinReferenceCues 条。
    if (asrReference.first.starts.length < kMinReferenceCues) {
      fushiDebugPrint(
        '[SubtitleEvidence] skip sidecar "$path": too few recognized cues '
        'to verify its timing',
      );
      return null;
    }
    final String original = await readTextWithEncoding(File(path));
    final Uint8List bytes = Uint8List.fromList(utf8.encode(original));
    final EmbeddedReferenceSyncResult sync = await Isolate.run(
      () => syncSubtitleBytesToReferences(
        subtitleBytes: bytes,
        references: asrReference,
      ),
    );
    final SubtitleRetimeOutcome? retime = sync.retime;
    if (sync.kind != SubtitleSyncDecisionKind.autoApply || retime == null) {
      fushiDebugPrint(
        '[SubtitleEvidence] skip sidecar "$path": timing not verified '
        '(${sync.status.name}/${sync.kind.name})',
      );
      return null;
    }
    final List<SubtitleEvidenceCue> cues = await _parse(
      format,
      utf8.decode(retime.bytes, allowMalformed: true),
    );
    final String? tagged = _sidecarLanguageTag(path, videoPath);
    return SubtitleEvidenceTrack(
      label: p.basename(path),
      kind: SubtitleEvidenceKind.text,
      language: resolveSubtitleEvidenceLanguage(
        tagged: tagged,
        detected: _detect(cues),
      ),
      cues: cues,
    );
  }

  Future<SubtitleEvidenceTrack?> _embeddedTextTrack(
    String videoPath,
    EmbeddedSubtitleTrack track,
  ) async {
    final SubtitleFormat format = subtitleFormatForCodec(track.codec)!;
    final File? file = await extractEmbeddedSubtitleTrackFile(
      videoPath: videoPath,
      streamIndex: track.streamIndex,
      codec: track.codec,
    );
    if (file == null) return null;
    final List<SubtitleEvidenceCue> cues = await _parse(
      format,
      await readTextWithEncoding(file),
    );
    return SubtitleEvidenceTrack(
      label: 'embedded ${referenceTrackLabel(track)}',
      kind: SubtitleEvidenceKind.text,
      language: resolveSubtitleEvidenceLanguage(
        tagged: normalizeSubtitleLanguageCode(track.language),
        detected: _detect(cues),
      ),
      cues: cues,
    );
  }

  Future<SubtitleEvidenceTrack?> _embeddedGraphicTrack(
    String videoPath,
    EmbeddedSubtitleTrack track,
    SubtitleEvidenceLoadRequest request,
  ) async {
    final SubtitleGraphicTrackRecognizer? ocr = graphicRecognizer;
    if (ocr == null) return null;
    final String? tagged = normalizeSubtitleLanguageCode(track.language);
    // OCR 模型只认日文：标了别的语言的图形轨不识别。
    if (tagged != null &&
        !sameSubtitleLanguage(tagged, request.targetLanguage)) {
      return null;
    }
    final List<SubtitleEvidenceCue>? cues = await ocr(
      videoPath: videoPath,
      track: track,
      cancel: request.cancel,
    );
    if (cues == null || cues.isEmpty) return null;
    return SubtitleEvidenceTrack(
      label: 'embedded ${referenceTrackLabel(track)} OCR',
      kind: SubtitleEvidenceKind.ocr,
      language: resolveSubtitleEvidenceLanguage(
        tagged: tagged,
        detected: _detect(cues),
      ),
      cues: cues,
    );
  }

  static String? _detect(List<SubtitleEvidenceCue> cues) =>
      detectSubtitleTextLanguage(<String>[
        for (final SubtitleEvidenceCue c in cues)
          if (c.role == SubtitleEvidenceRole.dialogue) c.text,
      ]);
}

/// 视频旁的外挂文字字幕（同名前缀，srt / ass / ssa / vtt）。
Future<List<String>> sidecarSubtitleFiles(String videoPath) async {
  final String dir = p.dirname(videoPath);
  final List<String> names = <String>[];
  try {
    await for (final FileSystemEntity e in Directory(
      dir,
    ).list(followLinks: false)) {
      if (e is File) names.add(p.basename(e.path));
    }
  } on FileSystemException {
    return const <String>[];
  }
  names.sort();
  return <String>[
    for (final String name in listSidecarSubtitles(
      p.basenameWithoutExtension(videoPath),
      names,
    ))
      p.join(dir, name),
  ];
}

/// 外挂文件名里的语言标记：`<视频名>.<标记>.<ext>` 的 `<标记>`，再归一化；`<标记>` 里
/// 多段时（`.ja.asr.srt`、`.zh-Hans.forced.ass`）逐段试。
String? _sidecarLanguageTag(String path, String videoPath) {
  final String base = p.basenameWithoutExtension(videoPath);
  final String name = p.basename(path);
  // 宿主登记的文件（app 文档目录里）不按视频名命名：没有可信的语言标记。
  if (name.length <= base.length + 1 ||
      !name.toLowerCase().startsWith(base.toLowerCase())) {
    return null;
  }
  final String middle = p.withoutExtension(name.substring(base.length));
  for (final String part in middle.split('.')) {
    if (part.isEmpty) continue;
    final String? lang = normalizeSubtitleLanguageCode(part);
    if (lang != null) return lang;
  }
  return null;
}

Future<List<SubtitleEvidenceCue>> _parse(
  SubtitleFormat format,
  String content,
) => Isolate.run(() => parseSubtitleEvidenceCues(format, content));

/// 字幕全文 → 证据行（纯函数）。ASS 走样式参考解析（保留样式名判招牌 / 歌词），
/// SRT / VTT 走通用解析器。按开始时间升序。
List<SubtitleEvidenceCue> parseSubtitleEvidenceCues(
  SubtitleFormat format,
  String content,
) {
  final List<SubtitleEvidenceCue> cues = switch (format) {
    SubtitleFormat.ass => switch (parseAssStyleReference(
      content,
      label: 'evidence',
      minEvents: 1,
    )) {
      final AssStyleReference ref => evidenceCuesFromAss(ref),
      null => <SubtitleEvidenceCue>[],
    },
    _ => <SubtitleEvidenceCue>[
      for (final c in parseSubtitleContent(
        format,
        content: content,
        bookUid: 'evidence',
      ))
        if (c.text.trim().isNotEmpty && c.endMs > c.startMs)
          SubtitleEvidenceCue(
            startMs: c.startMs,
            endMs: c.endMs,
            text: c.text.trim(),
            role: classifyPlainEvidenceText(c.text),
          ),
    ],
  };
  cues.sort(
    (SubtitleEvidenceCue a, SubtitleEvidenceCue b) =>
        a.startMs.compareTo(b.startMs),
  );
  return cues;
}
