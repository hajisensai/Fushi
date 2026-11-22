import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show
        kLiveLibraryDeletionTombstonesCapability,
        kLiveLibraryLocalAudioContentIdCapability,
        kLiveLibraryVideoDeletionCapability;
import 'package:fushi_engine/sync/pdf_sync_package.dart'
    show kLiveLibraryPdfBooksCapability;

/// 互联同步里因为**对端（host）版本 / 能力不够**而没同步、或降级同步的维度（拍板
/// other-sync-peer-version-errors）。
///
/// 新旧版本混用时，host 缺某个端点或能力位，client 只能跳过这一维度或换一种更弱的
/// 做法。此前多数维度是静默的，用户以为同步成功了；现在每个维度在同步报告里统一记
/// 一句（[SyncPeerGap.message]），说清哪一项没同步 / 降级成了什么、该升级哪台设备，
/// 每轮每维度最多一条。
enum SyncPeerGapDimension {
  collections(
    label: 'collections live sync',
    consequence: 'collections were not synced',
  ),
  tags(
    label: 'tags live sync',
    consequence: 'tags were not synced',
    capabilityKey: 'tags',
  ),
  mediaLinks(
    label: 'media links live sync',
    consequence: 'work links (the media graph) were not synced',
    capabilityKey: 'mediaLinks',
  ),
  videoMetadata(
    label: 'video metadata live sync',
    consequence: 'scraped video metadata was not synced',
    capabilityKey: 'videoMetadata',
  ),
  serviceConfig(
    label: 'service config live sync',
    consequence: "the host's shared service settings were not synced",
    capabilityKey: 'serviceConfig',
  ),
  deletionTombstones(
    label: 'deletion tombstones live sync',
    consequence:
        'items deleted on the host were not offered for deletion on this '
        'device',
    capabilityKey: kLiveLibraryDeletionTombstonesCapability,
  ),
  videoDeletion(
    label: 'deletion push video',
    consequence:
        'videos deleted here "from all devices" were not deleted on the host',
    capabilityKey: kLiveLibraryVideoDeletionCapability,
    reportWhenDeclaredOff: true,
  ),
  videoSubtitles(
    label: 'live push subtitles',
    consequence: 'video subtitles were not pushed to the host',
  ),
  pdfBooks(
    label: 'live push books',
    consequence: 'PDF books were not pushed and stay on this device only',
    capabilityKey: kLiveLibraryPdfBooksCapability,
    reportWhenDeclaredOff: true,
  ),
  localAudioIdentity(
    label: 'local audio',
    consequence:
        'local audio libraries were matched by display name only (a renamed '
        'copy of the same library may transfer again)',
    capabilityKey: kLiveLibraryLocalAudioContentIdCapability,
    degraded: true,
  );

  const SyncPeerGapDimension({
    required this.label,
    required this.consequence,
    this.capabilityKey,
    this.reportWhenDeclaredOff = false,
    this.degraded = false,
  });

  /// 缺这项能力时这一维度**照样同步了、只是降级**（本地音频退回按显示名匹配），而
  /// 不是没同步。手动同步摘要据此把它算进「N 项只能降级同步」，不说成「没同步」。
  final bool degraded;

  /// 报告行前缀，与该维度其它错误行（`'$label: $error'`）同前缀。
  final String label;

  /// 这一维度没同步 / 降级成了什么。
  final String consequence;

  /// host 在 `/api/capabilities` 的 `liveLibrary` 里声明这项能力的键；null = 没有
  /// 对应能力位（只能靠端点 404 判断，404 即版本过旧）。
  final String? capabilityKey;

  /// host 认识这一位但声明不支持（`declaredOff`）时是否也记一条。默认不记：那是
  /// host 实现主动不提供、用户升级也解决不了的；只有「用户的操作因此落空」的维度
  /// （PDF 留在本机、视频删除没传过去）要说出来。
  final bool reportWhenDeclaredOff;
}

/// 一条「对端缺能力」记录。[outdated] = true：对端 Fushi 版本过旧（升级对端即可）；
/// false：对端版本认识这项能力但不支持（例如无头服务端收不了 PDF）。
class SyncPeerGap {
  const SyncPeerGap({required this.dimension, required this.outdated});

  final SyncPeerGapDimension dimension;
  final bool outdated;

  /// 写进 [SyncRunReport.errors] 的那一行（同步任务面板逐行展示、错误日志留痕）。
  String get message => outdated
      ? '${dimension.label}: the peer runs an older Fushi version, so '
            '${dimension.consequence}. Update Fushi on the peer device (the '
            'interconnect host).'
      : '${dimension.label}: the peer does not support this, so '
            '${dimension.consequence}.';
}
