/// 漫画有声：已有有声书当台词音源的应用层装配（设计 §9）。匹配本身在引擎
/// （`manga_audiobook_match.dart`），这里只负责：
/// - 列出书库里能当音源的书（有 `Audiobooks` 行、不是漫画成品本身）；
/// - 读演出稿 + 本卷 OCR，解析出要匹配的台词；
/// - 读关联书的 cue 语料，能拿到逐 token 时间就挂上（见 [loadCorpus] 的说明）；
/// - 把关联书单写进本卷或整个系列每一卷的演出稿。
///
/// **关联存在演出稿里**（`MangaAudioScript.audiobookSources`，JSON `books`），不另立
/// sidecar：音源策略本来就在演出稿上，片段也写在行上，三者同生同灭、同一次原子写。
/// 「整个系列一起关联」= 把同一份书单写进系列里每一卷的演出稿。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart'
    show attachAsrCueTokenTiming, parseCuesForFormat;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart'
    show kMangaAlignmentFormat;
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show resolveMangaLineText;
import 'package:fushi_engine/tts/manga_audio/manga_audiobook_match.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 能当音源的一本书。
class MangaAudiobookCandidate {
  const MangaAudiobookCandidate({required this.bookKey, required this.title});

  final String bookKey;
  final String title;
}

/// 关联书的 cue 语料（按书单顺序首尾相接）。
class MangaAudiobookCorpus {
  const MangaAudiobookCorpus({
    required this.cues,
    required this.cueCounts,
    required this.withTokenTiming,
  });

  final List<MangaAudiobookCue> cues;

  /// 每本书读到的 cue 数（0 = 这本书没有有声书或还没对齐）。
  final Map<String, int> cueCounts;

  /// 挂上了逐 token 时间的书。
  final Set<String> withTokenTiming;
}

/// 本卷演出稿里会发声的行 → 要匹配的台词（文本按 OCR / 修正 / 手填解析，与合成同一个
/// 函数 [resolveMangaLineText]）。页越界（OCR 页数变了）的行跳过——那种演出稿本来就
/// 会被判「需重新标注」。
List<MangaAudiobookQueryLine> mangaAudiobookQueryLines(
  MangaAudioScript script,
  MokuroPayload payload,
) => <MangaAudiobookQueryLine>[
  for (final MangaScriptLine line in script.audibleLines)
    if (line.page >= 0 && line.page < payload.images.length)
      (
        lineId: line.lineId,
        text: resolveMangaLineText(line, payload.images[line.page].blocks),
      ),
];

/// 把同一份对齐文件重新解析出来、挂上逐 token 时间的 [parsed] 搬到数据库里的
/// [stored] 上——**只在两边一一对应时**（条数相同、每条起止时间相同）。
///
/// 逐 token 时间是 `AudioCue` 的瞬态字段，不落库；它的行号基准是转录产物原始 SRT。
/// 对齐落库时命中的 cue 会按正文句界重切、文本换成正文（`finalizeAlignedCues`），
/// 这之后数据库里的 cue 与原始 SRT 不再一一对应，按下标硬挂会整体错位（错位比没有
/// 更糟，同 `attachAsrCueTokenTiming` 的长度校验），所以对不上就一条都不挂。
bool attachTokenTimingIfAligned(List<AudioCue> stored, List<AudioCue> parsed) {
  if (stored.isEmpty || stored.length != parsed.length) return false;
  for (int i = 0; i < stored.length; i++) {
    if (stored[i].startMs != parsed[i].startMs ||
        stored[i].endMs != parsed[i].endMs ||
        parsed[i].tokenTiming == null) {
      return false;
    }
  }
  for (int i = 0; i < stored.length; i++) {
    stored[i].tokenTiming = parsed[i].tokenTiming;
  }
  return true;
}

/// 后台 isolate 跑匹配（归一化走 FFI，工作 isolate 自己加载原生库）。顶层函数：闭包
/// 只捕获两份纯数据，不会把 `AppModel` 之类带进 isolate 消息。
Future<MangaAudiobookMatchResult> matchMangaAudiobookInBackground(
  List<MangaAudiobookQueryLine> lines,
  List<MangaAudiobookCue> corpus,
) =>
    Isolate.run(() => matchMangaLinesToAudiobook(lines: lines, corpus: corpus));

/// 按 bookKey 与库里的原始标题给出展示名。
typedef MangaBookTitleResolver =
    String Function(String bookKey, String rawTitle);

/// 读写入口（生产用 `AppModel`）。
class MangaAudiobookSourceService {
  MangaAudiobookSourceService(this.appModel, {required this.bookTitle});

  final AudioProductionHost appModel;

  /// 书的展示名（生产用 `display_title.dart` 的 `displayTitleForBook`：带用户改名
  /// 覆盖、去哈希）。注入而不直接 import：那份实现要读书族源，会把本服务拖进
  /// import 大环。
  final MangaBookTitleResolver bookTitle;

  FushiDatabase get _db => appModel.database;

  MangaAudioScriptStore get _scripts => mangaAudioScriptStoreFor(appModel);

  Future<MangaAudioScript> loadScript(String bookKey) => _scripts.load(bookKey);

  Future<void> saveScript(String bookKey, MangaAudioScript script) =>
      _scripts.save(bookKey, script);

  /// 书库里带有声书的书（不含 [mangaBookKey] 自己、不含漫画有声成品）。按显示名排序。
  Future<List<MangaAudiobookCandidate>> candidates(String mangaBookKey) async {
    final Map<String, Audiobook> audiobooks = await AudiobookRepository(
      _db,
    ).buildBookKeyMap();
    final List<MangaAudiobookCandidate> out = <MangaAudiobookCandidate>[];
    for (final MapEntry<String, Audiobook> e in audiobooks.entries) {
      if (e.key == mangaBookKey) continue;
      if (e.value.alignmentFormat == kMangaAlignmentFormat) continue;
      final EpubBookRow? row = await _db.getEpubBook(e.key);
      out.add(
        MangaAudiobookCandidate(
          bookKey: e.key,
          title: row == null ? e.key : bookTitle(row.bookKey, row.title),
        ),
      );
    }
    out.sort(
      (MangaAudiobookCandidate a, MangaAudiobookCandidate b) =>
          a.title.compareTo(b.title),
    );
    return out;
  }

  /// 本卷 OCR（本地卷：`<extractDir>/<epubPath>` 的 `manga.json`）。在线作品按章各一份
  /// `manga.json`、演出稿的页下标没有统一坐标，不支持——返回 null，读不出来也返回 null。
  Future<MokuroPayload?> loadPayload(String bookKey) async {
    final EpubBookRow? row = await _db.getEpubBook(bookKey);
    if (row == null || row.extractDir.isEmpty) return null;
    final File json = File(p.join(row.extractDir, row.epubPath));
    if (!await json.exists()) return null;
    try {
      return parseMangaJson(await json.readAsString());
    } on Object catch (e, stack) {
      // 坏文件：界面显示「本卷还没有可用的 OCR」，不在这里重试或修复。
      ErrorLogService.instance.log(
        'MangaAudiobookSource.loadPayload',
        e,
        stack,
      );
      return null;
    }
  }

  /// 关联书的 cue 语料。数据库里的 cue 不带逐 token 时间（瞬态字段）；若对齐文件是
  /// 转录产物、旁边有 token sidecar，且重新解析出来的 cue 与库里一一对应（见
  /// [attachTokenTimingIfAligned]），就把时间挂上，半句命中才裁得了。对齐过的转录
  /// 产物通常已重切、对不上，这时 [MangaAudiobookCorpus.withTokenTiming] 不含该书，
  /// 统计界面据此说明「半句命中不可用」。
  Future<MangaAudiobookCorpus> loadCorpus(List<String> bookKeys) async {
    final AudiobookRepository repo = AudiobookRepository(_db);
    final List<MangaAudiobookCue> cues = <MangaAudiobookCue>[];
    final Map<String, int> counts = <String, int>{};
    final Set<String> timed = <String>{};
    for (final String key in bookKeys) {
      final List<AudioCue> stored = await repo.cuesForBook(key);
      counts[key] = stored.length;
      if (stored.isEmpty) continue;
      final Audiobook? ab = await repo.findByBookKey(key);
      if (ab != null && await _attachTiming(key, ab, stored)) timed.add(key);
      cues.addAll(stored.map(MangaAudiobookCue.fromAudioCue));
    }
    return MangaAudiobookCorpus(
      cues: cues,
      cueCounts: counts,
      withTokenTiming: timed,
    );
  }

  Future<bool> _attachTiming(
    String bookKey,
    Audiobook ab,
    List<AudioCue> stored,
  ) async {
    final File file = File(ab.alignmentPath);
    if (ab.alignmentPath.isEmpty || !await file.exists()) return false;
    try {
      final List<AudioCue> parsed = await parseCuesForFormat(file, bookKey, 0);
      if (!await attachAsrCueTokenTiming(parsed, file.path)) return false;
      return attachTokenTimingIfAligned(stored, parsed);
    } on Object catch (e, stack) {
      // 逐 token 时间是可选增强：读不动只是半句命中不可用，整句匹配照常。
      ErrorLogService.instance.log(
        'MangaAudiobookSource.tokenTiming',
        e,
        stack,
      );
      return false;
    }
  }

  /// 与 [bookKey] 同系列的其它卷（系列档案成员 ∪ 系列来自合集时的合集成员）。
  /// 不属于任何系列返回空表。
  Future<List<String>> seriesVolumes(String bookKey) async {
    final String? seriesKey = await resolveSeriesKey(appModel, bookKey);
    if (seriesKey == null) return const <String>[];
    final SeriesCastProfile profile = await seriesCastStoreFor(
      appModel,
    ).load(seriesKey);
    final Set<String> keys = <String>{...profile.members};
    const String collectionPrefix = 'collection:';
    if (seriesKey.startsWith(collectionPrefix)) {
      final int? id = int.tryParse(
        seriesKey.substring(collectionPrefix.length),
      );
      if (id != null) {
        for (final MediaCollectionItemRow item in await _db.getCollectionItems(
          id,
        )) {
          if (item.mediaType != 'epub') continue;
          // 成员键可能是 uid（新行）或 bookKey（旧行），统一换成 bookKey。
          final EpubBookRow? row =
              await _db.getEpubBook(item.entryKey) ??
              await _db.getEpubBookByUid(item.entryKey);
          if (row != null) keys.add(row.bookKey);
        }
      }
    }
    keys.remove(bookKey);
    return keys.toList();
  }

  /// 把 [sources] 写进 [volumes] 每一卷的演出稿（只改书单，不动行与策略）。返回写了
  /// 几卷。
  Future<int> linkSourcesTo(List<String> volumes, List<String> sources) async {
    int written = 0;
    for (final String volume in volumes) {
      final MangaAudioScript script = await _scripts.load(volume);
      script.audiobookSources
        ..clear()
        ..addAll(sources);
      await _scripts.save(volume, script);
      written++;
    }
    return written;
  }
}
