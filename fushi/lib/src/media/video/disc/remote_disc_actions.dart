import 'dart:async';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_menu_info.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

import 'package:fushi/src/media/video/disc/disc_session_entry.dart';
import 'package:fushi/src/media/video/disc/remote_disc_menu_source.dart';
import 'package:fushi/src/sync/remote_disc_share.dart';

/// 详情页对「远端原盘」能做的事（远端原盘第二期），由库页按当前远端来源装配；
/// null = 这个远端来源给不出原盘（云盘 / 媒体服务器），按第一期的「远端资源」处理。
class RemoteDiscActions {
  const RemoteDiscActions({
    required this.openShare,
    required this.readFile,
    this.hostCanOpenDisc,
    this.openOnHost,
  });

  /// 为盘上任一条标题签发共享会话。老 host 抛 [RemoteDiscShareUnsupported]。
  final Future<RemoteDiscShare> Function(String videoId) openShare;

  /// 读共享里的一个小文件（`index.bdmv` 等）。
  final Future<Uint8List?> Function(
    RemoteDiscShare share,
    String relativePath,
    int maxBytes,
  )
  readFile;

  /// 这台 host 能不能被遥控着打开原盘菜单（视频遥控 `openDiscMenu`）。null = 本机
  /// 没有到这台 host 的遥控通道。
  final Future<bool> Function()? hostCanOpenDisc;

  /// 遥控 host 在它自己那边打开 [videoId] 所在的原盘会话。
  final Future<void> Function(String videoId)? openOnHost;

  /// 会话用的盘源。
  RemoteDiscMenuSource menuSource(
    RemoteDiscShare share,
    String title, {
    Future<void> Function()? downloadToDevice,
  }) => RemoteDiscMenuSource(
    share: share,
    title: title,
    readFile: (String path, int maxBytes) => readFile(share, path, maxBytes),
    downloadToDevice: downloadToDevice,
  );
}

/// 一次远端原盘探测的结果：能开就带上共享与盘源，开不了就给原因。
class RemoteDiscProbe {
  const RemoteDiscProbe({this.source, this.unavailable});

  final RemoteDiscMenuSource? source;
  final DiscMenuUnavailableReason? unavailable;
}

/// 远端原盘能不能在本机流式开菜单（签发一次共享、读一次 `index.bdmv`，不启动
/// Java）。与本地盘同一套 BD-J 规则（[resolveRemoteDiscMenuAvailability]）；本机
/// 播放组件支不支持读远端盘要等会话起来才知道（libmpv 的 `disc-remote-access`），
/// 那时如实报。
Future<RemoteDiscProbe> probeRemoteDiscMenu({
  required RemoteDiscActions actions,
  required String videoId,
  required String title,
  required DiscMenuPlatform platform,
  required bool bdjComponentInstallable,
  Future<void> Function()? downloadToDevice,
}) async {
  final RemoteDiscShare share;
  try {
    share = await actions.openShare(videoId);
  } on RemoteDiscShareUnsupported {
    return const RemoteDiscProbe(
      unavailable: DiscMenuUnavailableReason.remoteHostTooOld,
    );
  } catch (_) {
    return const RemoteDiscProbe(
      unavailable: DiscMenuUnavailableReason.remoteUnreachable,
    );
  }
  final RemoteDiscMenuSource source = actions.menuSource(
    share,
    title,
    downloadToDevice: downloadToDevice,
  );
  BlurayMenuInfo? info;
  if (!source.isDvd) {
    try {
      info = await source.readMenuInfo();
    } catch (_) {
      info = null;
    }
  }
  final DiscMenuUnavailableReason? reason = resolveRemoteDiscMenuAvailability(
    shareSupported: true,
    dvdFolder: source.streamBlock == RemoteDiscStreamBlock.dvdFolder,
    requiresJava: info?.requiresJava ?? false,
    platform: platform,
    bdjComponentInstallable: bdjComponentInstallable,
  );
  return RemoteDiscProbe(source: source, unavailable: reason);
}

/// 远端原盘成员：这一集是不是一条远端原盘标题（只看 host 下发的文件名）。
bool isRemoteDiscMember(RemoteVideoInfo? info) =>
    isRemoteDiscMemberFileName(info?.fileName);
