/// 片源动态范围（SDR / HDR10 / HLG）的**唯一值域**与各来源的归一入口。
///
/// 存在的理由是收口：同一个「这片子是不是 HDR」，仓库里原本有三套互不相识的表示——
/// - libmpv `video-params`：`primaries=bt.2020` + `gamma=pq|hlg`（`video_hdr_output.dart`
///   的 [isHdrVideoParams]，只服务 Windows HDR 直通判据）；
/// - ffprobe：`color_primaries=bt2020` + `color_transfer=smpte2084|arib-std-b67`
///   （**字符串与 mpv 全不同名**，不能互相直接比较）；
/// - 种子发布标题解析：`AnimeDynamicRange`（`media/torrent/anime_release_descriptor.dart`），
///   只认标题里的 `HDR10` / `HLG` 字样。
///
/// 三套各判各的，库页和播放器就会对同一个文件给出不一致的 HDR 结论。这里只做一件事：
/// 定义一个值域，并给每个来源一个归一函数。**判据本身在各来源之间保持一致**（见下），
/// 不因为来源不同而放宽或收紧。
library;

import 'package:flutter/foundation.dart' show immutable;

/// 片源动态范围。
///
/// [unknown] 与 [sdr] **是两回事，不可互相顶替**：容器里没写色彩标签时，ffprobe 会
/// 直接省略 `color_primaries` / `color_transfer` 字段（实测：未显式给编码器写 VUI 的
/// 文件，连 `-show_streams` 全量输出里也没有这两个键）。此时正确答案是「不知道」，
/// 而不是「SDR」——把未知当 SDR 会让 UI 对一个真 HDR 片源打上 SDR 标，比不显示更糟。
enum VideoDynamicRange {
  /// 标准动态范围（BT.709 等）。
  sdr,

  /// HDR10：PQ 曲线（ffprobe `smpte2084` / mpv `pq`）。
  hdr10,

  /// HLG：混合对数伽马（ffprobe `arib-std-b67` / mpv `hlg`）。
  hlg,

  /// 色彩标签缺失或无法识别——**不等于 SDR**。
  unknown;

  /// 是否属于高动态范围。[unknown] 一律为 false（不猜）。
  bool get isHdr => this == hdr10 || this == hlg;

  /// 给 UI 的短标签；[unknown] 无标签（UI 不应为「不知道」占一个角标位）。
  String? get badgeLabel => switch (this) {
        VideoDynamicRange.hdr10 => 'HDR10',
        VideoDynamicRange.hlg => 'HLG',
        VideoDynamicRange.sdr => 'SDR',
        VideoDynamicRange.unknown => null,
      };

  /// 持久化 / 比较用的稳定字符串（不用 [name] 以免日后改枚举名时静默改变存储值）。
  String get storageValue => switch (this) {
        VideoDynamicRange.sdr => 'sdr',
        VideoDynamicRange.hdr10 => 'hdr10',
        VideoDynamicRange.hlg => 'hlg',
        VideoDynamicRange.unknown => 'unknown',
      };

  static VideoDynamicRange fromStorage(String? value) {
    for (final VideoDynamicRange r in values) {
      if (r.storageValue == value) return r;
    }
    return VideoDynamicRange.unknown;
  }
}

/// 一组色彩标签（primaries + transfer），与来源无关。
///
/// 两个来源的字符串拼写不同，先各自归一成这个中间形状，再走同一条判据——判据只写
/// 一次，就不会出现「mpv 说 HDR、ffprobe 说 SDR」。
@immutable
class VideoColorTags {
  const VideoColorTags({this.primaries, this.transfer});

  /// 是否 BT.2020 色域。null = 容器没写。
  final bool? primaries;

  /// 传递函数；null = 容器没写。
  final VideoTransferFunction? transfer;
}

/// 传递函数（归一后的值域）。
enum VideoTransferFunction { sdr, pq, hlg }

/// **唯一判据**：BT.2020 色域 **且** PQ/HLG 曲线才算 HDR。
///
/// 用「与」而不是只看 transfer，是为了与既有的 Windows HDR 直通行为逐位一致
/// （[isHdrVideoParams] 从一开始就是这个与逻辑，改判据会改变哪些片源触发宿主窗，
/// 属于破坏既有行为）。代价是「只写了 PQ 却没写 primaries」的畸形文件会判成
/// [VideoDynamicRange.unknown] 而非 HDR——这类文件极罕见，且判 unknown 只是不显示
/// 角标，不会显示错误信息。
VideoDynamicRange resolveDynamicRange(VideoColorTags tags) {
  // 两个标签都缺 = 容器没写色彩信息，诚实返回「不知道」。
  if (tags.primaries == null && tags.transfer == null) {
    return VideoDynamicRange.unknown;
  }
  final bool bt2020 = tags.primaries ?? false;
  switch (tags.transfer) {
    case VideoTransferFunction.pq:
      return bt2020 ? VideoDynamicRange.hdr10 : VideoDynamicRange.unknown;
    case VideoTransferFunction.hlg:
      return bt2020 ? VideoDynamicRange.hlg : VideoDynamicRange.unknown;
    case VideoTransferFunction.sdr:
      return VideoDynamicRange.sdr;
    case null:
      // 有 primaries 没 transfer：BT.2020 色域本身不足以断定 HDR（存在 BT.2020 的
      // SDR 素材），信息不足。
      return VideoDynamicRange.unknown;
  }
}

/// ffprobe `color_primaries` / `color_transfer` → [VideoDynamicRange]。
///
/// 取值实测自捆绑的 ffprobe n7.1.5（样本见计划记录）：
/// - HDR10：`color_primaries=bt2020`、`color_transfer=smpte2084`
/// - HLG：  `color_primaries=bt2020`、`color_transfer=arib-std-b67`
/// - SDR：  `color_primaries=bt709`、 `color_transfer=bt709`
/// - 未标注：**两个键都不出现在 JSON 里**（不是空串、不是 "unknown"）。
VideoDynamicRange dynamicRangeFromFfprobe({
  String? colorPrimaries,
  String? colorTransfer,
}) =>
    resolveDynamicRange(VideoColorTags(
      primaries: _bt2020FromFfprobe(colorPrimaries),
      transfer: _transferFromFfprobe(colorTransfer),
    ));

/// libmpv `video-params/primaries` / `video-params/gamma` → [VideoDynamicRange]。
///
/// mpv 的拼写与 ffprobe 不同：色域是 `bt.2020`（**带点**），曲线是 `pq` / `hlg`。
VideoDynamicRange dynamicRangeFromMpv({
  String? primaries,
  String? gamma,
}) =>
    resolveDynamicRange(VideoColorTags(
      primaries: _bt2020FromMpv(primaries),
      transfer: _transferFromMpv(gamma),
    ));

bool? _bt2020FromFfprobe(String? value) {
  final String? v = _normalized(value);
  if (v == null) return null;
  // ffprobe 对 BT.2020 有两种拼法（`bt2020` 与旧的 `bt2020nc`/`bt2020_ncl` 属于
  // color_space，不是 primaries；primaries 侧只会是 `bt2020`）。
  return v == 'bt2020';
}

VideoTransferFunction? _transferFromFfprobe(String? value) {
  final String? v = _normalized(value);
  if (v == null) return null;
  return switch (v) {
        'smpte2084' => VideoTransferFunction.pq,
        'arib-std-b67' => VideoTransferFunction.hlg,
        _ => VideoTransferFunction.sdr,
      };
}

bool? _bt2020FromMpv(String? value) {
  final String? v = _normalized(value);
  if (v == null) return null;
  return v == 'bt.2020';
}

VideoTransferFunction? _transferFromMpv(String? value) {
  final String? v = _normalized(value);
  if (v == null) return null;
  return switch (v) {
        'pq' => VideoTransferFunction.pq,
        'hlg' => VideoTransferFunction.hlg,
        _ => VideoTransferFunction.sdr,
      };
}

/// 空串按「没写」处理：mpv 在属性未就绪时给空串，与 ffprobe 的「省略键」同义。
String? _normalized(String? value) {
  if (value == null) return null;
  final String trimmed = value.trim().toLowerCase();
  if (trimmed.isEmpty || trimmed == 'unknown' || trimmed == 'unspecified') {
    return null;
  }
  return trimmed;
}
