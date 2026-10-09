/// 下载方式 / 内容来源标注（2026-10-09 所有者：「给各个下载提供明显提示，说是
/// 外部来源」）。
///
/// 起因是海外用户分不清浏览页里的下载走的是内置 BT 还是直链、要不要挂 VPN。
/// 每个下载结果 / 下载任务都用同一组标签说清两件事：
/// - **方式**（[DownloadTransferMethod]）：BT / 磁力（P2P）、直链（HTTP）、
///   扩展源（第三方扩展抓取）；
/// - **来源**：内容来自第三方站点时多一枚「外部来源」，表明不是 Fushi 提供的。
///
/// 点标签会弹一句说明（[FushiTag.message]），文案只陈述技术事实：内置引擎默认
/// 关上传，所以 BT 说明写的是「开启上传时会上传」，不写成「一定会上传」。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/media/discovery/media_discovery_service.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';

/// 一条下载实际走的传输方式。
enum DownloadTransferMethod {
  /// BitTorrent / 磁力：点对点，数据来自同一种子的其他用户。
  torrent,

  /// HTTP(S) 直链：直接从某台服务器下载（发现源直链、互联对端、媒体服务器）。
  direct,

  /// 用户安装的第三方扩展（Mihon / Aniyomi / LNReader）从对应网站获取。
  extension,
}

extension DownloadTransferMethodLabels on DownloadTransferMethod {
  String get label => switch (this) {
    DownloadTransferMethod.torrent => t.download_method_torrent,
    DownloadTransferMethod.direct => t.download_method_direct,
    DownloadTransferMethod.extension => t.download_method_extension,
  };

  String get hint => switch (this) {
    DownloadTransferMethod.torrent => t.download_method_torrent_hint,
    DownloadTransferMethod.direct => t.download_method_direct_hint,
    DownloadTransferMethod.extension => t.download_method_extension_hint,
  };

  IconData get icon => switch (this) {
    DownloadTransferMethod.torrent => Icons.hub_outlined,
    DownloadTransferMethod.direct => Icons.link_rounded,
    DownloadTransferMethod.extension => Icons.extension_outlined,
  };
}

/// 发现资源按 payload 种类对应的传输方式（torrent → BT，httpFile → 直链）。
DownloadTransferMethod discoveryTransferMethodOf(DiscoveryPayloadKind kind) =>
    switch (kind) {
      DiscoveryPayloadKind.torrent => DownloadTransferMethod.torrent,
      DiscoveryPayloadKind.httpFile => DownloadTransferMethod.direct,
    };

/// 发现源条目是不是外部来源：内置发现源（真红小站 / Nyaa / 内置 AList …）是
/// 第三方站点；用户自配的 OPDS / Audiobookshelf 是用户自己指定的服务器，不标。
/// 源已不在注册表时按外部处理。
bool isExternalDiscoverySource(
  MediaDiscoveryService service,
  String sourceId,
) => service.sourceById(sourceId)?.isUserConfigured != true;

/// 「外部来源」标签的图标（作品页 chip 与下载标签共用）。
const IconData kExternalSourceIcon = Icons.public_rounded;

/// 方式标签 + （可选）外部来源标签，一行小胶囊。
class DownloadSourceTags extends StatelessWidget {
  const DownloadSourceTags({
    required this.method,
    this.external = true,
    super.key,
  });

  final DownloadTransferMethod method;

  /// 内容来自第三方站点（不是用户自己的设备 / 媒体服务器）。
  final bool external;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        FushiTag(
          key: ValueKey<String>('download-method-${method.name}'),
          text: method.label,
          message: method.hint,
          icon: method.icon,
          iconSize: 14,
          tone: FushiTagTone.accent,
          dense: true,
        ),
        if (external) const DownloadExternalSourceTag(),
      ],
    );
  }
}

/// 单独一枚「外部来源」标签（点按弹说明）。
class DownloadExternalSourceTag extends StatelessWidget {
  const DownloadExternalSourceTag({super.key});

  @override
  Widget build(BuildContext context) => FushiTag(
    key: const ValueKey<String>('download-source-external'),
    text: t.download_source_external,
    message: t.download_source_external_hint,
    icon: kExternalSourceIcon,
    iconSize: 14,
    tone: FushiTagTone.warning,
    dense: true,
  );
}

/// 在线扩展源作品页头部的两枚 chip（扩展源 + 外部来源），三域作品页共用。
List<MediaDetailChip> extensionSourceDetailChips() => <MediaDetailChip>[
  MediaDetailChip(
    t.download_method_extension,
    icon: DownloadTransferMethod.extension.icon,
    key: const ValueKey<String>('online-work-extension-source-chip'),
  ),
  MediaDetailChip(
    t.download_source_external,
    icon: kExternalSourceIcon,
    tone: MediaDetailChipTone.tertiary,
    key: const ValueKey<String>('online-work-external-source-chip'),
  ),
];
