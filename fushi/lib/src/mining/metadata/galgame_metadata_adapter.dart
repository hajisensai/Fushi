/// galgame 元数据源 adapter 抽象接口（契约 §2.2）。
///
/// 新增数据源 = 实现本接口 + 在 `GalgameMetadataService` 的 registry 注册，搜索 / 合并 /
/// 展示 / 设置 UI 全自动支持。
library;

import 'package:fushi/src/mining/metadata/galgame_metadata_draft.dart';
import 'package:fushi/src/mining/metadata/galgame_metadata_source.dart';

/// 元数据抓取失败的统一异常。**绝不吞异常**：网络失败、非 2xx、JSON 畸形全部抛这个，
/// 由 service 决定降级（mixed 下单源失败降级为空）还是上抛给 UI（§2.5）。
class GalgameMetadataException implements Exception {
  const GalgameMetadataException(
    this.message, {
    this.source,
    this.statusCode,
  });

  /// 可读描述（英文技术信息 + 源名 + 状态码；UI 文案由展示层套 i18n 外壳）。
  final String message;

  /// 出问题的源，null = 与具体源无关。
  final GalgameMetadataSource? source;

  /// HTTP 状态码（非 2xx 时带上）；网络 / 解析异常为 null。
  final int? statusCode;

  @override
  String toString() {
    final String prefix = source == null ? '' : '[${source!.key}] ';
    final String suffix = statusCode == null ? '' : ' (HTTP $statusCode)';
    return 'GalgameMetadataException: $prefix$message$suffix';
  }
}

/// 单个数据源的抓取实现。
abstract class GalgameMetadataAdapter {
  /// 本 adapter 对应的源。
  GalgameMetadataSource get source;

  /// 判断一串用户输入是否本源的合法外部 ID（命中则跳过搜索直接 [fetchById]，§2.5）。
  bool validateId(String id);

  /// 该 ID 的网页外链（详情页「打开源站」按钮）。
  String externalUrl(String id);

  /// 按外部 ID 抓完整元数据。**未找到（404 / 空结果）返回 null**；网络或解析失败抛
  /// [GalgameMetadataException]。
  Future<GalgameMetadataDraft?> fetchById(String id);

  /// 按名称搜索候选；无命中返回空表（不是异常）。失败抛 [GalgameMetadataException]。
  Future<List<SourceCandidate>> searchByName(String name, {int limit});

  /// 释放内部 HTTP 资源。默认 no-op（契约 §2.2 未列此方法，但 adapter 持有 http.Client
  /// 就必须有回收口；默认实现保证已有实现不受影响）。
  void close() {}
}
