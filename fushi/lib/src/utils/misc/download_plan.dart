import 'package:flutter/foundation.dart';

/// 一片数据的**一个来源**。
///
/// [remoteOffset] 是「本片的第一个字节，在该 URL 所指资源内部的偏移」——这一个字段
/// 就把两种分发形态收成同一个结构，消费端不需要 mode 分支：
///
/// - **整包 + HTTP Range**（服务端零改动）：URL 指向完整包，[remoteOffset] == 本片在
///   目标文件中的偏移。取本片就是 `Range: bytes=<remoteOffset>-<remoteOffset+len-1>`。
/// - **物理切片**（分片撒在多主机）：URL 指向切好的那一片，[remoteOffset] == 0。
///   取本片就是整个资源。
///
/// 同一片可以同时挂两种来源（CF 整包 + GitHub 切片互为镜像），失败时轮换。
@immutable
class DownloadSource {
  const DownloadSource({required this.url, this.remoteOffset = 0})
      : assert(remoteOffset >= 0, 'remoteOffset 不能为负');

  final String url;

  /// 本片首字节在该 URL 资源内的偏移；整包来源为该片的绝对偏移，切片来源为 0。
  final int remoteOffset;

  @override
  bool operator ==(Object other) =>
      other is DownloadSource &&
      other.url == url &&
      other.remoteOffset == remoteOffset;

  @override
  int get hashCode => Object.hash(url, remoteOffset);

  @override
  String toString() => 'DownloadSource($url @$remoteOffset)';
}

/// 目标文件的一片：写到目标文件 [offset] 处的 [length] 个字节。
///
/// [sha256] 可选，只有物理切片清单能给出（Range 模式无法预先知道每片摘要）；给出时
/// 边下边算、单片校验失败只重下该片，不用等整包下完才发现坏了。
@immutable
class DownloadPart {
  const DownloadPart({
    required this.index,
    required this.offset,
    required this.length,
    required this.sources,
    this.sha256,
  })  : assert(offset >= 0, 'offset 不能为负'),
        assert(length > 0, 'length 必须为正');

  final int index;

  /// 本片在**目标文件**中的起始偏移。
  final int offset;
  final int length;

  /// 可用来源，按序轮换（首个为首选）。
  final List<DownloadSource> sources;

  /// 本片内容的 sha256（小写 hex），可选。
  final String? sha256;

  /// 本片的结束偏移（**独占**）。
  int get end => offset + length;

  @override
  String toString() => 'DownloadPart(#$index $offset+$length)';
}

/// 分片下载计划：一个目标文件 + 一组互不重叠、恰好铺满 `[0, totalBytes)` 的片。
///
/// 构造时校验铺砖（[_validateTiling]）：有缝或重叠都会当场抛 [ArgumentError]，而不是
/// 下完 9.5 GB 才在 sha256 上发现包是坏的。
@immutable
class DownloadPlan {
  DownloadPlan({
    required this.totalBytes,
    required this.parts,
    this.sha256,
    this.version,
  }) {
    _validateTiling(totalBytes, parts);
  }

  /// 整包 + Range 模式：把 [totalBytes] 按 [partSize] 切段，每段挂上全部 [urls]。
  ///
  /// 服务端零改动——只要主机支持 Range，现有直链立刻能并发下载。
  factory DownloadPlan.ranged({
    required List<String> urls,
    required int totalBytes,
    required int partSize,
    String? sha256,
    String? version,
  }) {
    if (urls.isEmpty) {
      throw ArgumentError.value(urls, 'urls', '至少要有一个来源');
    }
    if (totalBytes <= 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', '必须为正');
    }
    if (partSize <= 0) {
      throw ArgumentError.value(partSize, 'partSize', '必须为正');
    }
    final List<DownloadPart> parts = <DownloadPart>[];
    int offset = 0;
    int index = 0;
    while (offset < totalBytes) {
      final int length =
          offset + partSize > totalBytes ? totalBytes - offset : partSize;
      parts.add(DownloadPart(
        index: index,
        offset: offset,
        length: length,
        sources: <DownloadSource>[
          for (final String url in urls)
            DownloadSource(url: url, remoteOffset: offset),
        ],
      ));
      offset += length;
      index += 1;
    }
    return DownloadPlan(
      totalBytes: totalBytes,
      parts: parts,
      sha256: sha256,
      version: version,
    );
  }

  /// 单流退化计划：整个文件一片。服务器不支持 Range 时的兜底形态，让消费端仍然
  /// 只认识 [DownloadPlan] 一种输入。
  factory DownloadPlan.single({
    required List<String> urls,
    required int totalBytes,
    String? sha256,
    String? version,
  }) =>
      DownloadPlan.ranged(
        urls: urls,
        totalBytes: totalBytes,
        partSize: totalBytes,
        sha256: sha256,
        version: version,
      );

  /// 目标文件总字节数。
  final int totalBytes;

  final List<DownloadPart> parts;

  /// 整包 sha256（小写 hex，可选）。每片都带 [DownloadPart.sha256] 时，逐片校验已
  /// 严格强于整包校验，消费端可跳过整包重读。
  final String? sha256;

  /// 包版本标识（清单里的 `version`）。进度文件靠它判断「服务端换包了」。
  final String? version;

  /// 是否每片都带摘要——是则无需整包重读校验。
  bool get hasPerPartDigests =>
      parts.isNotEmpty && parts.every((DownloadPart p) => p.sha256 != null);

  static void _validateTiling(int totalBytes, List<DownloadPart> parts) {
    if (totalBytes <= 0) {
      throw ArgumentError.value(totalBytes, 'totalBytes', '必须为正');
    }
    if (parts.isEmpty) {
      throw ArgumentError.value(parts, 'parts', '不能为空');
    }
    final List<DownloadPart> sorted = <DownloadPart>[...parts]
      ..sort((DownloadPart a, DownloadPart b) => a.offset.compareTo(b.offset));
    int expected = 0;
    for (final DownloadPart part in sorted) {
      if (part.sources.isEmpty) {
        throw ArgumentError('片 #${part.index} 没有任何来源');
      }
      if (part.offset != expected) {
        throw ArgumentError(
          '分片不连续：期望 offset=$expected，实到 ${part.offset}'
          '（片 #${part.index}）',
        );
      }
      expected = part.end;
    }
    if (expected != totalBytes) {
      throw ArgumentError(
        '分片总长 $expected 与 totalBytes $totalBytes 不符',
      );
    }
    final Set<int> indices = parts.map((DownloadPart p) => p.index).toSet();
    if (indices.length != parts.length) {
      throw ArgumentError('片 index 重复');
    }
  }
}
