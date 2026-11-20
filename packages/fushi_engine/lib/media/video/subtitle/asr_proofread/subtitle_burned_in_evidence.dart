/// 烧录字幕（硬字幕）OCR 证据（拍板台 `d-fO4eGxKx`）：画面里压着日文字幕的视频，
/// 在识别稿每行的时刻截一帧、读出画面下方的字幕，作为一条 `ocr` 证据轨交给管线。
///
/// 动机是制卡：视频卡的例句就是字幕行，语音识别的同音字错误（「島」/「堂」）会原样
/// 进卡片；画面上的硬字幕是片方排好的正确写法。
///
/// - 只对本机视频文件做（取帧走 [SubtitleFrameSource]，网络流取不到帧），按原分辨率
///   取帧（小字缩了会读错字）。
/// - **先探测再整集**：均匀抽 [kSubtitleBurnedInProbeFrames] 行试读，至少
///   [kSubtitleBurnedInProbeMinHits] 帧读到「目标语言、且与识别稿字面相近」的字幕才
///   整集读；没有硬字幕 / 硬字幕是别的语言（中文字幕组压制）的视频只花这几帧。
/// - 文字识别由宿主注入（[SubtitleFrameTextReader]）：引擎没有 OCR 推理，无头服务端
///   不注入 = 不读硬字幕。
/// - 证据只能让字幕更好，不能让生成失败：单帧取不到 / 读不出就少一行；但多数帧读取
///   本身失败（OCR 会话起不来、ffmpeg 暂时不可用）时抛 [SubtitleBurnedInReadFailed]，
///   收集方据此不缓存，下次重读——不把「读失败」记成「没有硬字幕」。
/// - 与识别行写法不同的行再读一帧确认，两次不一致的不收。
///
/// 读出的轨怎么用：S3 校对把它当同语言证据（「同语言字幕与台词吻合时优先采用其写
/// 法」）；不开 AI 时由 `correctSubtitleDraftsFromOcrEvidence` 确定性地换掉字面相近
/// 的识别行（`subtitle_evidence_fusion.dart`）。
library;

import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show fushiDebugPrint;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_evidence.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_frame_reference.dart'
    show SubtitleFrameSource;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_song_lyrics.dart'
    show lyricsBigramDice;

/// 探测时试读几帧。
const int kSubtitleBurnedInProbeFrames = 12;

/// 探测里至少几帧对得上才算有硬字幕（试读帧不足这个数时要求全部对上）。
const int kSubtitleBurnedInProbeMinHits = 3;

/// 探测里一帧算「对得上」的字面相似度下限（字符二元组 Dice）：同一句台词即使有同音
/// 字错误也远高于它，不同的句子几乎都低于它。
const double kSubtitleBurnedInProbeMinSimilarity = 0.3;

/// 字幕带的上沿（占画面高的比例）：行的竖直中心在它之下才算字幕。宿主可以只把这一
/// 带交给 OCR（省时间）。
const double kSubtitleBurnedInBandTop = 0.6;

/// 字幕行的水平中心离画面中线最多偏多少（占画面宽的比例）：台词字幕居中排，偏到
/// 角落的是台标 / 时间 / 招牌。
const double kSubtitleBurnedInMaxCenterOffset = 0.2;

/// 证据轨的标签（给提示词与日志看）。
const String kSubtitleBurnedInTrackLabel = 'burned-in subtitles OCR';

/// 画面上读出的一行文字，坐标按整帧宽高归一化到 0~1。
class SubtitleFrameTextLine {
  const SubtitleFrameTextLine({
    required this.text,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });

  final String text;
  final double left;
  final double top;
  final double right;
  final double bottom;
}

/// 宿主注入的画面文字识别。
abstract interface class SubtitleFrameTextReader {
  /// 识别器身份（模型键等，进证据缓存键）；null = 现在读不了（模型没下载 / 平台不
  /// 支持），这次不读硬字幕。
  Future<String?> identity();

  /// 读一帧（[SubtitleFrameSource] 给的 JPEG）里的文字行。读不了时抛错。
  Future<List<SubtitleFrameTextLine>> read(Uint8List frame);
}

/// **纯函数**：一帧的文字行里挑出台词字幕，按从上到下拼成一句（日文换行不加空格）；
/// 没有字幕返回空串。
String burnedInSubtitleText(List<SubtitleFrameTextLine> lines) {
  final List<SubtitleFrameTextLine> picked =
      <SubtitleFrameTextLine>[
        for (final SubtitleFrameTextLine l in lines)
          if (l.text.trim().isNotEmpty &&
              l.bottom > l.top &&
              l.right > l.left &&
              (l.top + l.bottom) / 2 >= kSubtitleBurnedInBandTop &&
              ((l.left + l.right) / 2 - 0.5).abs() <=
                  kSubtitleBurnedInMaxCenterOffset)
            l,
      ]..sort(
        (SubtitleFrameTextLine a, SubtitleFrameTextLine b) =>
            a.top.compareTo(b.top),
      );
  return picked.map((SubtitleFrameTextLine l) => l.text.trim()).join();
}

/// **纯函数**：探测读哪几行（[drafts] 的下标，升序）：有字的行里均匀取至多 [count] 行。
List<int> planBurnedInProbe(
  List<SubtitleDraftCue> drafts, {
  int count = kSubtitleBurnedInProbeFrames,
}) {
  final List<int> spoken = <int>[
    for (int i = 0; i < drafts.length; i++)
      if (drafts[i].text.trim().isNotEmpty) i,
  ];
  if (spoken.length <= count) return spoken;
  if (count <= 0) return const <int>[];
  if (count == 1) return <int>[spoken[spoken.length ~/ 2]];
  final List<int> out = <int>[];
  for (int k = 0; k < count; k++) {
    final int i = spoken[(k * (spoken.length - 1) / (count - 1)).round()];
    if (out.isEmpty || out.last != i) out.add(i);
  }
  return out;
}

/// **纯函数**：探测结果够不够判「有目标语言的硬字幕」。[pairs] 是试读的
/// （画面字幕, 识别行）。
///
/// - 与识别行字面相近（Dice ≥ [kSubtitleBurnedInProbeMinSimilarity]）的帧至少
///   [kSubtitleBurnedInProbeMinHits] 帧（试读不足这个数时要求全部对上）；
/// - 这些帧的字合起来判得出语言时必须是 [targetLanguage]（单句太短判不出，合起来判）。
bool burnedInProbeAccepts(
  List<(String ocr, String draft)> pairs, {
  required String targetLanguage,
}) {
  if (pairs.isEmpty) return false;
  final List<String> hits = <String>[
    for (final (String ocr, String draft) in pairs)
      if (ocr.trim().isNotEmpty &&
          lyricsBigramDice(ocr, draft) >= kSubtitleBurnedInProbeMinSimilarity)
        ocr,
  ];
  final int need = pairs.length < kSubtitleBurnedInProbeMinHits
      ? pairs.length
      : kSubtitleBurnedInProbeMinHits;
  if (hits.length < need) return false;
  final String? language = detectSubtitleTextLanguage(hits);
  return language == null || sameSubtitleLanguage(language, targetLanguage);
}

/// 读硬字幕本身失败（取帧 / OCR 抛错占了多数帧，不是「读到了但不是日文硬字幕」）：结果
/// 不可信，收集方不得把它当「没有硬字幕」缓存下来，下次要重读。
class SubtitleBurnedInReadFailed implements Exception {
  const SubtitleBurnedInReadFailed(this.failed, this.total);

  final int failed;
  final int total;

  @override
  String toString() =>
      'SubtitleBurnedInReadFailed: $failed of $total frames failed to read';
}

/// 多数帧读取失败（[failed] / [total]）就不算数。
bool _mostlyFailed(int failed, int total) =>
    total > 0 && failed > 0 && failed * 2 >= total;

/// 读硬字幕：探测 → 整集 → 证据轨。
class SubtitleBurnedInReader {
  const SubtitleBurnedInReader({required this.frames, required this.reader});

  /// 取帧（生产 `ffmpegSubtitleFullFrameSource`：原分辨率，不缩——画面参考那路缩到
  /// 768 宽，字幕只剩二十来像素高，OCR 会把「島」读成「鳥」）。
  final SubtitleFrameSource frames;
  final SubtitleFrameTextReader reader;

  /// 缓存键里的身份；null = 这次不读。
  Future<String?> identity() async {
    try {
      final String? id = await reader.identity();
      return id == null ? null : 'burned-in:$id';
    } catch (error) {
      fushiDebugPrint('[SubtitleBurnedIn] identity failed: $error');
      return null;
    }
  }

  /// 读 [videoPath] 在 [drafts] 各行时刻的硬字幕。没有可用的硬字幕返回 null；多数帧
  /// 读取本身失败时抛 [SubtitleBurnedInReadFailed]（别当「没有」缓存）。
  /// [onProgress] 报整集读到第几行（探测阶段不报）。
  ///
  /// 与识别行写法不同的画面字幕（纠错的候选）在同一行的另一时刻再读一帧，两次读出的
  /// 字不一样就不收这一行：单帧 OCR 的偶发误读不会被当成「正确写法」。
  Future<SubtitleEvidenceTrack?> read({
    required String videoPath,
    required List<SubtitleDraftCue> drafts,
    required String targetLanguage,
    SubtitleCancelToken cancel = const SubtitleNeverCancel(),
    void Function(int done, int total)? onProgress,
  }) async {
    if (await identity() == null) return null;
    final Map<int, String> texts = <int, String>{};

    final List<int> probe = planBurnedInProbe(drafts);
    if (probe.isEmpty) return null;
    int probeFailed = 0;
    for (final int i in probe) {
      throwIfSubtitleCancelled(cancel);
      final String? text = await _readAt(videoPath, drafts[i], 0.5);
      if (text == null) probeFailed++;
      texts[i] = text ?? '';
    }
    if (!burnedInProbeAccepts(<(String, String)>[
      for (final int i in probe) (texts[i]!, drafts[i].text),
    ], targetLanguage: targetLanguage)) {
      if (_mostlyFailed(probeFailed, probe.length)) {
        throw SubtitleBurnedInReadFailed(probeFailed, probe.length);
      }
      fushiDebugPrint(
        '[SubtitleBurnedIn] $videoPath: no burned-in $targetLanguage '
        'subtitles in ${probe.length} probe frames',
      );
      return null;
    }
    for (final int i in probe) {
      throwIfSubtitleCancelled(cancel);
      texts[i] = await _confirmed(videoPath, drafts[i], texts[i]!);
    }

    final List<int> rest = <int>[
      for (int i = 0; i < drafts.length; i++)
        if (drafts[i].text.trim().isNotEmpty && !texts.containsKey(i)) i,
    ];
    final int total = texts.length + rest.length;
    int done = texts.length;
    int failed = 0;
    onProgress?.call(done, total);
    for (final int i in rest) {
      throwIfSubtitleCancelled(cancel);
      final String? text = await _readAt(videoPath, drafts[i], 0.5);
      if (text == null) failed++;
      texts[i] = text == null
          ? ''
          : await _confirmed(videoPath, drafts[i], text);
      done++;
      onProgress?.call(done, total);
    }
    if (_mostlyFailed(failed, rest.length)) {
      throw SubtitleBurnedInReadFailed(failed, rest.length);
    }

    final List<SubtitleEvidenceCue> cues = <SubtitleEvidenceCue>[
      for (int i = 0; i < drafts.length; i++)
        if (texts[i] case final String text when text.isNotEmpty)
          SubtitleEvidenceCue(
            startMs: drafts[i].startMs,
            endMs: drafts[i].endMs,
            text: text,
            role: classifyPlainEvidenceText(text),
          ),
    ];
    if (cues.isEmpty) return null;
    return SubtitleEvidenceTrack(
      label: kSubtitleBurnedInTrackLabel,
      kind: SubtitleEvidenceKind.ocr,
      language: resolveSubtitleEvidenceLanguage(
        tagged: null,
        detected: detectSubtitleTextLanguage(<String>[
          for (final SubtitleEvidenceCue c in cues)
            if (c.role == SubtitleEvidenceRole.dialogue) c.text,
        ]),
      ),
      cues: cues,
    );
  }

  /// [text] 的字与识别行一样（或为空）原样返回；不一样就在行的 3/4 处再读一帧，两次
  /// 的字一致才留，否则返回空串（这一行不当证据）。
  Future<String> _confirmed(
    String videoPath,
    SubtitleDraftCue cue,
    String text,
  ) async {
    final String key = subtitleSpellingKey(text);
    if (key.isEmpty || key == subtitleSpellingKey(cue.text)) return text;
    final String? again = await _readAt(videoPath, cue, 0.75);
    return again != null && subtitleSpellingKey(again) == key ? text : '';
  }

  /// 行内 [at]（0~1，占行时长的比例）那一帧的字幕；这一刻没有帧 / 没有字幕返回空串，
  /// 取帧或 OCR 抛错返回 null（读取失败，与「没有」区分）。
  Future<String?> _readAt(
    String videoPath,
    SubtitleDraftCue cue,
    double at,
  ) async {
    final int span = cue.endMs > cue.startMs ? cue.endMs - cue.startMs : 0;
    final int atMs = cue.startMs + (span * at).round();
    try {
      final Uint8List? frame = await frames(videoPath, atMs);
      if (frame == null || frame.isEmpty) return '';
      return burnedInSubtitleText(await reader.read(frame));
    } on SubtitlePipelineCancelled {
      rethrow;
    } catch (error) {
      fushiDebugPrint('[SubtitleBurnedIn] $videoPath @$atMs ms: $error');
      return null;
    }
  }
}
