/// EPUB 包文档（OPF）里声明的系列归属，以及它在 `epub_books.sourceMetadata` 里的
/// 存法（反馈 n4KC1azJvw）。
///
/// 两种来源，优先级从高到低：
/// 1. EPUB 3：`<meta property="belongs-to-collection" id="c">系列名</meta>` +
///    `<meta refines="#c" property="collection-type">series</meta>` +
///    `<meta refines="#c" property="group-position">3</meta>`；
/// 2. Calibre / EPUB 2：`<meta name="calibre:series" content="系列名"/>` +
///    `<meta name="calibre:series_index" content="3.0"/>`；
/// 3. 没标 `collection-type` 的 `belongs-to-collection`（标成 `set` 等别的类型的
///    不算系列，那是丛书 / 套装）。
///
/// 书架系列归组（`BookSeriesGrouper`）优先认这里的系列名，标题启发式只在包里没有
/// 声明时兜底：每卷副标题各不相同、也没有结尾系列标签的作品（『ココロコネクト
/// ヒトランダム / キズランダム …』）只有这条路能归组。
library;

import 'dart:convert';

import 'package:xml/xml.dart';

/// 一本书声明的系列：系列名 + 卷序（可空，可带小数）。
class EpubSeries {
  const EpubSeries({required this.name, this.index});

  final String name;
  final num? index;

  @override
  bool operator ==(Object other) =>
      other is EpubSeries && other.name == name && other.index == index;

  @override
  int get hashCode => Object.hash(name, index);

  @override
  String toString() => 'EpubSeries($name, $index)';
}

/// `sourceMetadata` 里系列描述符的类型标记（写进用户库，永不改名）。
const String kEpubSeriesMetadataType = 'fushi-epub-series';

/// 编码成 `sourceMetadata`。[series] 为 null 也写一份（只有类型标记）：表示「读过
/// OPF、没有声明」，存量回填据此不再重复读这本书。
String encodeEpubSeriesMetadata(EpubSeries? series) =>
    jsonEncode(<String, Object?>{
      'type': kEpubSeriesMetadataType,
      if (series != null) 'name': series.name,
      if (series?.index != null) 'index': series!.index,
    });

/// 从 `sourceMetadata` 读系列；不是本描述符（null / 别的类型 / 坏 JSON）或没有声明
/// 系列时为 null。
EpubSeries? decodeEpubSeriesMetadata(String? sourceMetadata) {
  if (sourceMetadata == null) return null;
  final Object? value;
  try {
    value = jsonDecode(sourceMetadata);
  } on FormatException {
    return null;
  }
  if (value is! Map<String, dynamic> ||
      value['type'] != kEpubSeriesMetadataType) {
    return null;
  }
  final Object? name = value['name'];
  if (name is! String || name.trim().isEmpty) return null;
  final Object? index = value['index'];
  return EpubSeries(name: name.trim(), index: index is num ? index : null);
}

/// 按 local-name 匹配任意前缀（`<opf:meta>` 同样要认，见 `EpubParser._elements`）。
Iterable<XmlElement> _metas(XmlDocument opf) =>
    opf.findAllElements('meta', namespace: '*');

String? _attr(XmlElement el, String name) =>
    el.getAttribute(name) ?? el.getAttribute(name, namespace: '*');

/// `3`、`3.0`、` 2.5 ` → 3 / 3 / 2.5；读不出为 null。
num? _parseIndex(String? raw) {
  final num? n = num.tryParse((raw ?? '').trim());
  if (n == null || n.isNaN || n.isInfinite || n < 0) return null;
  return n == n.truncate() ? n.toInt() : n;
}

/// 从 OPF 文档解析系列声明；没有声明返回 null。
EpubSeries? parseEpubSeries(XmlDocument opf) {
  final List<XmlElement> metas = _metas(opf).toList(growable: false);
  final Map<String, Map<String, String>> refines =
      <String, Map<String, String>>{};
  for (final XmlElement m in metas) {
    final String? target = _attr(m, 'refines');
    final String? property = _attr(m, 'property');
    if (target == null || property == null) continue;
    refines.putIfAbsent(
      target.replaceFirst('#', ''),
      () => <String, String>{},
    )[property.trim()] = m.innerText
        .trim();
  }

  EpubSeries? untyped;
  for (final XmlElement m in metas) {
    if (_attr(m, 'property')?.trim() != 'belongs-to-collection') continue;
    final String name = m.innerText.trim();
    if (name.isEmpty) continue;
    final Map<String, String> r =
        refines[_attr(m, 'id') ?? ''] ?? const <String, String>{};
    final String? type = r['collection-type']?.toLowerCase();
    final EpubSeries series = EpubSeries(
      name: name,
      index: _parseIndex(r['group-position']),
    );
    if (type == 'series') return series;
    if (type == null || type.isEmpty) untyped ??= series;
  }

  String? calibreName;
  String? calibreIndex;
  for (final XmlElement m in metas) {
    final String? name = _attr(m, 'name')?.trim();
    if (name == 'calibre:series') calibreName ??= _attr(m, 'content')?.trim();
    if (name == 'calibre:series_index') {
      calibreIndex ??= _attr(m, 'content');
    }
  }
  if (calibreName != null && calibreName.isNotEmpty) {
    return EpubSeries(name: calibreName, index: _parseIndex(calibreIndex));
  }
  return untyped;
}
