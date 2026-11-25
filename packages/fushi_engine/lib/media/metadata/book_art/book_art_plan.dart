/// 每卷封面 / 横幅的取图规则（纯函数，无 IO）：清晰度优先（所有者拍板「高清优先」）。
///
/// - 每卷候选：MangaBaka 的 ja 卷封面（同卷多张时先挑常规版、安全分级，再比面积）与
///   Bangumi 单行本封面；取**像素面积最大**的，面积相同选 MangaBaka。
/// - 与本地内嵌封面比：刮来的图面积大于本地 [kBookArtSharperFactor] 倍才写；本地没有
///   封面时直接写；本地有封面但量不出尺寸、或刮来的图尺寸未知时不写（证明不了更清晰）；
/// - 与刮削层里已有的同系列那张比：不更大就保留已有的（[BookArtVolumeOutcome.kept]）。
/// - 横幅优先 MangaBaka：宽高比 ≥ [kBookArtBannerMinAspect] 的里取面积最大；MangaBaka
///   没有时回落 AniList 的 `bannerImage`（见 anilist_banner.dart）。
library;

import 'dart:typed_data';

import 'package:fushi_engine/media/metadata/book_art/book_art_matcher.dart';
import 'package:fushi_engine/media/metadata/mangabaka/mangabaka_models.dart';
import 'package:fushi_engine/models/content_language.dart';
import 'package:image/image.dart' as img;

/// 刮来的图要比本地大这么多倍（面积）才替换。
const double kBookArtSharperFactor = 1.2;

/// 横幅最小宽高比（探针里有 2000×800 与 800×450）。
const double kBookArtBannerMinAspect = 1.6;

/// 下载图片的格式白名单（源站给的 `image.raw.format`）。
const Set<String> kBookArtImageFormats = <String>{'jpeg', 'jpg', 'png', 'webp'};

/// 单张图片字节上限（源站给的 `image.raw.size`）。
const int kBookArtMaxImageBytes = 20 * 1024 * 1024;

/// MangaBaka 那张短边低于它时，才额外量 Bangumi 那张的尺寸（控制请求数）。
const int kBookArtProbeShortSide = 1000;

/// 封面 / 横幅来源。系列匹配与钉死只用 [mangabaka] / [bangumi]（[seriesSources]）；
/// [anilist] 只出横幅。
enum BookArtSource {
  mangabaka('mangabaka'),
  bangumi('bangumi'),
  anilist('anilist');

  const BookArtSource(this.wire);

  /// 落盘元数据 / ops 线上形状里的名字。
  final String wire;

  /// 能匹配 / 钉死系列的源。
  static const List<BookArtSource> seriesSources = <BookArtSource>[
    mangabaka,
    bangumi,
  ];

  static BookArtSource? tryParse(String? raw) {
    for (final BookArtSource s in values) {
      if (s.wire == raw) return s;
    }
    return null;
  }

  /// 只认能匹配系列的源（钉死请求 / 刮削层记的系列源）。
  static BookArtSource? tryParseSeries(String? raw) {
    final BookArtSource? s = tryParse(raw);
    return s != null && seriesSources.contains(s) ? s : null;
  }
}

/// 一张候选图。
class BookArtImageOption {
  const BookArtImageOption({
    required this.source,
    required this.url,
    this.width,
    this.height,
  });

  final BookArtSource source;
  final String url;
  final int? width;
  final int? height;

  bool get hasSize => (width ?? 0) > 0 && (height ?? 0) > 0;
  int get area => (width ?? 0) * (height ?? 0);
  int get shortSide {
    final int w = width ?? 0;
    final int h = height ?? 0;
    return w < h ? w : h;
  }

  BookArtImageOption withSize(int? width, int? height) => BookArtImageOption(
    source: source,
    url: url,
    width: width,
    height: height,
  );
}

int _ratingRank(String rating) => switch (rating) {
  'safe' => 0,
  'suggestive' => 1,
  _ => 99,
};

bool _downloadable(MangaBakaRawImage raw) {
  final String? format = raw.format;
  if (format != null && !kBookArtImageFormats.contains(format)) return false;
  final int? size = raw.size;
  return size == null || size <= kBookArtMaxImageBytes;
}

/// 把 MangaBaka 图片列表按卷号分组，每卷挑一张：只看 `type=volume`、[language]
/// 版（按主语言子标签比：`zh` 收 `zh` / `zh-tw` / `zh-hk`，默认日文版）、白名单
/// 格式与大小；分级 safe 优先于 suggestive（erotica / pornographic 不要）；常规版
/// （`note == null`）优先于变体；最后比面积。别的语言版本的封面一律不选（BUG-5287）。
Map<num, MangaBakaImage> pickMangaBakaVolumeImages(
  Iterable<MangaBakaImage> images, {
  String language = 'ja',
}) {
  final Map<num, MangaBakaImage> best = <num, MangaBakaImage>{};
  for (final MangaBakaImage image in images) {
    final num? index = image.indexNumeric;
    if (index == null ||
        image.type != 'volume' ||
        contentLanguageKey(image.language) != language ||
        _ratingRank(image.contentRating) > 1 ||
        !_downloadable(image.raw)) {
      continue;
    }
    final num key = best.keys.firstWhere(
      (num k) => bookArtHasVolume(<num>[k], index),
      orElse: () => index,
    );
    final MangaBakaImage? current = best[key];
    if (current == null || _betterVolumeImage(image, current)) {
      best[key] = image;
    }
  }
  return best;
}

bool _betterVolumeImage(MangaBakaImage a, MangaBakaImage b) {
  final int ra = _ratingRank(a.contentRating);
  final int rb = _ratingRank(b.contentRating);
  if (ra != rb) return ra < rb;
  final bool na = a.note == null;
  final bool nb = b.note == null;
  if (na != nb) return na;
  return a.raw.area > b.raw.area;
}

/// MangaBaka 卷图 → 候选图。
BookArtImageOption mangaBakaOption(MangaBakaImage image) => BookArtImageOption(
  source: BookArtSource.mangabaka,
  url: image.raw.url,
  width: image.raw.width,
  height: image.raw.height,
);

/// 是否需要额外量 Bangumi 那张的尺寸：MangaBaka 缺这一卷，或那张短边不足。
bool bookArtNeedsBangumiProbe(BookArtImageOption? mangaBaka) =>
    mangaBaka == null ||
    !mangaBaka.hasSize ||
    mangaBaka.shortSide < kBookArtProbeShortSide;

/// 一卷的取图结论。
enum BookArtVolumeOutcome {
  /// 写入 [BookArtVolumeChoice.option]。
  write,

  /// 本地内嵌封面更清晰（或证明不了刮来的更清晰），保留本地。
  localSharper,

  /// 两个源都没有这一卷。
  noCandidate,

  /// 刮削层里已有的那张（同一系列）不比候选差：不重下、不降清晰度。
  kept,
}

class BookArtVolumeChoice {
  const BookArtVolumeChoice(this.outcome, [this.option]);

  final BookArtVolumeOutcome outcome;
  final BookArtImageOption? option;
}

/// 一卷选图：[mangaBaka] / [bangumi] 里面积最大的（Bangumi 尺寸未知时只在 MangaBaka
/// 缺图时用它），再比两道「高清优先」的闸：
/// - [keptArea]：刮削层里已有、且仍属同一系列的那张卷封面面积。候选不比它大 → [kept]
///   （重刮时 MangaBaka 被限流回落 Bangumi，不拿小图换掉已有的原图）；
/// - [localArea]：本地内嵌封面面积（null = 没有封面）。[localUnmeasured] = 有封面但
///   量不出尺寸：证明不了刮来的更清晰，按本地更清晰处理，**不**当成「没有封面」。
BookArtVolumeChoice chooseBookArtVolume({
  BookArtImageOption? mangaBaka,
  BookArtImageOption? bangumi,
  int? localArea,
  bool localUnmeasured = false,
  int? keptArea,
}) {
  BookArtImageOption? pick = mangaBaka;
  if (bangumi != null) {
    if (pick == null) {
      pick = bangumi;
    } else if (bangumi.hasSize && bangumi.area > pick.area) {
      pick = bangumi;
    }
  }
  if (pick == null) {
    return const BookArtVolumeChoice(BookArtVolumeOutcome.noCandidate);
  }
  if (keptArea != null &&
      keptArea > 0 &&
      (!pick.hasSize || pick.area <= keptArea)) {
    return const BookArtVolumeChoice(BookArtVolumeOutcome.kept);
  }
  if (localUnmeasured) {
    return const BookArtVolumeChoice(BookArtVolumeOutcome.localSharper);
  }
  if (localArea == null || localArea <= 0) {
    return BookArtVolumeChoice(BookArtVolumeOutcome.write, pick);
  }
  if (!pick.hasSize || pick.area <= localArea * kBookArtSharperFactor) {
    return const BookArtVolumeChoice(BookArtVolumeOutcome.localSharper);
  }
  return BookArtVolumeChoice(BookArtVolumeOutcome.write, pick);
}

/// 横幅：`type=banner`、不限语言、分级 ≤ suggestive、白名单格式；宽高比
/// ≥ [kBookArtBannerMinAspect] 的取面积最大，没有返回 null。
BookArtImageOption? pickMangaBakaBanner(Iterable<MangaBakaImage> images) {
  MangaBakaImage? best;
  for (final MangaBakaImage image in images) {
    final int w = image.raw.width ?? 0;
    final int h = image.raw.height ?? 0;
    if (image.type != 'banner' ||
        _ratingRank(image.contentRating) > 1 ||
        !_downloadable(image.raw) ||
        w <= 0 ||
        h <= 0 ||
        w / h < kBookArtBannerMinAspect) {
      continue;
    }
    if (best == null || image.raw.area > best.raw.area) best = image;
  }
  return best == null
      ? null
      : BookArtImageOption(
          source: BookArtSource.mangabaka,
          url: best.raw.url,
          width: best.raw.width,
          height: best.raw.height,
        );
}

/// PNG 签名（8 字节）。
const List<int> _pngSignature = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
];

/// PNG 宽高在 IHDR 块的固定偏移（16..24，大端）：直接读，不走解码器。`image` 包的
/// PNG `startDecode` 要扫完整个文件的块，只给文件头时（大 PNG 的前 256 KB）量不出。
({int width, int height})? _pngDimensions(List<int> bytes) {
  if (bytes.length < 24) return null;
  for (int i = 0; i < _pngSignature.length; i++) {
    if (bytes[i] != _pngSignature[i]) return null;
  }
  // 12..16 必须是 IHDR。
  if (bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return null;
  }
  int be32(int o) =>
      (bytes[o] << 24) |
      (bytes[o + 1] << 16) |
      (bytes[o + 2] << 8) |
      bytes[o + 3];
  final int w = be32(16);
  final int h = be32(20);
  if (w <= 0 || h <= 0) return null;
  return (width: w, height: h);
}

/// 从图片字节（可以只是文件头）读宽高；认不出返回 null。
({int width, int height})? bookArtImageDimensions(List<int> bytes) {
  if (bytes.isEmpty) return null;
  final ({int width, int height})? png = _pngDimensions(bytes);
  if (png != null) return png;
  try {
    final Uint8List data = bytes is Uint8List
        ? bytes
        : Uint8List.fromList(bytes);
    final img.Decoder? decoder = img.findDecoderForData(data);
    final img.DecodeInfo? info = decoder?.startDecode(data);
    if (info == null || info.width <= 0 || info.height <= 0) return null;
    return (width: info.width, height: info.height);
  } catch (_) {
    // 截断的文件头 / 非图片：量不出就是 null，调用方按「尺寸未知」处理。
    return null;
  }
}

/// MangaBaka 系列 → 匹配候选（作者与作画都算作者证据）。
BookArtCandidate mangaBakaCandidate(MangaBakaSeries series) => BookArtCandidate(
  source: BookArtSource.mangabaka.wire,
  id: '${series.id}',
  displayTitle: series.displayTitle,
  titles: series.comparableTitles,
  kind: mangaBakaKind(series.type),
  authors: <String>[...series.authors, ...series.artists],
  finalVolume: series.finalVolume,
  isAdult: series.isAdult,
);
