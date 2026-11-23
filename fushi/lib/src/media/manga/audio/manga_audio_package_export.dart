/// 有声漫画导出包：导出（设计稿 §4）。
///
/// 两步：[planMangaAudioPackageExport] 只读本地——逐卷校验、列出要打包的文件（缺页图 /
/// 缺音频在这一步就整卷报错，不打残包），快、可同步报错；[runMangaAudioPackageExport]
/// 逐文件算摘要、生成 `package.json`、在工作 isolate 里流式写包（`.part` → 改名），
/// 可取消。界面与控制通道（`tts export`）共用这一对函数。
///
/// 导出什么：页图 + `manga.json` + 演出稿 + 已登记的成品（逐句合成 `audio/` 与广播剧
/// `drama/`，各自清单原样）+ 涉及到的系列档案（key 与成员改写成包内 id）。不导出：
/// 未配音账本、标注失败账本、AI 配置与密钥、声音模型 / 参考音频、阅读进度。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart' show ffcSha256File;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart'
    show MangaImporter;
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_package.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_render.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_script.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaPayloadOcrSignature;
import 'package:fushi_engine/utils/misc/safe_file_name.dart'
    show safeWindowsFileName;
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audiobook/tts/cast/series_cast_resolver.dart';
import 'package:fushi/src/media/audiobook/tts/studio/audio_production_host.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_library.dart'
    show audiobookRowHasRegistration, mangaManifestVolumeMismatch;
import 'package:fushi/src/media/manga/audio/manga_audio_package_io.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_render_service.dart'
    show isLocalMangaVolume;
import 'package:fushi/src/media/manga/audio/manga_audio_stores.dart';

/// 要导出的一卷。[scriptOnly] = 只带演出稿（不带成品），给另一台接着生成用。
class MangaPackageExportItem {
  const MangaPackageExportItem(this.bookKey, {this.scriptOnly = false});

  final String bookKey;
  final bool scriptOnly;
}

/// 这一卷现在不能导出的原因（有标注 / 生成任务在跑）；null = 可以。
typedef MangaPackageBusyCheck = String? Function(String bookKey);

/// 计划好的一卷（只在本库内部用）。
class MangaPackageExportVolume {
  MangaPackageExportVolume._({
    required this.id,
    required this.bookKey,
    required this.title,
    required this.pageCount,
    required this.blocks,
    required this.ocr,
    required this.content,
    required this.scriptStale,
    required this.hasScript,
    required this.audio,
    required this.drama,
    required this.voices,
    required this.files,
  });

  final String id;
  final String bookKey;
  final String title;
  final int pageCount;
  final int blocks;
  final String ocr;
  final String content;
  final bool scriptStale;
  final bool hasScript;
  final MangaAudioPackagePart? audio;
  final MangaAudioPackagePart? drama;
  final List<String> voices;

  /// 包内路径 → 源文件绝对路径。
  final Map<String, String> files;
  String? seriesId;

  bool get scriptOnly => audio == null && drama == null;

  /// 登记成这一卷有声的那份成品。
  MangaAudioPackagePart? get activePart =>
      (drama?.active ?? false) ? drama : (audio ?? drama);
}

/// 计划好的一个系列。
class MangaPackageExportSeries {
  MangaPackageExportSeries._({
    required this.id,
    required this.seriesKey,
    required this.profile,
    required this.members,
  });

  final String id;
  final String seriesKey;
  final SeriesCastProfile profile;

  /// 成员卷的包内 id（按本机系列顺序，只含这次导出的卷）。
  final List<String> members;

  /// 写进包里的档案：原样，只把 key 换成包内 id、成员换成包内卷 id。
  Uint8List encode() => Uint8List.fromList(
    utf8.encode(
      jsonEncode(
        SeriesCastProfile(
          seriesKey: id,
          title: profile.title,
          roster: profile.roster,
          voices: profile.voices,
          defaultSeed: profile.defaultSeed,
          members: members,
          substitutions: profile.substitutions,
          updatedAt: profile.updatedAt,
        ).toJson(),
      ),
    ),
  );
}

class MangaPackageExportPlan {
  MangaPackageExportPlan._(this.volumes, this.series);

  final List<MangaPackageExportVolume> volumes;
  final List<MangaPackageExportSeries> series;

  /// 要写的源文件总字节（进度分母）。
  int get totalBytes {
    int total = 0;
    for (final MangaPackageExportVolume v in volumes) {
      for (final String path in v.files.values) {
        total += File(path).lengthSync();
      }
    }
    return total;
  }
}

/// 逐卷校验并列出要打包的文件。校验不过抛 [MangaAudioPackageException]：
/// `empty` / `not_found` / `not_local_manga` / `busy` / `unreadable` / `unsafe_path` /
/// `missing_pages` / `no_audio`（没有登记成品、又没要求仅演出稿）/ `no_script` /
/// `audio_mismatch`（登记的成品不是这卷当前 OCR 的）/ `missing_audio`。
Future<MangaPackageExportPlan> planMangaAudioPackageExport(
  AudioProductionHost host,
  List<MangaPackageExportItem> items, {
  MangaPackageBusyCheck? busy,
}) async {
  final List<MangaPackageExportItem> unique = <MangaPackageExportItem>[];
  final Set<String> seen = <String>{};
  for (final MangaPackageExportItem item in items) {
    if (seen.add(item.bookKey)) unique.add(item);
  }
  if (unique.isEmpty) {
    throw const MangaAudioPackageException('empty', '没有要导出的卷');
  }
  final List<MangaPackageExportVolume> volumes = <MangaPackageExportVolume>[];
  final Map<String, String?> seriesOf = <String, String?>{};
  for (int i = 0; i < unique.length; i++) {
    final MangaPackageExportItem item = unique[i];
    final MangaPackageExportVolume volume = await _planVolume(
      host,
      'v${i + 1}',
      item,
      busy,
    );
    volumes.add(volume);
    seriesOf[item.bookKey] = await resolveSeriesKey(host, item.bookKey);
  }
  final List<MangaPackageExportSeries> series = <MangaPackageExportSeries>[];
  final SeriesCastStore store = seriesCastStoreFor(host);
  for (final MangaPackageExportVolume volume in volumes) {
    final String? seriesKey = seriesOf[volume.bookKey];
    if (seriesKey == null) continue;
    MangaPackageExportSeries? entry;
    for (final MangaPackageExportSeries s in series) {
      if (s.seriesKey == seriesKey) entry = s;
    }
    if (entry == null) {
      final SeriesCastProfile profile = await store.load(seriesKey);
      if (profile.title.isEmpty) {
        final int? collection = seriesCollectionId(seriesKey);
        final MediaCollectionRow? row = collection == null
            ? null
            : await host.database.getMediaCollectionById(collection);
        if (row != null) profile.title = row.name;
      }
      final List<String> order = await seriesMemberBooks(host, seriesKey);
      final List<MangaPackageExportVolume> members =
          <MangaPackageExportVolume>[
            for (final MangaPackageExportVolume v in volumes)
              if (seriesOf[v.bookKey] == seriesKey) v,
          ]..sort((MangaPackageExportVolume a, MangaPackageExportVolume b) {
            final int ia = order.indexOf(a.bookKey);
            final int ib = order.indexOf(b.bookKey);
            // 不在本机系列顺序里的卷排在后面，保持导出顺序。
            return (ia < 0 ? order.length : ia).compareTo(
              ib < 0 ? order.length : ib,
            );
          });
      entry = MangaPackageExportSeries._(
        id: 's${series.length + 1}',
        seriesKey: seriesKey,
        profile: profile,
        members: <String>[
          for (final MangaPackageExportVolume v in members) v.id,
        ],
      );
      series.add(entry);
    }
    volume.seriesId = entry.id;
  }
  return MangaPackageExportPlan._(volumes, series);
}

Future<MangaPackageExportVolume> _planVolume(
  AudioProductionHost host,
  String id,
  MangaPackageExportItem item,
  MangaPackageBusyCheck? busy,
) async {
  final FushiDatabase db = host.database;
  final String bookKey = item.bookKey;
  final EpubBookRow? row = await db.getEpubBook(bookKey);
  if (row == null) {
    throw MangaAudioPackageException('not_found', '书架里没有这一卷：$bookKey');
  }
  if (!isLocalMangaVolume(row)) {
    throw MangaAudioPackageException(
      'not_local_manga',
      '「${row.title}」不是本地漫画卷，不能导出有声漫画',
    );
  }
  final String? busyReason = busy?.call(bookKey);
  if (busyReason != null) {
    throw MangaAudioPackageException('busy', '「${row.title}」$busyReason');
  }
  final String dir = mangaAudioPackageVolumeDir(id);
  final File mangaJson = File(p.join(row.extractDir, row.epubPath));
  final MokuroPayload payload;
  try {
    final String raw = await mangaJson.readAsString();
    payload = await Isolate.run(() => parseMangaJson(raw));
  } on Object {
    throw MangaAudioPackageException(
      'unreadable',
      '读不出「${row.title}」的 manga.json',
    );
  }
  if (payload.images.isEmpty) {
    throw MangaAudioPackageException('unreadable', '「${row.title}」没有页');
  }
  final Map<String, String> files = <String, String>{
    '$dir/manga.json': mangaJson.path,
  };
  final List<String> missingPages = <String>[];
  for (final MokuroImage image in payload.images) {
    final List<String> segments = image.url
        .split(RegExp(r'[\\/]+'))
        .where((String s) => s.isNotEmpty && s != '.')
        .toList();
    final String rel = segments.join('/');
    if (segments.isEmpty || !isSafeMangaAudioPackagePath(rel)) {
      throw MangaAudioPackageException(
        'unsafe_path',
        '「${row.title}」的页图路径不安全：${image.url}',
      );
    }
    final File page = MangaImporter.mokuroPageFile(
      mangaJson.parent.path,
      image.url,
    );
    if (!await page.exists()) {
      missingPages.add(page.path);
      continue;
    }
    files['$dir/pages/$rel'] = page.path;
  }
  if (missingPages.isNotEmpty) {
    throw MangaAudioPackageException(
      'missing_pages',
      '「${row.title}」缺 ${missingPages.length} 张页图',
      details: missingPages,
    );
  }

  final MangaAudioScriptStore scripts = mangaAudioScriptStoreFor(host);
  final File scriptFile = scripts.fileFor(bookKey);
  final bool hasScript = await scriptFile.exists();
  final MangaAudioScript script = await scripts.load(bookKey);
  if (hasScript) files['$dir/script.json'] = scriptFile.path;
  final String ocr = mangaPayloadOcrSignature(payload);
  final bool stale =
      script.freshness(ocr) == MangaScriptFreshness.needsReannotation;

  MangaAudioPackagePart? audio;
  MangaAudioPackagePart? drama;
  final Set<String> voices = <String>{};
  if (item.scriptOnly) {
    if (!hasScript || script.audibleLines.isEmpty) {
      throw MangaAudioPackageException(
        'no_script',
        '「${row.title}」还没有演出稿，不能只导出演出稿',
      );
    }
  } else {
    final AudiobookRow? registration = await db.getAudiobookByBookKey(bookKey);
    if (registration == null ||
        !audiobookRowHasRegistration(registration) ||
        registration.alignmentFormat != kMangaAlignmentFormat) {
      throw MangaAudioPackageException(
        'no_audio',
        '「${row.title}」还没有登记好的有声成品（可只导出演出稿）',
      );
    }
    final String active = p.normalize(
      File(registration.alignmentPath).absolute.path,
    );
    final File internalAudio = mangaRenderManifestFile(host, bookKey).absolute;
    final File internalDrama = mangaDramaManifestFile(host, bookKey).absolute;
    final bool dramaActive = p.equals(active, p.normalize(internalDrama.path));
    // 逐句合成那一份：登记的不是广播剧时就是登记的那份清单（本机生成的，或 `tts
    // import` 导入的外部清单）；登记的是广播剧时带上本机生成的那份（有的话）。
    final File? audioManifest = dramaActive
        ? (await internalAudio.exists() ? internalAudio : null)
        : File(active);
    final File? dramaManifest = dramaActive
        ? internalDrama
        : (await internalDrama.exists() ? internalDrama : null);
    if (audioManifest != null) {
      audio = await _planPart(
        title: row.title,
        manifestFile: audioManifest,
        packageDir: '$dir/audio',
        payload: payload,
        active: !dramaActive,
        files: files,
        voices: voices,
      );
    }
    if (dramaManifest != null) {
      drama = await _planPart(
        title: row.title,
        manifestFile: dramaManifest,
        packageDir: '$dir/drama',
        payload: payload,
        active: dramaActive,
        files: files,
        voices: voices,
      );
    }
    if (audio == null && drama == null) {
      throw MangaAudioPackageException('no_audio', '「${row.title}」登记的有声成品读不出来');
    }
  }
  if (hasScript) {
    final SeriesCastProfile? series = await _seriesOf(host, bookKey);
    for (final MangaScriptLine line in script.audibleLines) {
      final String? voice = script.voices.resolveOver(
        line.speaker,
        line.kind,
        series?.voices,
      );
      if (voice != null && voice.isNotEmpty) voices.add(voice);
    }
  }
  int blocks = 0;
  for (final MokuroImage image in payload.images) {
    blocks += image.blocks.length;
  }
  return MangaPackageExportVolume._(
    id: id,
    bookKey: bookKey,
    title: row.title,
    pageCount: payload.images.length,
    blocks: blocks,
    ocr: ocr,
    content: mangaPayloadContentSignature(payload),
    scriptStale: hasScript && stale,
    hasScript: hasScript,
    audio: audio,
    drama: drama,
    voices: voices.toList()..sort(),
    files: files,
  );
}

Future<SeriesCastProfile?> _seriesOf(
  AudioProductionHost host,
  String bookKey,
) async {
  final String? seriesKey = await resolveSeriesKey(host, bookKey);
  return seriesKey == null
      ? null
      : await seriesCastStoreFor(host).load(seriesKey);
}

/// 一份成品：清单与它引用的每个音频（按清单里的相对路径放进 [packageDir]）。
/// [active] 的那份读不出 / 与本卷 OCR 不符直接报错；另一份（没在登记的）读不出就不带。
/// 引用的音频缺失一律报错（与 `checkMangaAudioManifest` 同口径），不打残包。
Future<MangaAudioPackagePart?> _planPart({
  required String title,
  required File manifestFile,
  required String packageDir,
  required MokuroPayload payload,
  required bool active,
  required Map<String, String> files,
  required Set<String> voices,
}) async {
  final MangaRenderManifest? manifest = await MangaRenderManifest.load(
    manifestFile,
  );
  if (manifest == null) {
    if (!active) return null;
    throw MangaAudioPackageException(
      'unreadable',
      '读不出「$title」登记的成品清单：${manifestFile.path}',
    );
  }
  if (mangaManifestVolumeMismatch(manifest, payload) != null) {
    if (!active) return null;
    throw MangaAudioPackageException(
      'audio_mismatch',
      '「$title」登记的成品与这一卷当前的页数 / OCR 不符，先重新生成或重新导入',
    );
  }
  final String root = manifestFile.parent.absolute.path;
  final Map<String, String> partFiles = <String, String>{
    '$packageDir/manifest.json': manifestFile.absolute.path,
  };
  final List<String> missing = <String>[];
  int durationMs = 0;
  for (final MangaRenderedLine line in manifest.lines) {
    durationMs += line.durationMs;
    if (line.voice case final String voice when voice.isNotEmpty) {
      voices.add(voice);
    }
    final String abs = p.normalize(p.join(root, line.file));
    if (!p.isWithin(root, abs)) {
      throw MangaAudioPackageException(
        'unsafe_path',
        '「$title」的成品清单引用了清单目录以外的音频：${line.file}',
      );
    }
    final String rel = p.posix.joinAll(p.split(p.relative(abs, from: root)));
    if (!await File(abs).exists()) {
      missing.add(abs);
      continue;
    }
    partFiles['$packageDir/$rel'] = abs;
  }
  if (missing.isNotEmpty) {
    throw MangaAudioPackageException(
      'missing_audio',
      '「$title」的成品清单引用的 ${missing.length} 个音频文件不存在',
      details: missing,
    );
  }
  files.addAll(partFiles);
  return MangaAudioPackagePart(
    manifest: '$packageDir/manifest.json',
    lines: manifest.lines.length,
    durationMs: durationMs,
    active: active,
  );
}

/// 按 [plan] 写包到 [outputPath]：逐文件算摘要（`hashing`）→ 写 `package.json` 与各
/// 条目（`writing`，工作 isolate，先写 `.part` 再改名）。[onProgress] 报阶段与 0..1；
/// 取消抛 [MangaAudioPackageCancelled]（半成品已删）。返回导出结果（给界面 / 路由）。
Future<Map<String, Object?>> runMangaAudioPackageExport(
  MangaPackageExportPlan plan, {
  required String outputPath,
  required String appLabel,
  DateTime? now,
  void Function(String phase, double? progress)? onProgress,
  MangaPackageCancelToken? cancel,
}) async {
  final int total = plan.totalBytes;
  // 摘要与写包各读一遍源文件：进度各占一半。
  final double denominator = total <= 0 ? 1 : total * 2;
  int done = 0;
  onProgress?.call('hashing', 0);
  final List<MangaAudioPackageVolume> volumes = <MangaAudioPackageVolume>[];
  for (final MangaPackageExportVolume v in plan.volumes) {
    final Map<String, String> digests = <String, String>{};
    int bytes = 0;
    for (final MapEntry<String, String> f in v.files.entries) {
      cancel?.throwIfCancelled();
      final int size = await File(f.value).length();
      digests[f.key] = await ffcSha256File(f.value);
      bytes += size;
      done += size;
      onProgress?.call('hashing', done / denominator);
    }
    volumes.add(
      MangaAudioPackageVolume(
        id: v.id,
        title: v.title,
        series: v.seriesId,
        pageCount: v.pageCount,
        blocks: v.blocks,
        ocr: v.ocr,
        content: v.content,
        script: v.hasScript
            ? '${mangaAudioPackageVolumeDir(v.id)}/script.json'
            : null,
        scriptStale: v.scriptStale,
        audio: v.audio,
        drama: v.drama,
        voices: v.voices,
        files: MangaAudioPackageFiles(
          count: digests.length,
          bytes: bytes,
          sha256: mangaAudioPackageFilesDigest(digests),
        ),
      ),
    );
  }
  cancel?.throwIfCancelled();
  final MangaAudioPackageManifest manifest = MangaAudioPackageManifest(
    createdAt: (now ?? DateTime.now()).millisecondsSinceEpoch,
    app: appLabel,
    series: <MangaAudioPackageSeries>[
      for (final MangaPackageExportSeries s in plan.series)
        MangaAudioPackageSeries(
          id: s.id,
          title: s.profile.title,
          members: s.members,
        ),
    ],
    volumes: volumes,
  );
  final List<MangaPackageZipEntry> entries = <MangaPackageZipEntry>[
    MangaPackageZipEntry.bytes(
      kMangaAudioPackageManifestName,
      Uint8List.fromList(utf8.encode(manifest.encode())),
    ),
    for (final MangaPackageExportSeries s in plan.series)
      MangaPackageZipEntry.bytes(mangaAudioPackageSeriesFile(s.id), s.encode()),
    for (final MangaPackageExportVolume v in plan.volumes)
      for (final MapEntry<String, String> f in v.files.entries)
        MangaPackageZipEntry.file(f.key, f.value),
  ];
  onProgress?.call('writing', done / denominator);
  await File(outputPath).parent.create(recursive: true);
  await writeMangaAudioPackageZip(
    outputPath: outputPath,
    entries: entries,
    cancel: cancel,
    onBytes: (int delta) {
      done += delta;
      onProgress?.call('writing', done / denominator);
    },
  );
  return <String, Object?>{
    'path': outputPath,
    'bytes': await File(outputPath).length(),
    'series': plan.series.length,
    'volumes': <Map<String, Object?>>[
      for (final MangaPackageExportVolume v in plan.volumes)
        <String, Object?>{
          'id': v.id,
          'bookKey': v.bookKey,
          'title': v.title,
          'pages': v.pageCount,
          'scriptOnly': v.scriptOnly,
          if (v.scriptStale) 'scriptStale': true,
          'lines': v.activePart?.lines ?? 0,
          'durationMs': v.activePart?.durationMs ?? 0,
        },
    ],
  };
}

/// 导出包的默认文件名：单卷取卷名，多卷取系列名 / 第一卷名，非法字符换成 `_`。
String mangaAudioPackageFileName(String title) {
  final String base = title.trim().isEmpty
      ? 'manga-audio'
      : safeWindowsFileName(title.trim());
  return '$base$kMangaAudioPackageExtension';
}
