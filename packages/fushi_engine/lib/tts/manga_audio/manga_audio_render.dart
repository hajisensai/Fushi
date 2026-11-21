/// 漫画有声成品的清单（生成端写、播放端读的唯一契约）。
///
/// 成品 = 每句一段音频文件 + 本清单。静音不烘焙进音频（设计 §2）：页停留、`lead`、
/// 句间停顿都由播放器按 [MangaRenderManifest.timeline] 插入，所以同一份音频既能边看边
/// 听、也能纯听。没配上音的句子（见 `cast_line_voicing.dart`）也有一个文件——一段按字数
/// 估长度的静音，`placeholder: true`；补回时只换这一句的文件和时长，播放端照常读。
///
/// 入库形态（播放走 `AudiobookSession`）：
/// - `Audiobooks.alignmentFormat` = [kMangaAlignmentFormat]，`alignmentPath` = 本清单
///   的路径，`audioPathsJson` = [MangaRenderManifest.audioFiles]（按行顺序）；
/// - 每个会发声的行一条 `AudioCues`：`chapterHref` = [mangaPageHref]，
///   `textFragmentId` = [mangaBlocksFragment]，`startMs = 0`、`endMs = 时长`、
///   `audioFileIndex` = 行在 [MangaRenderManifest.lines] 里的下标，`sentenceIndex` 同。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_timeline.dart';

/// `Audiobooks.alignmentFormat` 的漫画取值。
const String kMangaAlignmentFormat = 'manga_script';

/// cue 的 `chapterHref`：页（0 起），与 PDF 的 `pdf-page-N` 同构。
String mangaPageHref(int page) => 'manga-page-$page';

/// [mangaPageHref] 的反解；不是漫画页返回 null。
int? parseMangaPageHref(String href) {
  final RegExpMatch? m = RegExp(r'^manga-page-(\d+)$').firstMatch(href);
  return m == null ? null : int.parse(m[1]!);
}

/// cue 的 `textFragmentId`：块下标列表，逗号分隔、保持朗读顺序。
String mangaBlocksFragment(List<int> blocks) => blocks.join(',');

/// [mangaBlocksFragment] 的反解；格式不对返回空列表。
List<int> parseMangaBlocksFragment(String fragment) {
  final List<int> out = <int>[];
  for (final String part in fragment.split(',')) {
    final int? v = int.tryParse(part.trim());
    if (v == null || v < 0) return const <int>[];
    out.add(v);
  }
  return out;
}

/// 清单里的一句。
class MangaRenderedLine {
  const MangaRenderedLine({
    required this.lineId,
    required this.page,
    required this.blocks,
    required this.speaker,
    required this.kind,
    required this.beatMs,
    required this.file,
    required this.durationMs,
    required this.text,
    this.placeholder = false,
    this.voice,
    this.seed,
  });

  /// [MangaScriptLine.lineId]。
  final String lineId;
  final int page;
  final List<int> blocks;
  final String speaker;
  final CastLineKind kind;
  final int beatMs;

  /// 音频文件，相对清单所在目录。
  final String file;

  /// 文件时长（裁过首尾静音）。
  final int durationMs;

  /// 生成时念的文字（cue 文本、制卡用；来自用户自己的 OCR 或手填）。
  final String text;

  /// 占位静音（没配上音）。
  final bool placeholder;

  /// 实际用的声音 id / 种子（重生成与诊断用）。
  final String? voice;
  final int? seed;

  MangaTimedLine get timed => MangaTimedLine(
    page: page,
    speaker: speaker,
    kind: kind,
    durationMs: durationMs,
    beatMs: beatMs,
    placeholder: placeholder,
  );

  MangaRenderedLine replaced({
    required String file,
    required int durationMs,
    required bool placeholder,
    String? voice,
    int? seed,
    String? text,
  }) => MangaRenderedLine(
    lineId: lineId,
    page: page,
    blocks: blocks,
    speaker: speaker,
    kind: kind,
    beatMs: beatMs,
    file: file,
    durationMs: durationMs,
    text: text ?? this.text,
    placeholder: placeholder,
    voice: voice,
    seed: seed,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': lineId,
    'p': page,
    'b': blocks,
    's': speaker,
    'k': kind.wire,
    if (beatMs != 0) 'beat': beatMs,
    'f': file,
    'ms': durationMs,
    't': text,
    if (placeholder) 'ph': true,
    if (voice != null) 'voice': voice,
    if (seed != null) 'seed': seed,
  };

  static MangaRenderedLine? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? page = raw['p'];
    final Object? blocks = raw['b'];
    final Object? speaker = raw['s'];
    final CastLineKind? kind = CastLineKind.parse(raw['k']);
    final Object? file = raw['f'];
    final Object? ms = raw['ms'];
    if (id is! String ||
        page is! int ||
        blocks is! List ||
        speaker is! String ||
        kind == null ||
        !kind.isAudible ||
        file is! String ||
        ms is! int ||
        ms < 0) {
      return null;
    }
    final Object? beat = raw['beat'];
    final Object? text = raw['t'];
    final Object? voice = raw['voice'];
    final Object? seed = raw['seed'];
    return MangaRenderedLine(
      lineId: id,
      page: page,
      blocks: <int>[
        for (final Object? b in blocks)
          if (b is int) b,
      ],
      speaker: speaker,
      kind: kind,
      beatMs: beat is int && beat > 0 ? beat : 0,
      file: file,
      durationMs: ms,
      text: text is String ? text : '',
      placeholder: raw['ph'] == true,
      voice: voice is String ? voice : null,
      seed: seed is int ? seed : null,
    );
  }
}

/// 一卷的成品清单。
class MangaRenderManifest {
  MangaRenderManifest({
    required this.pageCount,
    required this.lines,
    Map<int, MangaPageDirective>? pages,
    this.engineSignature,
    this.continuous = false,
  }) : pages = pages ?? <int, MangaPageDirective>{};

  static const int schemaVersion = 1;

  final int pageCount;

  /// 会发声的行，按阅读顺序。
  final List<MangaRenderedLine> lines;

  /// 生成时的逐页指令快照。
  final Map<int, MangaPageDirective> pages;

  /// 生成时演出稿的 OCR 签名。
  final String? engineSignature;

  /// 连续音轨（广播剧 / 动画音轨，见 `manga_drama_track.dart`）：各段首尾相接就是
  /// 原音频，停顿与翻页节奏都已经在音频里，时间表不再插入页停留、`lead` 与句间停顿
  /// （[MangaTimingParams.continuous]）。逐句合成的成品为 false。
  final bool continuous;

  /// `Audiobooks.audioPathsJson` 的内容（相对清单目录，按行顺序）。
  List<String> get audioFiles => <String>[
    for (final MangaRenderedLine l in lines) l.file,
  ];

  int get placeholderCount =>
      lines.where((MangaRenderedLine l) => l.placeholder).length;

  /// 按播放形态算时间表（与 [lines] 一一对应）。
  MangaTimeline timeline({
    MangaPlaybackMode mode = MangaPlaybackMode.watchAndListen,
    double pacing = 1.0,
    int startPage = 0,
    MangaTimingParams params = const MangaTimingParams(),
  }) {
    final List<MangaTimedLine> timed = <MangaTimedLine>[
      for (final MangaRenderedLine l in lines)
        if (l.page >= startPage) l.timed,
    ];
    return computeMangaTimeline(
      lines: timed,
      pageCount: pageCount,
      startPage: startPage,
      pages: continuous ? const <int, MangaPageDirective>{} : pages,
      mode: mode,
      pacing: pacing,
      params: continuous ? MangaTimingParams.continuous : params,
    );
  }

  /// 补回一句：换文件与时长（不改其余行）；找不到返回 false。
  bool replaceLine(
    String lineId,
    MangaRenderedLine Function(MangaRenderedLine) f,
  ) {
    final int i = lines.indexWhere((MangaRenderedLine l) => l.lineId == lineId);
    if (i < 0) return false;
    lines[i] = f(lines[i]);
    return true;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'v': schemaVersion,
    'pageCount': pageCount,
    if (engineSignature != null) 'ocr': engineSignature,
    if (continuous) 'cont': true,
    'lines': <Object?>[for (final MangaRenderedLine l in lines) l.toJson()],
    'pages': <String, Object?>{
      for (final MapEntry<int, MangaPageDirective> e in pages.entries)
        '${e.key}': e.value.toJson(),
    },
  };

  /// 解析；结构坏（缺页数、行页码越界 / 乱序）返回 null，不认识的行丢弃。
  static MangaRenderManifest? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? count = raw['pageCount'];
    final Object? lines = raw['lines'];
    final Object? pages = raw['pages'];
    final Object? ocr = raw['ocr'];
    if (count is! int || count < 0 || lines is! List) return null;
    final List<MangaRenderedLine> parsed = <MangaRenderedLine>[
      for (final Object? l in lines)
        if (MangaRenderedLine.fromJson(l) case final MangaRenderedLine line)
          line,
    ];
    int prev = 0;
    for (final MangaRenderedLine l in parsed) {
      if (l.page < prev || l.page >= count) return null;
      prev = l.page;
    }
    return MangaRenderManifest(
      pageCount: count,
      lines: parsed,
      engineSignature: ocr is String ? ocr : null,
      continuous: raw['cont'] == true,
      pages: <int, MangaPageDirective>{
        if (pages is Map)
          for (final MapEntry<Object?, Object?> e in pages.entries)
            if (int.tryParse('${e.key}') case final int page)
              page: MangaPageDirective.fromJson(e.value),
      },
    );
  }

  /// 清单文件位置：`<root>/<sha1(bookKey)>/manifest.json`，音频文件放同目录。
  static File fileFor(Directory root, String bookKey) => File(
    p.join(root.path, '${sha1.convert(utf8.encode(bookKey))}', 'manifest.json'),
  );

  static Future<MangaRenderManifest?> load(File f) async {
    if (!await f.exists()) return null;
    try {
      return fromJson(jsonDecode(await f.readAsString()));
    } on FormatException {
      return null;
    }
  }

  Future<void> save(File f) async {
    await f.parent.create(recursive: true);
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(toJson()), flush: true);
    await tmp.rename(f.path);
  }
}
