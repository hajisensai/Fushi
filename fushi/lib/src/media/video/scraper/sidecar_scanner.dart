/// sidecar 本地封面资产识别（刮削流水线第 ① 层，零网络、零歧义）。
///
/// 识别 Jellyfin / Kodi / tinyMediaManager 生态已经落地在视频文件同目录下的
/// 封面图（`poster.jpg` / `folder.jpg` / `<片名>-poster.jpg` 等）与 NFO 元数据
/// （`tvshow.nfo` / `<片名>.nfo` / `movie.nfo`）。命中即直接采用，无需联网匹配。
///
/// 契约见同目录 `scraper_types.dart`（本文件只识别本地资产，产出中立结果，
/// 由上层决定如何落 [CoverMeta]）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'package:fushi/src/media/media_extensions.dart';

/// 判断来源目录内的 sidecar 是否仍是 Hibiki 原样生成物。
///
/// 实现必须同时校验持久化的 artifact 身份和文件当前内容；只有已登记路径且当前
/// SHA-256 与登记值一致时才返回 true。不存在登记、文件已被用户修改或无法校验时
/// 都返回 false，让旧封面流水线继续把它当作用户 sidecar 保护。
abstract interface class SidecarGeneratedArtifactChecker {
  Future<bool> isUnmodifiedGeneratedArtifact(String absolutePath);
}

/// sidecar 扫描结果：命中的海报文件 + 从 NFO 解析出的元数据。
///
/// 全部字段可空；无任何资产时返回全 null 实例（[SidecarResult.empty]）。
class SidecarResult {
  const SidecarResult({
    this.posterFile,
    this.posterIsUnmodifiedGeneratedArtifact = false,
    this.nfoTitle,
    this.nfoTmdbId,
    this.nfoYear,
  });

  /// 全 null 结果（目录不存在 / 无资产 / 不可读时返回）。
  const SidecarResult.empty()
      : posterFile = null,
        posterIsUnmodifiedGeneratedArtifact = false,
        nfoTitle = null,
        nfoTmdbId = null,
        nfoYear = null;

  /// 命中的本地海报文件（按优先序取第一个存在的），无则 null。
  final File? posterFile;

  /// 命中的海报是否为内容未变的 Hibiki 生成物。
  ///
  /// true 时旧封面刮削不能把它登记成 `CoverOrigin.sidecar`，否则后续会把自产
  /// 图片误当用户资产永久保护。字段只表达归属，不隐藏 [posterFile]，便于调用方
  /// 仍能诊断扫描命中。
  final bool posterIsUnmodifiedGeneratedArtifact;

  /// NFO 里的 `<title>` 文本，无则 null。
  final String? nfoTitle;

  /// NFO 里的 TMDB id（`<uniqueid type="tmdb">` 或旧式 `<tmdbid>`），无则 null。
  final String? nfoTmdbId;

  /// NFO 里的 `<year>`，解析不出为 null。
  final int? nfoYear;
}

/// 本地 sidecar 资产扫描器（全静态、无状态）。
class SidecarScanner {
  const SidecarScanner._();

  /// 海报图基名优先序（`poster` > `folder` > `cover`）。
  static const List<String> _posterStems = <String>[
    'poster',
    'folder',
    'cover'
  ];

  /// 海报图扩展名（含点，按此顺序取用）＝图片扩展名基集顺序，显式去掉
  /// `.gif` / `.bmp`（Jellyfin / Kodi 生态 sidecar 海报惯例只产
  /// jpg / jpeg / png / webp，动图更不宜作海报；const Set 基集按书写顺序
  /// 迭代，`.jpg` 最优先维持既有行为）。
  static final List<String> _imageExts = List<String>.unmodifiable(
    kImageExtensionsBase.where(
      (String ext) => ext != '.gif' && ext != '.bmp',
    ),
  );

  /// 扫描 [videoFilePath] 所在目录，识别海报图与 NFO 元数据。
  ///
  /// 目录不存在 / 不可读时返回 [SidecarResult.empty]，绝不抛出。
  static Future<SidecarResult> scan(
    String videoFilePath, {
    SidecarGeneratedArtifactChecker? generatedArtifactChecker,
  }) async {
    final String dirPath = p.dirname(videoFilePath);
    final String baseName = p.basenameWithoutExtension(videoFilePath);
    final Directory dir = Directory(dirPath);

    // 一次性列目录，构建「小写文件名 -> 实际 File」映射，实现大小写不敏感匹配。
    final Map<String, File> filesByLowerName = <String, File>{};
    try {
      if (!await dir.exists()) {
        return const SidecarResult.empty();
      }
      await for (final FileSystemEntity entity
          in dir.list(followLinks: false)) {
        if (entity is File) {
          filesByLowerName[p.basename(entity.path).toLowerCase()] = entity;
        }
      }
    } on FileSystemException {
      // 目录不可读：中立返回，交由上层降级到下一层刮削。
      return const SidecarResult.empty();
    }

    final File? poster = _findPoster(filesByLowerName, baseName);
    bool posterIsUnmodifiedGeneratedArtifact = false;
    if (poster != null && generatedArtifactChecker != null) {
      try {
        posterIsUnmodifiedGeneratedArtifact =
            await generatedArtifactChecker.isUnmodifiedGeneratedArtifact(
          p.normalize(p.absolute(poster.path)),
        );
      } on Object {
        // 归属校验失败时保守视作第三方/已修改文件，保持旧的用户 sidecar 保护。
        posterIsUnmodifiedGeneratedArtifact = false;
      }
    }
    final _NfoData nfo = await _findAndParseNfo(filesByLowerName, baseName);

    return SidecarResult(
      posterFile: poster,
      posterIsUnmodifiedGeneratedArtifact: posterIsUnmodifiedGeneratedArtifact,
      nfoTitle: nfo.title,
      nfoTmdbId: nfo.tmdbId,
      nfoYear: nfo.year,
    );
  }

  /// 按优先序返回第一个命中的海报文件；无则 null。
  ///
  /// 顺序：`poster` > `folder` > `cover`（各自遍历扩展名），再查
  /// Kodi 电影约定的 `<片名>-poster.<ext>`。
  static File? _findPoster(
      Map<String, File> filesByLowerName, String baseName) {
    final List<String> candidates = <String>[];
    for (final String stem in _posterStems) {
      for (final String ext in _imageExts) {
        candidates.add('$stem$ext');
      }
    }
    final String lowerBase = baseName.toLowerCase();
    for (final String ext in _imageExts) {
      candidates.add('$lowerBase-poster$ext');
    }
    for (final String name in candidates) {
      final File? hit = filesByLowerName[name];
      if (hit != null) {
        return hit;
      }
    }
    return null;
  }

  /// 按优先序查找并解析 NFO；非法 XML 直接跳过该文件不抛出。
  static Future<_NfoData> _findAndParseNfo(
    Map<String, File> filesByLowerName,
    String baseName,
  ) async {
    final List<String> candidates = <String>[
      '${baseName.toLowerCase()}.nfo', // 与视频同名（最具体）。
      'tvshow.nfo', // 剧集目录级。
      'movie.nfo', // 电影通用名。
    ];
    for (final String name in candidates) {
      final File? file = filesByLowerName[name];
      if (file == null) {
        continue;
      }
      final _NfoData? data = await _parseNfo(file);
      if (data != null) {
        return data;
      }
    }
    return const _NfoData();
  }

  /// 解析单个 NFO 文件；读取失败 / 非法 XML 返回 null（由调用方跳过）。
  static Future<_NfoData?> _parseNfo(File file) async {
    late final String content;
    try {
      content = await file.readAsString();
    } on FileSystemException {
      return null;
    }
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(content);
    } on XmlException {
      return null; // 非法 XML：忽略该文件。
    }

    final String? title = _firstElementText(doc, 'title');
    final int? year = _parseInt(_firstElementText(doc, 'year'));
    final String? tmdbId = _findTmdbId(doc);

    return _NfoData(title: title, year: year, tmdbId: tmdbId);
  }

  /// 取首个 `<name>` 元素的去空白文本；无则 null。
  static String? _firstElementText(XmlDocument doc, String name) {
    for (final XmlElement el in doc.findAllElements(name)) {
      final String text = el.innerText.trim();
      if (text.isNotEmpty) {
        return text;
      }
    }
    return null;
  }

  /// 优先 `<uniqueid type="tmdb">`（type 大小写不敏感），回退旧式 `<tmdbid>`。
  static String? _findTmdbId(XmlDocument doc) {
    for (final XmlElement el in doc.findAllElements('uniqueid')) {
      final String? type = el.getAttribute('type');
      if (type != null && type.toLowerCase() == 'tmdb') {
        final String text = el.innerText.trim();
        if (text.isNotEmpty) {
          return text;
        }
      }
    }
    return _firstElementText(doc, 'tmdbid');
  }

  /// 宽松整数解析：null / 非数字返回 null。
  static int? _parseInt(String? raw) {
    if (raw == null) {
      return null;
    }
    return int.tryParse(raw.trim());
  }
}

/// NFO 解析中间结果（内部值对象）。
class _NfoData {
  const _NfoData({this.title, this.year, this.tmdbId});

  final String? title;
  final int? year;
  final String? tmdbId;
}
