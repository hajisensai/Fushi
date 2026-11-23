/// 有声漫画导出包（`.fushi-manga-audio`）的包清单、卷匹配与系列合并（纯逻辑，不碰
/// 数据库与文件系统）。格式与流程见 `docs/specs/2026-11-23-manga-audio-export-package.md`。
///
/// 包 = 一个普通 zip：
///
/// ```text
/// package.json                      包清单（[MangaAudioPackageManifest]）
/// series/<sid>.series-cast.json     系列档案原样（key 与 members 改写成包内 id）
/// volumes/<vid>/pages/…             页图，按 manga.json 里各页 url 的原相对路径
/// volumes/<vid>/manga.json          MokuroPayload 原样
/// volumes/<vid>/script.json         演出稿原样（MangaAudioScript）
/// volumes/<vid>/audio/manifest.json 成品清单原样（f 相对此目录）+ 各句音频
/// volumes/<vid>/drama/manifest.json 可选：广播剧 / 动画音轨成品 + 各段音频
/// ```
///
/// 内部各文件都是现有格式原样（各自带自己的 `v`），包只在外层加 `package.json`。包里
/// 不出现源设备的绝对路径与本机身份（bookKey / seriesKey），导入时一律重建。
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_line_kind.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';
import 'package:fushi_engine/tts/cast/cast_voice_assignment.dart';
import 'package:fushi_engine/tts/cast/series_cast.dart';
import 'package:fushi_engine/tts/manga_audio/manga_audio_validate.dart'
    show mangaOcrSignature;

/// `package.json` 的 `format`。
const String kMangaAudioPackageFormat = 'fushi-manga-audio';

/// 包文件扩展名（带点，小写）。
const String kMangaAudioPackageExtension = '.fushi-manga-audio';

/// 本版本读写的包清单版本。只在不兼容时加；读方认识的最大版本小于包的 `v` 时拒绝。
const int kMangaAudioPackageVersion = 1;

/// 包清单在 zip 里的名字。
const String kMangaAudioPackageManifestName = 'package.json';

/// 包里一卷的目录（`volumes/<vid>`）。
String mangaAudioPackageVolumeDir(String volumeId) => 'volumes/$volumeId';

/// 包里一个系列档案的路径。
String mangaAudioPackageSeriesFile(String seriesId) =>
    'series/$seriesId.series-cast.json';

/// 读包清单失败。[code] 稳定，给路由 / 界面分辨原因。
class MangaAudioPackageFormatException implements Exception {
  const MangaAudioPackageFormatException(this.code, this.message);

  /// `not_package`（不是有声漫画包 / 缺 package.json）、`too_new`（包版本比本机新）、
  /// `malformed`（结构坏）。
  final String code;
  final String message;

  @override
  String toString() => 'MangaAudioPackageFormatException($code): $message';
}

/// 卷的 OCR **内容**签名：不看引擎签名，只按每页块数、块框与文字算（`content:` 前缀）。
///
/// 卷身份匹配必须用它而不是 `mangaPayloadOcrSignature`：后者在 OCR 自带引擎签名时
/// 直接返回引擎签名，同一个引擎识别的所有卷签名都一样，按它找「同一卷」会把页数恰好
/// 相同的另一卷认成目标。
String mangaPayloadContentSignature(MokuroPayload payload) => mangaOcrSignature(
  engineSignature: null,
  pages: <List<MokuroBlock>>[
    for (final MokuroImage image in payload.images) image.blocks,
  ],
);

/// 一卷文件的整体摘要：按包内路径排序后逐个 `path\0sha256\n` 拼起来再取 sha256。
String mangaAudioPackageFilesDigest(Map<String, String> sha256ByPath) {
  final List<String> paths = sha256ByPath.keys.toList()..sort();
  final StringBuffer canon = StringBuffer();
  for (final String path in paths) {
    canon
      ..write(path)
      ..write('\u0000')
      ..write(sha256ByPath[path])
      ..write('\n');
  }
  return sha256.convert(utf8.encode(canon.toString())).toString();
}

/// 一卷里的一份成品（逐句合成 `audio/` 或广播剧 `drama/`）。
class MangaAudioPackagePart {
  const MangaAudioPackagePart({
    required this.manifest,
    required this.lines,
    required this.durationMs,
    required this.active,
  });

  /// 成品清单在包里的路径。
  final String manifest;
  final int lines;
  final int durationMs;

  /// 源设备当前登记的是不是这一份（导入后登记同一份）。
  final bool active;

  /// 清单所在目录（包内路径）。
  String get dir {
    final int slash = manifest.lastIndexOf('/');
    return slash < 0 ? '' : manifest.substring(0, slash);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'manifest': manifest,
    'lines': lines,
    'durationMs': durationMs,
    'active': active,
  };

  static MangaAudioPackagePart? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? manifest = raw['manifest'];
    if (manifest is! String || !isSafeMangaAudioPackagePath(manifest)) {
      return null;
    }
    final Object? lines = raw['lines'];
    final Object? ms = raw['durationMs'];
    return MangaAudioPackagePart(
      manifest: manifest,
      lines: lines is int ? lines : 0,
      durationMs: ms is int ? ms : 0,
      active: raw['active'] == true,
    );
  }
}

/// 一卷文件的数量、字节与整体摘要（[mangaAudioPackageFilesDigest]）。
class MangaAudioPackageFiles {
  const MangaAudioPackageFiles({
    required this.count,
    required this.bytes,
    required this.sha256,
  });

  final int count;
  final int bytes;
  final String sha256;

  Map<String, Object?> toJson() => <String, Object?>{
    'count': count,
    'bytes': bytes,
    'sha256': sha256,
  };

  static MangaAudioPackageFiles? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? count = raw['count'];
    final Object? bytes = raw['bytes'];
    final Object? digest = raw['sha256'];
    if (count is! int || bytes is! int || digest is! String) return null;
    return MangaAudioPackageFiles(count: count, bytes: bytes, sha256: digest);
  }
}

/// 包里的一卷。
class MangaAudioPackageVolume {
  const MangaAudioPackageVolume({
    required this.id,
    required this.title,
    required this.pageCount,
    required this.blocks,
    required this.content,
    required this.files,
    this.series,
    this.ocr,
    this.script,
    this.scriptStale = false,
    this.audio,
    this.drama,
    this.voices = const <String>[],
  });

  /// 包内序号（`v1`、`v2`…）。
  final String id;
  final String title;

  /// 所属系列的包内 id；null = 不属于任何系列。
  final String? series;
  final int pageCount;

  /// OCR 块总数（0 = 没有识别结果，这时内容签名只剩页数，匹配要再看标题）。
  final int blocks;

  /// 本卷当前 OCR 签名（与 `MangaRenderManifest.ocr` 同值：引擎签名优先）。
  final String? ocr;

  /// OCR 内容签名（[mangaPayloadContentSignature]），卷身份匹配用。
  final String content;

  /// 演出稿在包里的路径；null = 没带演出稿。
  final String? script;

  /// 演出稿的 OCR 签名与本卷当前 OCR 不一致（导入方要提示重新标注）。
  final bool scriptStale;
  final MangaAudioPackagePart? audio;
  final MangaAudioPackagePart? drama;

  /// 清单与演出稿里出现过的声音 id（只用于「继续重配」前的缺失检查）。
  final List<String> voices;
  final MangaAudioPackageFiles files;

  String get dir => mangaAudioPackageVolumeDir(id);
  String get manga => '$dir/manga.json';
  String get pagesDir => '$dir/pages';

  /// 有成品（不是仅演出稿）。
  bool get hasAudio => audio != null || drama != null;

  /// 登记成这一卷有声的那份成品（`active` 的那份；都没标时优先逐句合成）。
  MangaAudioPackagePart? get activePart {
    if (audio?.active ?? false) return audio;
    if (drama?.active ?? false) return drama;
    return audio ?? drama;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'series': series,
    'pageCount': pageCount,
    'blocks': blocks,
    'ocr': ocr,
    'content': content,
    'manga': manga,
    'pages': pagesDir,
    'script': script,
    if (scriptStale) 'scriptStale': true,
    'audio': audio?.toJson(),
    'drama': drama?.toJson(),
    'voices': voices,
    'files': files.toJson(),
  };

  static MangaAudioPackageVolume? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? pageCount = raw['pageCount'];
    final Object? content = raw['content'];
    final MangaAudioPackageFiles? files = MangaAudioPackageFiles.fromJson(
      raw['files'],
    );
    if (id is! String ||
        !_isPackageId(id) ||
        pageCount is! int ||
        pageCount <= 0 ||
        content is! String ||
        files == null) {
      return null;
    }
    final Object? title = raw['title'];
    final Object? series = raw['series'];
    final Object? blocks = raw['blocks'];
    final Object? ocr = raw['ocr'];
    final Object? script = raw['script'];
    final Object? voices = raw['voices'];
    final String? scriptPath = script is String ? script : null;
    if (script != null &&
        (scriptPath == null || !isSafeMangaAudioPackagePath(scriptPath))) {
      return null;
    }
    final MangaAudioPackagePart? audio = MangaAudioPackagePart.fromJson(
      raw['audio'],
    );
    final MangaAudioPackagePart? drama = MangaAudioPackagePart.fromJson(
      raw['drama'],
    );
    final String volumeDir = mangaAudioPackageVolumeDir(id);
    for (final String? path in <String?>[
      scriptPath,
      audio?.manifest,
      drama?.manifest,
    ]) {
      // 卷里的路径必须落在本卷目录下：不让一卷的清单指到别的卷去。
      if (path != null && !path.startsWith('$volumeDir/')) return null;
    }
    return MangaAudioPackageVolume(
      id: id,
      title: title is String ? title : '',
      series: series is String && _isPackageId(series) ? series : null,
      pageCount: pageCount,
      blocks: blocks is int ? blocks : 0,
      ocr: ocr is String ? ocr : null,
      content: content,
      script: scriptPath,
      scriptStale: raw['scriptStale'] == true,
      audio: audio,
      drama: drama,
      voices: <String>[
        if (voices is List)
          for (final Object? v in voices)
            if (v is String && v.isNotEmpty) v,
      ],
      files: files,
    );
  }
}

/// 包里的一个系列。
class MangaAudioPackageSeries {
  const MangaAudioPackageSeries({
    required this.id,
    required this.title,
    required this.members,
  });

  /// 包内序号（`s1`…）。
  final String id;
  final String title;

  /// 成员卷的包内 id，按源设备的系列顺序。
  final List<String> members;

  String get file => mangaAudioPackageSeriesFile(id);

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'title': title,
    'file': file,
    'members': members,
  };

  static MangaAudioPackageSeries? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || !_isPackageId(id)) return null;
    final Object? title = raw['title'];
    final Object? members = raw['members'];
    return MangaAudioPackageSeries(
      id: id,
      title: title is String ? title : '',
      members: <String>[
        if (members is List)
          for (final Object? m in members)
            if (m is String && _isPackageId(m)) m,
      ],
    );
  }
}

/// `package.json`。
class MangaAudioPackageManifest {
  const MangaAudioPackageManifest({
    required this.createdAt,
    required this.app,
    required this.series,
    required this.volumes,
    this.version = kMangaAudioPackageVersion,
  });

  final int version;

  /// 导出时刻（毫秒）。
  final int createdAt;

  /// 导出方（`fushi <版本>`）。
  final String app;
  final List<MangaAudioPackageSeries> series;
  final List<MangaAudioPackageVolume> volumes;

  MangaAudioPackageSeries? seriesById(String? id) {
    if (id == null) return null;
    for (final MangaAudioPackageSeries s in series) {
      if (s.id == id) return s;
    }
    return null;
  }

  MangaAudioPackageVolume? volumeById(String id) {
    for (final MangaAudioPackageVolume v in volumes) {
      if (v.id == id) return v;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'format': kMangaAudioPackageFormat,
    'v': version,
    'createdAt': createdAt,
    'app': app,
    'series': <Object?>[
      for (final MangaAudioPackageSeries s in series) s.toJson(),
    ],
    'volumes': <Object?>[
      for (final MangaAudioPackageVolume v in volumes) v.toJson(),
    ],
  };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  /// 解析包清单。不是有声漫画包、版本比本机新、结构坏都抛
  /// [MangaAudioPackageFormatException]。
  static MangaAudioPackageManifest parse(String text) {
    final Object? raw;
    try {
      raw = jsonDecode(text);
    } on FormatException {
      throw const MangaAudioPackageFormatException(
        'malformed',
        'package.json is not valid JSON',
      );
    }
    if (raw is! Map || raw['format'] != kMangaAudioPackageFormat) {
      throw const MangaAudioPackageFormatException(
        'not_package',
        'not a Fushi manga audio package',
      );
    }
    final Object? v = raw['v'];
    if (v is! int || v < 1) {
      throw const MangaAudioPackageFormatException(
        'malformed',
        'package.json has no valid version',
      );
    }
    if (v > kMangaAudioPackageVersion) {
      throw MangaAudioPackageFormatException(
        'too_new',
        'package version $v is newer than supported '
            '($kMangaAudioPackageVersion)',
      );
    }
    final Object? series = raw['series'];
    final Object? volumes = raw['volumes'];
    if (volumes is! List || volumes.isEmpty) {
      throw const MangaAudioPackageFormatException(
        'malformed',
        'package.json lists no volumes',
      );
    }
    final List<MangaAudioPackageVolume> parsedVolumes =
        <MangaAudioPackageVolume>[];
    final Set<String> ids = <String>{};
    for (final Object? entry in volumes) {
      final MangaAudioPackageVolume? volume = MangaAudioPackageVolume.fromJson(
        entry,
      );
      if (volume == null || !ids.add(volume.id)) {
        throw const MangaAudioPackageFormatException(
          'malformed',
          'package.json has a malformed or duplicate volume entry',
        );
      }
      parsedVolumes.add(volume);
    }
    final List<MangaAudioPackageSeries> parsedSeries =
        <MangaAudioPackageSeries>[
          if (series is List)
            for (final Object? s in series)
              if (MangaAudioPackageSeries.fromJson(s)
                  case final MangaAudioPackageSeries entry)
                entry,
        ];
    final Object? createdAt = raw['createdAt'];
    final Object? app = raw['app'];
    return MangaAudioPackageManifest(
      version: v,
      createdAt: createdAt is int ? createdAt : 0,
      app: app is String ? app : '',
      series: parsedSeries,
      volumes: parsedVolumes,
    );
  }
}

/// 包内路径是否安全：正斜杠相对路径、没有 `..` / 空段 / 盘符 / 反斜杠。
bool isSafeMangaAudioPackagePath(String path) {
  if (path.isEmpty || path.startsWith('/') || path.contains('\\')) {
    return false;
  }
  if (path.contains(':')) return false;
  for (final String segment in path.split('/')) {
    if (segment.isEmpty || segment == '.' || segment == '..') return false;
  }
  return true;
}

bool _isPackageId(String id) => RegExp(r'^[a-z][0-9]{1,6}$').hasMatch(id);

// ─────────────────────────────────────────────────────────────────────────
// 卷匹配
// ─────────────────────────────────────────────────────────────────────────

/// 本机库里一卷可匹配的身份。
class MangaPackageLocalVolume {
  const MangaPackageLocalVolume({
    required this.bookKey,
    required this.title,
    required this.pageCount,
    required this.content,
  });

  final String bookKey;
  final String title;
  final int pageCount;

  /// [mangaPayloadContentSignature]。
  final String content;
}

enum MangaPackageMatchKind {
  /// 本机已有同一卷（页数与 OCR 内容一致），直接用它。
  existing,

  /// 本机没有，作为新卷导入。
  create,

  /// 本机有同名卷，但页数 / OCR 不一致：要用户选「作为新卷导入」或跳过。
  conflict,
}

/// 冲突的原因。
enum MangaPackageConflict { pageMismatch, ocrMismatch }

class MangaPackageVolumeMatch {
  const MangaPackageVolumeMatch.existing(String this.bookKey)
    : kind = MangaPackageMatchKind.existing,
      conflict = null;

  const MangaPackageVolumeMatch.create()
    : kind = MangaPackageMatchKind.create,
      bookKey = null,
      conflict = null;

  const MangaPackageVolumeMatch.conflict(
    String this.bookKey,
    MangaPackageConflict this.conflict,
  ) : kind = MangaPackageMatchKind.conflict;

  final MangaPackageMatchKind kind;

  /// [MangaPackageMatchKind.existing] / [MangaPackageMatchKind.conflict] 时本机那一卷。
  final String? bookKey;
  final MangaPackageConflict? conflict;
}

/// 在本机卷 [local] 里找包里的一卷 [volume]（设计稿 §5.1）：
///
/// 1. 页数与 OCR 内容签名都一致的卷是同一卷；有多个时取同标题的。没有任何 OCR 块的卷
///    内容签名只剩页数，必须再标题一致才算；
/// 2. 否则有同标题的卷 → 冲突（页数不同 = pageMismatch，否则 ocrMismatch）；
/// 3. 都没有 → 新卷。
MangaPackageVolumeMatch matchMangaAudioPackageVolume(
  MangaAudioPackageVolume volume,
  Iterable<MangaPackageLocalVolume> local,
) {
  final String title = volume.title.trim();
  final List<MangaPackageLocalVolume> same = <MangaPackageLocalVolume>[
    for (final MangaPackageLocalVolume l in local)
      if (l.pageCount == volume.pageCount &&
          l.content == volume.content &&
          (volume.blocks > 0 || l.title.trim() == title))
        l,
  ];
  if (same.isNotEmpty) {
    for (final MangaPackageLocalVolume l in same) {
      if (l.title.trim() == title) {
        return MangaPackageVolumeMatch.existing(l.bookKey);
      }
    }
    return MangaPackageVolumeMatch.existing(same.first.bookKey);
  }
  if (title.isNotEmpty) {
    for (final MangaPackageLocalVolume l in local) {
      if (l.title.trim() != title) continue;
      return MangaPackageVolumeMatch.conflict(
        l.bookKey,
        l.pageCount != volume.pageCount
            ? MangaPackageConflict.pageMismatch
            : MangaPackageConflict.ocrMismatch,
      );
    }
  }
  return const MangaPackageVolumeMatch.create();
}

// ─────────────────────────────────────────────────────────────────────────
// 系列合并
// ─────────────────────────────────────────────────────────────────────────

/// 把包里的系列档案 [incoming] 并进本机档案 [local]（原地改，设计稿 §5.4）：
///
/// - 角色表：[mergeCastRoster]（同名合并别名、空特征补上）；
/// - 声音指派：**本机已设的优先**，包里的只补本机没设的那一级（角色名先换成本机
///   角色表里的规范名）；重试候选去重追加；
/// - 用词替换 / 人名读法：按原文（`source` + 类型）去重追加；
/// - 默认种子、展示名：本机没有才用包里的。
///
/// 成员顺序不在这里处理（要先把包内卷 id 换成本机 bookKey）。
void mergeImportedSeriesProfile(
  SeriesCastProfile local,
  SeriesCastProfile incoming,
) {
  mergeCastRoster(local.roster, incoming.roster.values);
  String canonical(String name) =>
      canonicalCastName(local.roster, name) ?? name;
  final CastVoiceAssignment mine = local.voices;
  final CastVoiceAssignment theirs = incoming.voices;
  mine.defaultVoice ??= theirs.defaultVoice;
  mine.narrationVoice ??= theirs.narrationVoice;
  theirs.byCharacter.forEach((String name, String voice) {
    mine.byCharacter.putIfAbsent(canonical(name), () => voice);
  });
  theirs.byCharacterKind.forEach((
    String name,
    Map<CastLineKind, String> kinds,
  ) {
    final Map<CastLineKind, String> target = mine.byCharacterKind.putIfAbsent(
      canonical(name),
      () => <CastLineKind, String>{},
    );
    kinds.forEach(
      (CastLineKind kind, String voice) =>
          target.putIfAbsent(kind, () => voice),
    );
  });
  for (final String voice in theirs.retryVoices) {
    if (!mine.retryVoices.contains(voice)) mine.retryVoices.add(voice);
  }
  final Set<String> known = <String>{
    for (final CastTextSubstitution s in local.substitutions)
      '${s.kind.name}\u0000${s.source}',
  };
  for (final CastTextSubstitution s in incoming.substitutions) {
    if (known.add('${s.kind.name}\u0000${s.source}')) {
      local.substitutions.add(s);
    }
  }
  local.defaultSeed ??= incoming.defaultSeed;
  if (local.title.isEmpty) local.title = incoming.title;
}

/// 按包里的成员顺序把 [ordered]（已换成本机 bookKey）并进 [members]：已在的不动，
/// 不在的插到包里排在它前面的那一卷之后（都不在就追加到末尾），保持包里的相对顺序。
void mergeSeriesMemberOrder(List<String> members, List<String> ordered) {
  String? previous;
  for (final String key in ordered) {
    if (!members.contains(key)) {
      final int at = previous == null ? -1 : members.indexOf(previous);
      if (at < 0) {
        members.add(key);
      } else {
        members.insert(at + 1, key);
      }
    }
    previous = key;
  }
}
