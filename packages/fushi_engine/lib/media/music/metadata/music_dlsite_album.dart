/// 音声 / ASMR 专辑的 DLsite 资料（拍板台 NCzkl6oLnf）：按专辑认 DLsite 作品编号、
/// 原始响应快照的编解码、界面语言 → DLsite 请求区域。
///
/// 身份只认**作品编号**（`RJ01109339` 一类）：DLsite 的下载包几乎都以编号命名文件夹，
/// 编号是精确键，不做按名模糊搜（同名音声作品太多，猜错了比没有更糟）。
///
/// 快照落 `music_metadata_raw_snapshots`（provider = `dlsite`，kind = `work`，
/// externalId = 作品编号）：存的是 product.json / 评分端点的**原始响应体**，读侧用
/// `dlsite_client.dart` 的解析器现解——解析器修好后旧快照不用重取就能受益。
/// 这张表是设备本地、可重建的缓存，不进同步。
library;

import 'dart:convert';

import 'package:fushi_engine/media/metadata/dlsite/dlsite_client.dart';

/// `music_metadata_raw_snapshots.snapshot_kind`（DLsite 作品）。冻结。
const String kMusicDlsiteSnapshotKind = 'work';

/// 快照格式版本（编码结构变了才加）。
const int kMusicDlsiteSnapshotVersion = 1;

/// 往上找编号的目录层数（曲目文件本身算第 0 层）。音声包常见结构是
/// `RJxxxx 标题/mp3/本編/01.mp3`，4 层覆盖「作品目录/格式/分类/文件」。
const int kMusicDlsiteMaxPathDepth = 4;

/// 一张专辑对应的 DLsite 作品编号；认不出（或多个编号互相矛盾）返回 null。
///
/// 顺序：目录编号（catalog no. 本身就是编号）→ 专辑名里带的编号 → 各曲目路径
/// （每首从文件名往上找最近的一个编号）。曲目路径给出**不止一个**编号说明这张
/// 「专辑」是按标签把几部作品并在一起了，不猜，返回 null。
DlsiteWorkId? musicAlbumDlsiteWorkId({
  required String title,
  String? catalogNo,
  Iterable<String> trackPaths = const <String>[],
}) {
  final String? catalog = catalogNo?.trim();
  if (catalog != null && catalog.isNotEmpty) {
    final DlsiteWorkId? id =
        DlsiteWorkId.tryParse(catalog) ?? DlsiteWorkId.findIn(catalog);
    if (id != null) return id;
  }
  final DlsiteWorkId? fromTitle = DlsiteWorkId.findIn(title);
  if (fromTitle != null) return fromTitle;
  DlsiteWorkId? found;
  for (final String path in trackPaths) {
    final DlsiteWorkId? id = _nearestWorkIdInPath(path);
    if (id == null) continue;
    if (found == null) {
      found = id;
    } else if (found != id) {
      return null;
    }
  }
  return found;
}

DlsiteWorkId? _nearestWorkIdInPath(String path) {
  final List<String> parts = path
      .split(RegExp(r'[\\/]'))
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);
  int depth = 0;
  for (int i = parts.length - 1; i >= 0; i--) {
    if (depth > kMusicDlsiteMaxPathDepth) break;
    final DlsiteWorkId? id = DlsiteWorkId.findIn(parts[i]);
    if (id != null) return id;
    depth++;
  }
  return null;
}

/// 界面语言 → DLsite 请求区域（影响标签 / 作品类型名的语言；标题始终是原文）。
/// DLsite 只有日 / 英 / 简中 / 繁中 / 韩五种，其余语言取日文原文。
String dlsiteLocaleFor(String languageCode, {String? countryCode}) {
  final String lang = languageCode.toLowerCase();
  final String country = (countryCode ?? '').toUpperCase();
  return switch (lang) {
    'zh' when country == 'TW' || country == 'HK' || country == 'MO' => 'zh_TW',
    'zh' => 'zh_CN',
    'en' => 'en_US',
    'ko' => 'ko_KR',
    _ => 'ja_JP',
  };
}

/// 一次取数的原始响应 → 快照 JSON。[ratingBody] 为 null = 评分端点没取到（不影响主数据）。
String encodeMusicDlsiteSnapshot({
  required String productBody,
  String? ratingBody,
  required String locale,
}) => jsonEncode(<String, Object?>{
  'v': kMusicDlsiteSnapshotVersion,
  'locale': locale,
  'product': productBody,
  'rating': ratingBody,
});

/// 解开的 DLsite 快照。
class MusicDlsiteSnapshot {
  const MusicDlsiteSnapshot({
    required this.id,
    required this.work,
    required this.locale,
  });

  final DlsiteWorkId id;

  /// null = DLsite 上查无此作（取过、确认没有，不再自动重取）。
  final DlsiteWork? work;

  /// 取数时的请求区域（界面语言换了，「刷新」会按新区域重取）。
  final String? locale;
}

/// [encodeMusicDlsiteSnapshot] 的逆。快照坏了（不是对象 / 响应体结构不对）返回 null，
/// 调用方按「没取过」处理。
MusicDlsiteSnapshot? decodeMusicDlsiteSnapshot(
  String rawJson,
  DlsiteWorkId id,
) {
  final Object? decoded;
  try {
    decoded = jsonDecode(rawJson);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) return null;
  final Object? product = decoded['product'];
  if (product is! String) return null;
  try {
    DlsiteWork? work = parseDlsiteProductJson(product, id);
    final Object? rating = decoded['rating'];
    if (work != null && rating is String) {
      try {
        work = work.withRating(parseDlsiteRatingJson(rating, id));
      } on DlsiteException {
        // 评分快照坏了不影响主数据。
      }
    }
    final Object? locale = decoded['locale'];
    return MusicDlsiteSnapshot(
      id: id,
      work: work,
      locale: locale is String ? locale : null,
    );
  } on DlsiteException {
    return null;
  }
}
