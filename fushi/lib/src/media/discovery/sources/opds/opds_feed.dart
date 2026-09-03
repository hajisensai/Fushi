/// OPDS 目录的**协议无关**归一化模型。
///
/// OPDS 有两个在野版本：1.2 是 Atom XML（Calibre-Web / BookOrbit / KOReader 生态），
/// 2.0 是 JSON（Kavita 0.8+）。两者的**语义**完全一致——导航条目、出版物条目、
/// 下一页、搜索模板——只有序列化不同。所以两个解析器都产出本文件的模型，
/// 「OPDS → `DiscoveryEntry`」那一层只写一遍（`opds_discovery_source.dart`）。
///
/// 不把 `DiscoveryEntry` 直接当解析产物，是因为那样两个解析器各自都要懂
/// payload/kind/文件名推导，同一套规则写两遍必然漂移——而漂移的那一份
/// 只在「用户恰好用了另一种服务端」时才暴露。
library;

import 'package:fushi/src/media/discovery/discovery_models.dart';

/// OPDS 供给的文件类型：MIME ↔ 落盘扩展名 ↔ 本仓媒体域的**唯一真相源**。
///
/// 为什么必须有扩展名这一列：OPDS 的下载直链普遍不带扩展名
/// （BookOrbit 是 `/api/v1/opds/download/<id>`，Komga 是 `/api/v1/books/<id>/file`），
/// 而下载队列的 `_resolveFileName` 只会 payload.fileName → URL 末段 → 标题，
/// **不读 `Content-Disposition`**。不由本表反推扩展名，落盘就是个无后缀的
/// `download`，`classifyDiscoveryFile` 一律判 `unknownFileType`——
/// 表现为「下载进度跑到 100% 然后导入失败」。
///
/// [importable] 标记本仓当前**导入器**是否吃得下该格式（不是「能不能下载」）：
/// `.mobi`/`.azw3`/`.fb2` 能下载但进不了书架。它只用于**同一条目多格式时的择优**，
/// 不用于隐藏条目——只供 mobi 的书库如果被整个滤掉，用户看到的是「空目录」，
/// 比「下下来读不了」更难排查。
enum OpdsFileType {
  epub(
    mediaType: 'application/epub+zip',
    extension: '.epub',
    kind: DiscoveryMediaKind.novel,
    importable: true,
  ),
  pdf(
    mediaType: 'application/pdf',
    extension: '.pdf',
    kind: DiscoveryMediaKind.novel,
    importable: true,
  ),
  plainText(
    mediaType: 'text/plain',
    extension: '.txt',
    kind: DiscoveryMediaKind.novel,
    importable: true,
  ),
  cbz(
    mediaType: 'application/vnd.comicbook+zip',
    extension: '.cbz',
    kind: DiscoveryMediaKind.manga,
    importable: true,
  ),
  cbr(
    mediaType: 'application/vnd.comicbook-rar',
    extension: '.cbr',
    kind: DiscoveryMediaKind.manga,
    importable: true,
  ),
  mobi(
    mediaType: 'application/x-mobipocket-ebook',
    extension: '.mobi',
    kind: DiscoveryMediaKind.novel,
    importable: false,
  ),
  azw3(
    mediaType: 'application/vnd.amazon.ebook',
    extension: '.azw3',
    kind: DiscoveryMediaKind.novel,
    importable: false,
  ),
  fb2(
    mediaType: 'text/fb2+xml',
    extension: '.fb2',
    kind: DiscoveryMediaKind.novel,
    importable: false,
  );

  const OpdsFileType({
    required this.mediaType,
    required this.extension,
    required this.kind,
    required this.importable,
  });

  /// 规范 MIME。
  final String mediaType;

  /// 落盘必须带上的扩展名（含点）。
  final String extension;

  final DiscoveryMediaKind kind;

  /// 本仓导入器当前是否支持该格式。
  final bool importable;

  /// 各服务端实际发出的 MIME 别名。规范值之外的这些是实测存在的写法：
  /// Komga 早期版本发 `application/x-cbz`，部分 Calibre 插件发
  /// `application/x-cbr`，FB2 有两种注册写法。
  ///
  /// 刻意用别名表而不是「模糊包含匹配」：`contains('zip')` 会把
  /// `application/epub+zip` 和 `application/vnd.comicbook+zip` 判成同一档，
  /// 于是漫画进小说域、epub 进漫画域——两边都错，且只在混合库里暴露。
  static const Map<String, OpdsFileType> _aliases = <String, OpdsFileType>{
    'application/x-cbz': OpdsFileType.cbz,
    'application/x-cbr': OpdsFileType.cbr,
    'application/vnd.comicbook+rar': OpdsFileType.cbr,
    'application/x-mobi8-ebook': OpdsFileType.azw3,
    'application/x-fictionbook+xml': OpdsFileType.fb2,
    'application/fb2+zip': OpdsFileType.fb2,
  };

  /// 按 MIME 定型。参数可带 `;` 参数段（`application/epub+zip;charset=utf-8`）
  /// 与大小写差异，一律先归一。无法识别返回 null。
  static OpdsFileType? fromMediaType(String? raw) {
    if (raw == null) return null;
    final String normalized = raw.split(';').first.trim().toLowerCase();
    if (normalized.isEmpty) return null;
    for (final OpdsFileType type in OpdsFileType.values) {
      if (type.mediaType == normalized) return type;
    }
    return _aliases[normalized];
  }

  /// 按文件扩展名定型（服务端没给 MIME、或给了 `application/octet-stream`
  /// 时的兜底：很多自建服务端的 acquisition 链接末段仍带真实文件名）。
  static OpdsFileType? fromPath(String? path) {
    if (path == null) return null;
    final int dot = path.lastIndexOf('.');
    if (dot < 0) return null;
    final String ext = path.substring(dot).toLowerCase();
    for (final OpdsFileType type in OpdsFileType.values) {
      if (type.extension == ext) return type;
    }
    return null;
  }
}

/// acquisition 链接的 `rel` 语义。
///
/// 只有 [openAccess] 与 [generic] 是「点了就能拿到文件」；[borrow]/[buy]/
/// [subscribe] 指向的是**交易流程页**（OPDS 规范的付费/借阅扩展），把它们
/// 当直链下载下来只会得到一个 HTML 错误页并以「导入失败」收场。自建服务端
/// 通常只发前两种，但公共目录（如 Feedbooks、Standard Ebooks 的付费镜像）会发后几种。
enum OpdsAcquisitionRel {
  generic('http://opds-spec.org/acquisition'),
  openAccess('http://opds-spec.org/acquisition/open-access'),
  borrow('http://opds-spec.org/acquisition/borrow'),
  buy('http://opds-spec.org/acquisition/buy'),
  sample('http://opds-spec.org/acquisition/sample'),
  subscribe('http://opds-spec.org/acquisition/subscribe');

  const OpdsAcquisitionRel(this.rel);

  final String rel;

  /// 是否是「直接可下载」的 rel。
  bool get isDirectDownload =>
      this == OpdsAcquisitionRel.generic ||
      this == OpdsAcquisitionRel.openAccess ||
      this == OpdsAcquisitionRel.sample;

  static OpdsAcquisitionRel? fromRel(String? raw) {
    if (raw == null) return null;
    final String normalized = raw.trim().toLowerCase();
    for (final OpdsAcquisitionRel value in OpdsAcquisitionRel.values) {
      if (value.rel == normalized) return value;
    }
    return null;
  }
}

/// 一条 acquisition 链接（[href] 已 resolve 成绝对 URL）。
class OpdsAcquisitionLink {
  const OpdsAcquisitionLink({
    required this.href,
    required this.rel,
    this.fileType,
    this.sizeBytes,
  });

  final String href;
  final OpdsAcquisitionRel rel;

  /// null = MIME 与扩展名都认不出来。仍可下载，但落盘没有可靠扩展名。
  final OpdsFileType? fileType;

  final int? sizeBytes;
}

/// 目录里的一个条目：导航（可下钻）或出版物（可下载）。
///
/// 与 `DiscoveryEntry` 同构的 sealed 两分——这不是巧合，OPDS 的
/// navigation/acquisition feed 二分本来就是这个形状。
sealed class OpdsEntry {
  const OpdsEntry({required this.title});

  final String title;
}

/// 导航条目：点进去继续 browse [href]。
final class OpdsNavigationEntry extends OpdsEntry {
  const OpdsNavigationEntry({
    required super.title,
    required this.href,
    this.summary,
    this.itemCount,
  });

  /// 已 resolve 成绝对 URL 的子目录地址。
  final String href;

  final String? summary;

  /// 服务端声明的直属条目数（`opds:facetGroup`/2.0 的 `numberOfItems`）。
  final int? itemCount;
}

/// 出版物条目：一本书/一卷漫画，带一到多条 acquisition 链接。
final class OpdsPublicationEntry extends OpdsEntry {
  OpdsPublicationEntry({
    required super.title,
    required this.id,
    required Iterable<OpdsAcquisitionLink> links,
    this.author,
    this.summary,
    this.updatedText,
    this.coverHref,
  }) : links = List<OpdsAcquisitionLink>.unmodifiable(links);

  /// 源内稳定身份（Atom `<id>` / 2.0 `metadata.identifier`；都缺时退回首条
  /// acquisition href——它至少在同一目录内唯一）。
  final String id;

  final List<OpdsAcquisitionLink> links;

  final String? author;
  final String? summary;

  /// 展示用的发布/更新时间**原文**，不解析成 DateTime——各服务端格式与时区
  /// 不一，解析只会制造错序假象（沿用 `DiscoveryResourceItem.dateText` 的既定口径）。
  final String? updatedText;

  /// 封面直链（已 resolve）。私有目录的封面同样需要认证头才取得到。
  final String? coverHref;

  /// 在[允许的域]内挑一条最该下载的链接。
  ///
  /// 择优顺序：能下载的 rel 优先 → 落在 [kind] 域内 → 本仓导入器吃得下
  /// → 表内声明顺序（epub 先于 pdf 先于 txt）。返回 null 表示这条出版物
  /// 在该域下没有可下载物（例如纯 mobi 的书在 manga 域下查询）。
  OpdsAcquisitionLink? bestLinkFor(DiscoveryMediaKind kind) {
    OpdsAcquisitionLink? best;
    int bestScore = -1;
    for (final OpdsAcquisitionLink link in links) {
      if (!link.rel.isDirectDownload) continue;
      final OpdsFileType? type = link.fileType;
      if (type == null || type.kind != kind) continue;
      // 分数越大越优先：importable 是硬门（+100），其余按枚举声明序倒排，
      // 让 epub(0) 得分高于 pdf(1) 高于 txt(2)。
      final int score = (type.importable ? 100 : 0) +
          (OpdsFileType.values.length - type.index);
      if (score > bestScore) {
        bestScore = score;
        best = link;
      }
    }
    return best;
  }

  /// 本条目覆盖到的所有媒体域（一条 OPDS 条目可能同时供 epub 与 cbz）。
  Set<DiscoveryMediaKind> get kinds => <DiscoveryMediaKind>{
        for (final OpdsAcquisitionLink link in links)
          if (link.rel.isDirectDownload && link.fileType != null)
            link.fileType!.kind,
      };
}

/// 一页 OPDS 目录。
class OpdsFeed {
  OpdsFeed({
    Iterable<OpdsEntry> entries = const <OpdsEntry>[],
    this.nextHref,
    this.searchTemplate,
    this.searchDescriptionHref,
  }) : entries = List<OpdsEntry>.unmodifiable(entries);

  final List<OpdsEntry> entries;

  /// `rel="next"` 的绝对 URL；null = 没有下一页。
  ///
  /// OPDS 的分页是**链接驱动**（服务端给下一页地址），不是页码驱动。
  /// 自己拼 `?page=N` 在多数服务端上无效或语义不同。
  final String? nextHref;

  /// 可直接替换的搜索模板（含 `{searchTerms}` 或 `{?query}`）。
  /// 1.2 里通常要经 [searchDescriptionHref] 二次抓取才拿得到；
  /// 2.0 的 `rel="search"` + `templated: true` 直接就是模板。
  final String? searchTemplate;

  /// OpenSearch 描述文档地址（1.2 专有）。
  final String? searchDescriptionHref;
}
