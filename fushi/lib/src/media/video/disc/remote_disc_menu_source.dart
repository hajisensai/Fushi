import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_menu_info.dart';
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart' show dvdTitlePath;
import 'package:path/path.dart' as p;

import 'package:fushi/src/sync/remote_disc_share.dart';

/// 一个流式原盘会话的盘源（远端原盘第二期）：libmpv 经 HTTP 读 host 的盘目录共享，
/// app 侧的少量预读（`index.bdmv`、`AACS/Unit_Key_RO.inf`）经 [readFile] 走同一共享。
///
/// 会话里的「标题身份」需要一个盘根来拼成员路径，以区分各条标题；远端盘在本机没有
/// 盘根，[identityRoot] 是一个**只作身份**的虚拟根（不是文件系统路径，任何 IO 都
/// 不该落到它上面）——会话不把远端标题绑定成本机库行。
class RemoteDiscMenuSource {
  RemoteDiscMenuSource({
    required this.share,
    required this.readFile,
    required this.title,
  });

  final RemoteDiscShare share;

  /// 读共享里一个文件的全部字节；超过 [maxBytes] / 不存在 / 读失败返回 null。
  final Future<Uint8List?> Function(String relativePath, int maxBytes) readFile;

  /// 会话顶栏显示的名字（远端合集名 / 盘名）。
  final String title;

  DiscShareManifest get manifest => share.manifest;

  bool get isDvd => manifest.format == DiscFormat.dvd;

  /// 只作身份的虚拟盘根。
  String get identityRoot =>
      p.join('fushi-remote-disc', manifest.discKey, manifest.name);

  /// 会话开盘用的代表成员路径（虚拟）：只用来让播放页按原盘会话的流程走，
  /// 真正读盘的是 libmpv 里的 libbluray / libdvdnav。
  String get representativeMemberPath => isDvd
      ? dvdTitlePath(identityRoot, 1)
      : p.join(identityRoot, 'BDMV', 'PLAYLIST', '00000.mpls');

  /// 交给 libmpv 的设备串（调用方再经 `nativePlaybackUri` 降给中继）。
  String get nativeDevice => share.nativeDevice;

  /// 这张盘能不能流式开菜单；不能时给原因（第一期「说明原因」的文案表）。
  RemoteDiscStreamBlock? get streamBlock => remoteDiscStreamBlockFor(manifest);

  /// 读蓝光主索引（与本地 [readBlurayMenuInfo] 同一回退：主索引坏了读 BACKUP）。
  Future<BlurayMenuInfo?> readMenuInfo() async {
    for (final String relative in const <String>[
      'BDMV/index.bdmv',
      'BDMV/BACKUP/index.bdmv',
    ]) {
      if (manifest.fileAt(relative) == null) continue;
      final Uint8List? bytes = await readFile(relative, 1024 * 1024);
      if (bytes == null || bytes.length < 78) continue;
      final BlurayMenuInfo? info = parseBlurayMenuInfo(bytes);
      if (info != null) return info;
    }
    return null;
  }
}

/// 一张共享盘不能流式开菜单的结构性原因（与平台能力无关、只看清单就定得下）。
enum RemoteDiscStreamBlock {
  /// DVD 是 `VIDEO_TS` 文件夹形态：libdvdnav 7.0 没有文件访问入口，只能按块读镜像。
  dvdFolder,
}

/// 纯判定：只看清单。
RemoteDiscStreamBlock? remoteDiscStreamBlockFor(DiscShareManifest manifest) =>
    manifest.format == DiscFormat.dvd &&
        manifest.layout == DiscShareLayout.directory
    ? RemoteDiscStreamBlock.dvdFolder
    : null;
