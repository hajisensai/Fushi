/// 漫画有声成品入库：把生成端写好的 [MangaRenderManifest] 登记成 `Audiobooks` +
/// `AudioCues`（设计 §3），以及单句补回后的增量更新。
///
/// 库里的形态（生成端与播放端的契约，见 `manga_audio_render.dart` 文件头）：
/// - `Audiobooks.alignmentFormat` = [kMangaAlignmentFormat]，`alignmentPath` = 清单
///   路径，音频列表 = 清单里各句的文件（按行顺序；落库成绝对路径——仓库层
///   `AudiobookRepository.replaceAudio` 的契约是落地后的绝对路径，播放 / 删除 / 数据
///   根迁移都按它读）；
/// - 每句一条 cue：`chapterHref` = [mangaPageHref]，`textFragmentId` =
///   [mangaBlocksFragment]，`startMs = 0`、`endMs = 时长`、`audioFileIndex` =
///   `sentenceIndex` = 行下标。逐句生成即有精确时间，不跑匹配器。
///
/// 页停留 / `lead` / 句间停顿不进库（它们不是句），播放时由
/// `manga_audio_playback_plan.dart` 按清单的时间表插入。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:drift/drift.dart' show Value;
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart'
    show MokuroPayload, parseMangaJson;
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:path/path.dart' as p;

/// 一本漫画已登记的有声成品。
class MangaAudioRegistration {
  const MangaAudioRegistration({
    required this.bookKey,
    required this.manifestFile,
    required this.manifest,
  });

  final String bookKey;
  final File manifestFile;
  final MangaRenderManifest manifest;

  String get manifestDir => manifestFile.parent.path;

  /// 第 [lineIndex] 句音频的绝对路径。
  String linePath(MangaRenderedLine line) =>
      mangaAudioLinePath(manifestFile, line);
}

/// 清单里一句音频（相对清单目录）的绝对路径。
String mangaAudioLinePath(File manifestFile, MangaRenderedLine line) =>
    p.normalize(p.join(manifestFile.parent.path, line.file));

/// 库里每句一条 cue（与清单行一一对应）。
List<AudioCue> mangaAudioCues(String bookKey, MangaRenderManifest manifest) =>
    <AudioCue>[
      for (int i = 0; i < manifest.lines.length; i++)
        _cueFor(bookKey, manifest.lines[i], i),
    ];

AudioCue _cueFor(String bookKey, MangaRenderedLine line, int index) =>
    AudioCue()
      ..bookKey = bookKey
      ..chapterHref = mangaPageHref(line.page)
      ..sentenceIndex = index
      ..textFragmentId = mangaBlocksFragment(line.blocks)
      ..text = line.text
      ..startMs = 0
      ..endMs = line.durationMs
      ..audioFileIndex = index;

/// 登记（或整份替换）[bookKey] 的漫画有声成品。幂等：同一份清单重复登记得到同样的
/// 行；换了清单则音频列表、对齐与 cue 整组换掉。进度按仓库层既有规则处理：音频列表
/// 真变了且断点所在文件之前变了才归零，cue 时长变了按旧 / 新 cue 换算
/// （`AudiobookRepository.replaceAudio` / `saveCues`）。
Future<void> registerMangaAudio(
  FushiDatabase db, {
  required String bookKey,
  required File manifestFile,
  required MangaRenderManifest manifest,
}) async {
  final AudiobookRepository repo = AudiobookRepository(db);
  await repo.ensureAudiobook(bookKey);
  await repo.replaceAlignment(
    bookKey: bookKey,
    format: kMangaAlignmentFormat,
    path: manifestFile.absolute.path,
  );
  await repo.replaceAudio(
    bookKey: bookKey,
    audioPaths: <String>[
      for (final MangaRenderedLine line in manifest.lines)
        mangaAudioLinePath(manifestFile.absolute, line),
    ],
  );
  await repo.saveCues(
    bookKey: bookKey,
    cues: mangaAudioCues(bookKey, manifest),
  );
}

/// 单句补回之后更新库：生成端已用 [MangaRenderManifest.replaceLine] 换好这一句并
/// 存回清单，这里只把这一句的音频路径、时长与文本写进库，其余句子原样不动。
///
/// 库里的 cue 与清单行数对不上（库是旧清单登记的）时退回整份重登记——那不是「一句
/// 的变化」。[lineId] 不在清单里返回 false。
Future<bool> updateMangaAudioLine(
  FushiDatabase db, {
  required String bookKey,
  required File manifestFile,
  required MangaRenderManifest manifest,
  required String lineId,
}) => updateMangaAudioLines(
  db,
  bookKey: bookKey,
  manifestFile: manifestFile,
  manifest: manifest,
  lineIds: <String>[lineId],
);

/// 多句一起换过之后更新库（批量补回 / 换本地音频 / 按角色重生成 / 它们的撤销）：只把
/// [lineIds] 这几句的音频路径、时长与文本写进库，一个事务写完；续听位置仍在同一句
/// （`AudiobookRepository.swapAudioFiles`：落在被换的句子里就从它开头接着听，别的
/// 句子里原样保留偏移）。规则同 [updateMangaAudioLine]：库与
/// 清单行数对不上时整份重登记；[lineIds] 里有不在清单里的句子返回 false（什么都不写）。
Future<bool> updateMangaAudioLines(
  FushiDatabase db, {
  required String bookKey,
  required File manifestFile,
  required MangaRenderManifest manifest,
  required Iterable<String> lineIds,
}) async {
  final Set<int> indexes = <int>{};
  for (final String lineId in lineIds) {
    final int index = manifest.lines.indexWhere(
      (MangaRenderedLine l) => l.lineId == lineId,
    );
    if (index < 0) return false;
    indexes.add(index);
  }
  if (indexes.isEmpty) return true;
  final AudiobookRepository repo = AudiobookRepository(db);
  final List<AudioCue> stored = await repo.cuesForBook(bookKey);
  final Audiobook? audiobook = await repo.findByBookKey(bookKey);
  final List<String>? paths = audiobook?.audioPaths;
  if (audiobook == null ||
      audiobook.alignmentFormat != kMangaAlignmentFormat ||
      paths == null ||
      paths.length != manifest.lines.length ||
      stored.length != manifest.lines.length) {
    await registerMangaAudio(
      db,
      bookKey: bookKey,
      manifestFile: manifestFile,
      manifest: manifest,
    );
    return true;
  }
  stored.sort((AudioCue a, AudioCue b) => a.audioFileIndex - b.audioFileIndex);
  final List<String> nextPaths = List<String>.of(paths);
  for (final int index in indexes) {
    nextPaths[index] = mangaAudioLinePath(
      manifestFile.absolute,
      manifest.lines[index],
    );
  }
  final List<AudioCue> nextCues = <AudioCue>[
    for (int i = 0; i < stored.length; i++)
      indexes.contains(i) ? _cueFor(bookKey, manifest.lines[i], i) : stored[i],
  ];
  // 句子结构没变、只换了这几句的音频：cue、音频列表与续听位置一起改，断点仍在同一句
  // （落在被换的句子里就从它开头接着听），不按「换了一套音频」归零。
  await repo.swapAudioFiles(
    bookKey: bookKey,
    cues: nextCues,
    paths: <int, String>{
      for (final int index in indexes) index: nextPaths[index],
    },
  );
  return true;
}

/// [bookKey] 登记过的漫画有声成品；没有、不是漫画格式、清单读不出来都返回 null。
Future<MangaAudioRegistration?> loadMangaAudio(
  FushiDatabase db,
  String bookKey,
) async {
  final AudiobookRow? row = await db.getAudiobookByBookKey(bookKey);
  if (row == null || row.alignmentFormat != kMangaAlignmentFormat) return null;
  final File manifestFile = File(row.alignmentPath);
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  if (manifest == null) return null;
  return MangaAudioRegistration(
    bookKey: bookKey,
    manifestFile: manifestFile,
    manifest: manifest,
  );
}

/// 手动导入一份清单的结果。
enum MangaAudioImportResult {
  imported,

  /// 读不出 / 结构坏的清单。
  invalid,

  /// 清单页数与这一卷的 `manga.json` 不符（不是这卷的成品）。
  pageMismatch,

  /// 清单引用的音频文件缺失。
  missingAudio,

  /// 清单记的 OCR 签名与本卷当前 OCR 不符（OCR 重跑过：块下标对不上，高亮会错位）。
  ocrMismatch,
}

/// 清单是不是这一卷当前 OCR 的成品：页数不符 → [MangaAudioImportResult.pageMismatch]；
/// 清单记了 OCR 签名而与本卷当前签名（与标注 / 生成同一种：引擎签名优先，mokuro 导入
/// 的卷按块内容算）不符 → [MangaAudioImportResult.ocrMismatch]；对得上返回 null。
MangaAudioImportResult? mangaManifestVolumeMismatch(
  MangaRenderManifest manifest,
  MokuroPayload payload,
) {
  if (payload.images.length != manifest.pageCount) {
    return MangaAudioImportResult.pageMismatch;
  }
  final String? recorded = manifest.engineSignature;
  if (recorded != null && recorded != mangaPayloadOcrSignature(payload)) {
    return MangaAudioImportResult.ocrMismatch;
  }
  return null;
}

/// 一份成品清单对某一卷的校验结论（界面「导入漫画有声」与控制通道 `tts import` 共用）。
class MangaAudioManifestCheck {
  const MangaAudioManifestCheck._({
    this.failure,
    this.manifest,
    this.volumePages,
    this.missingFiles = const <String>[],
  });

  /// 没通过的原因；null = 可以登记。
  final MangaAudioImportResult? failure;

  /// 读出的清单（[MangaAudioImportResult.invalid] 时为 null）。
  final MangaRenderManifest? manifest;

  /// 本卷 `manga.json` 的页数（读不出本卷时为 null）。
  final int? volumePages;

  /// 清单引用而磁盘上不存在的音频（绝对路径，按清单顺序）。
  final List<String> missingFiles;

  bool get ok => failure == null;
}

/// 校验清单：结构、页数与 OCR 签名与本卷一致、引用的音频都在。不写库。
Future<MangaAudioManifestCheck> checkMangaAudioManifest(
  FushiDatabase db, {
  required String bookKey,
  required File manifestFile,
}) async {
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  if (manifest == null) {
    return const MangaAudioManifestCheck._(
      failure: MangaAudioImportResult.invalid,
    );
  }
  int? volumePages;
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row != null) {
    final File mangaJson = File(p.join(row.extractDir, row.epubPath));
    if (await mangaJson.exists()) {
      MokuroPayload? payload;
      try {
        payload = parseMangaJson(await mangaJson.readAsString());
      } on Object {
        // 读不出本卷的 manga.json：不拿它否决导入，播放时阅读器还会再核一次页数。
      }
      if (payload != null) {
        volumePages = payload.images.length;
        final MangaAudioImportResult? mismatch = mangaManifestVolumeMismatch(
          manifest,
          payload,
        );
        if (mismatch != null) {
          return MangaAudioManifestCheck._(
            failure: mismatch,
            manifest: manifest,
            volumePages: volumePages,
          );
        }
      }
    }
  }
  final List<String> missing = <String>[
    for (final MangaRenderedLine line in manifest.lines)
      if (!await File(mangaAudioLinePath(manifestFile, line)).exists())
        mangaAudioLinePath(manifestFile, line),
  ];
  return MangaAudioManifestCheck._(
    failure: missing.isEmpty ? null : MangaAudioImportResult.missingAudio,
    manifest: manifest,
    volumePages: volumePages,
    missingFiles: missing,
  );
}

/// 漫画卡「导入漫画有声」：校验清单（[checkMangaAudioManifest]）后登记。
/// 生成端（制作台）直接调 [registerMangaAudio]，不走这里。
Future<MangaAudioImportResult> importMangaAudioManifest(
  FushiDatabase db, {
  required String bookKey,
  required File manifestFile,
}) async {
  final MangaAudioManifestCheck check = await checkMangaAudioManifest(
    db,
    bookKey: bookKey,
    manifestFile: manifestFile,
  );
  if (check.failure case final MangaAudioImportResult failure) return failure;
  await registerMangaAudio(
    db,
    bookKey: bookKey,
    manifestFile: manifestFile,
    manifest: check.manifest!,
  );
  return MangaAudioImportResult.imported;
}

/// [row] 是不是一份真的登记（`ensureAudiobookRow` 建出的空行不算）。
bool audiobookRowHasRegistration(AudiobookRow row) =>
    row.alignmentPath.isNotEmpty ||
    row.audioRoot != null ||
    (row.audioPathsJson != null && row.audioPathsJson != '[]');

/// [bookKey] 当前有声登记的指纹（对齐格式 / 路径、音频列表、整组 cue）；没有行为 null。
/// 导入的撤销据此判断导入之后有没有被别的操作（重新生成、单句补回、再导入）改过。
Future<String?> audiobookRegistrationRevision(
  FushiDatabase db,
  String bookKey,
) async {
  final AudiobookRow? row = await db.getAudiobookByBookKey(bookKey);
  if (row == null) return null;
  final List<AudioCueRow> cues = await db.getCuesForBook(bookKey);
  final String canonical = jsonEncode(<Object?>[
    row.alignmentFormat,
    row.alignmentPath,
    row.audioRoot,
    row.audioPathsJson,
    for (final AudioCueRow c in cues)
      <Object?>[
        c.chapterHref,
        c.sentenceIndex,
        c.textFragmentId,
        c.cueText,
        c.startMs,
        c.endMs,
        c.audioFileIndex,
        c.tokenTimingJson,
      ],
  ]);
  return sha1.convert(utf8.encode(canonical)).toString();
}

/// 导入会改的那部分登记的前态快照（可 JSON 往返，撤销载荷持久化进本机操作记录）：
/// audiobooks 行的音频 / 对齐四列、整组 cue、播放断点。没有登记时 `exists` = false。
Future<Map<String, Object?>> captureAudiobookRegistration(
  FushiDatabase db,
  String bookKey,
) async {
  final AudiobookRow? row = await db.getAudiobookByBookKey(bookKey);
  final int positionMs = await AudiobookRepository(db).readPositionMs(bookKey);
  if (row == null) {
    return <String, Object?>{'exists': false, 'positionMs': positionMs};
  }
  return <String, Object?>{
    'exists': true,
    'audioRoot': row.audioRoot,
    'audioPathsJson': row.audioPathsJson,
    'alignmentFormat': row.alignmentFormat,
    'alignmentPath': row.alignmentPath,
    'cues': <Map<String, Object?>>[
      for (final AudioCueRow c in await db.getCuesForBook(bookKey))
        <String, Object?>{
          'chapterHref': c.chapterHref,
          'sentenceIndex': c.sentenceIndex,
          'textFragmentId': c.textFragmentId,
          'cueText': c.cueText,
          'startMs': c.startMs,
          'endMs': c.endMs,
          'audioFileIndex': c.audioFileIndex,
          'tokenTimingJson': c.tokenTimingJson,
        },
    ],
    'positionMs': positionMs,
  };
}

/// 把 [bookKey] 的登记放回 [snapshot]（[captureAudiobookRegistration] 抓的前态）。
/// 只动登记行与 cue，不删任何音频文件；前态没有登记时删掉登记行。
Future<void> restoreAudiobookRegistration(
  FushiDatabase db,
  String bookKey,
  Map<String, Object?> snapshot,
) async {
  final AudiobookRepository repo = AudiobookRepository(db);
  if (snapshot['exists'] != true) {
    await db.deleteAudiobookByBookKey(bookKey);
  } else {
    final Object? rawCues = snapshot['cues'];
    final List<AudioCuesCompanion> cues = <AudioCuesCompanion>[
      if (rawCues is List)
        for (final Object? c in rawCues)
          if (c is Map)
            AudioCuesCompanion.insert(
              bookKey: bookKey,
              chapterHref: '${c['chapterHref']}',
              sentenceIndex: (c['sentenceIndex']! as num).toInt(),
              textFragmentId: '${c['textFragmentId']}',
              cueText: '${c['cueText']}',
              startMs: (c['startMs']! as num).toInt(),
              endMs: (c['endMs']! as num).toInt(),
              audioFileIndex: (c['audioFileIndex']! as num).toInt(),
              tokenTimingJson: Value<String?>(c['tokenTimingJson'] as String?),
            ),
    ];
    await db.transaction(() async {
      await db.ensureAudiobookRow(bookKey);
      await db.patchAudiobook(
        bookKey,
        AudiobooksCompanion(
          audioRoot: Value<String?>(snapshot['audioRoot'] as String?),
          audioPathsJson: Value<String?>(snapshot['audioPathsJson'] as String?),
          alignmentFormat: Value<String>('${snapshot['alignmentFormat']}'),
          alignmentPath: Value<String>('${snapshot['alignmentPath']}'),
        ),
      );
      await db.replaceCuesForBook(bookKey, cues);
    });
  }
  final Object? position = snapshot['positionMs'];
  await repo.updatePositionMs(
    bookKey: bookKey,
    positionMs: position is num ? position.toInt() : 0,
  );
}
