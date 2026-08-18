/// 发现源契约：一个源 = 一个本类实现（nyaa / AList 站 / shinnku / Mihon 适配…）。
///
/// 加源零框架改动：实现本类 + 在组装点注册进 `MediaDiscoveryService` 即可。
/// 失败语义沿用全仓统一的 `ProviderBatchResult` / `ExternalProviderFailure`
/// （脱敏、部分成功），与视频发现/资源 provider 同一套，不再发明新错误形状。
library;

import 'package:fushi/src/media/discovery/discovery_models.dart';
import 'package:fushi/src/media/external_provider.dart';

abstract class MediaDiscoverySource {
  const MediaDiscoverySource();

  /// 稳定 id（持久化「默认源选择」「源开关」偏好用；改名即断档，别改）。
  String get id;

  /// UI 展示名（源站名，不走 i18n——站名没有译名）。
  String get displayName;

  /// 聚合展示顺序：小者靠前。
  int get priority;

  DiscoveryCapabilities get capabilities;

  /// 关键词搜索。[DiscoveryCapabilities.supportsSearch] 为 false 的源不会被调到。
  Future<ProviderBatchResult<DiscoveryResultPage>> search(
    DiscoveryRequest request,
  );

  /// 目录浏览（[DiscoveryRequest.path] null = 根）。默认不支持；目录型源
  /// （AList）覆写。声明了 [DiscoveryCapabilities.supportsBrowse] 却不覆写
  /// 本方法属于实现 bug，返回的 unsupported 失败会直接亮在源徽标上。
  Future<ProviderBatchResult<DiscoveryResultPage>> browse(
    DiscoveryRequest request,
  ) async {
    return ProviderBatchResult<DiscoveryResultPage>.failure(
      ExternalProviderFailure(
        providerId: id,
        operation: 'browse',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'source does not support directory browse',
      ),
    );
  }

  /// 下载前把条目物化成可执行 payload。默认直接返回列表阶段随条目带的
  /// payload；直链带临期签名、列表阶段给不出 URL 的源（AList `/api/fs/get`）
  /// 覆写本方法在**下载时**取直链——晚 resolve 是刻意的：早取的签名等到
  /// 用户点下载时可能已过期。
  Future<DiscoveryPayload> resolvePayload(DiscoveryResourceItem item) async {
    final DiscoveryPayload? payload = item.payload;
    if (payload == null) {
      throw ExternalProviderFailure(
        providerId: id,
        operation: 'resolvePayload',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'item carries no payload and source does not resolve lazily',
      );
    }
    return payload;
  }

  /// 释放源持有的连接资源。幂等；服务关闭时统一调。
  void close() {}
}
