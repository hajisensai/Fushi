import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/anilist_client.dart';

/// **纯映射**：把 [AniListFailureKind] 翻成给用户看的一句话。
///
/// 为什么要有这个文件：AniList 挂掉会在**三个入口**同时显形（放送日历页、番剧
/// 下载对话框的搜番、字幕面板的系列确认）。此前三处各自展示 `error.toString()`，
/// 于是同一次故障对用户呈现三种说法，且都是英文异常串——用户只能看出「坏了」，
/// 看不出「谁坏了、我该做什么」。
///
/// 尤其要分开的是**「连不上」与「上游自己关了」**：AniList 过载时会主动停用公开
/// API 并返回 403，请求其实已经打到对方。把这种情况显示成网络故障（更糟的是附
/// 上「去配置代理」），用户会去折腾自己的网络，而那边配到天亮也好不了。
///
/// 返回 null = 这类失败没有额外可说的（调用方只展示通用文案 + 原始错误串）。
String? anilistFailureNotice(AniListFailureKind? kind) {
  return switch (kind) {
    AniListFailureKind.apiDisabled => t.video_anilist_error_api_disabled,
    AniListFailureKind.rateLimited => t.video_anilist_error_rate_limited,
    AniListFailureKind.unreachable => t.video_anilist_error_unreachable,
    AniListFailureKind.other => null,
    null => null,
  };
}

/// 字幕面板的降级提示：先说「这次没在 AniList 确认上系列，结果可能跨季」，
/// 再补一句**为什么**（官方停服 / 限流 / 连不上）。
///
/// 两块信息缺一不可：只说降级，用户不知道是不是自己网络的锅、要不要重试；只说
/// 原因，用户不知道眼前这批结果为什么不可信。[kind] 为 null（旧调用点 / 测试
/// 钩子）时逐字退化成原来那一句，不改变既有行为。
String jimakuSeriesLookupNotice(AniListFailureKind? kind) {
  final String? reason = anilistFailureNotice(kind);
  if (reason == null) return t.video_jimaku_series_lookup_degraded;
  return '${t.video_jimaku_series_lookup_degraded}\n$reason';
}
