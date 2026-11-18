import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/media/video/bluray/bluray_angle.dart'
    show blurayAngleBaseMemberPath, parseBlurayAnglePath;
import 'package:fushi_engine/media/video/bluray/bluray_menu_info.dart';
import 'package:fushi_engine/media/video/bluray/bluray_source.dart'
    show isBlurayPlaylistPath;
import 'package:fushi_engine/media/video/disc/disc_format.dart';
import 'package:fushi_engine/media/video/disc/disc_share_manifest.dart';
import 'package:fushi_engine/media/video/dvd/dvd_angle.dart'
    show dvdTitleAngleBasePath, parseDvdTitleAnglePath;
import 'package:fushi_engine/media/video/dvd/dvd_disc.dart'
    show dvdTitlePath, isDvdTitlePath;
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
    this.downloadToDevice,
    this.fetchTitleAudio,
  });

  final RemoteDiscShare share;

  /// 读共享里一个文件的全部字节；超过 [maxBytes] / 不存在 / 读失败返回 null。
  final Future<Uint8List?> Function(String relativePath, int maxBytes) readFile;

  /// 会话顶栏显示的名字（远端合集名 / 盘名）。
  final String title;

  /// 「下载到本机」：把这张盘整盘排进下载队列（缓冲提示的动作）。null = 这个入口
  /// 给不出下载（提示只留「不再提示」与关闭）。
  final Future<void> Function()? downloadToDevice;

  /// 请 host 在它本地裁出一条 title（[hostTitleFor]）的音频落到本机（本机转录 /
  /// 重定时 / 对轴的整集音源）。null = 这个入口的盘源不是互联 host，取不到。
  final RemoteDiscTitleAudioFetch? fetchTitleAudio;

  DiscShareManifest get manifest => share.manifest;

  /// 会话里一条 title（[sessionMemberPath]：[identityRoot] 下的
  /// `BDMV/PLAYLIST/<名>.mpls`）在 host 上的定位：host 库里有这一条的行就用它；没有
  /// （菜单里的特典等）就用盘上任一条蓝光行当锚点、带上相对盘根的 title 路径，由 host
  /// 按（盘, title）定位（字幕任务的 `discTitle`、`clipaudio?discTitle=`）。
  ///
  /// 会话正放多角度 title 的第 N 个角度时，[sessionMemberPath] 是角度成员路径
  /// （`00001.a2.mpls`，见 `bluray_angle.dart`）：按不带角度的那条找 host 行，但总带
  /// `discTitle`（= 角度成员路径），让 host 按该角度读（要 host 声明认角度路径，见
  /// [RemoteDiscHostTitle.readsAngle]）。
  ///
  /// DVD 会话的 title（[identityRoot] 下的 `VIDEO_TS/TITLE_nn.dvdtitle`）总带 `discTitle`
  /// （= 成员路径），锚在这条 title 自己的行、没有就锚在盘上任一条 DVD 行：host 经
  /// `dvdvideo` demuxer 按 title 读，要 host 声明认 DVD title 才发（见
  /// [RemoteDiscHostTitle.readsDvd]）。正放多角度 title 的第 N 个角度时它是角度成员路径
  /// （`TITLE_03.a2.dvdtitle`，见 `dvd_angle.dart`）：按不带角度的那条找 host 行，
  /// `discTitle` 带角度，要 host 另声明认 DVD 角度路径（[RemoteDiscHostTitle.readsDvdAngle]）。
  ///
  /// 不在这张盘的身份根下、不是蓝光播放列表 / DVD title、或共享里没有任何同类行可当
  /// 锚点 → null。
  RemoteDiscHostTitle? hostTitleFor(String sessionMemberPath) {
    final List<String> root = p.split(p.normalize(identityRoot));
    final List<String> parts = p.split(p.normalize(sessionMemberPath));
    if (isDvdTitlePath(sessionMemberPath)) {
      return _dvdHostTitleFor(root, parts);
    }
    if (parts.length != root.length + 3) return null;
    for (int i = 0; i < root.length; i++) {
      if (parts[i] != root[i]) return null;
    }
    final List<String> rel = parts.sublist(root.length);
    if (rel[0].toUpperCase() != 'BDMV' ||
        rel[1].toUpperCase() != 'PLAYLIST' ||
        !isBlurayPlaylistPath(rel[2])) {
      return null;
    }
    final String memberPath = rel.join('/');
    final bool angle = parseBlurayAnglePath(rel[2]) != null;
    final String key = <String>[
      rel[0],
      rel[1],
      blurayAngleBaseMemberPath(rel[2]),
    ].join('/').toUpperCase();
    for (final RemoteDiscShareTitle t in share.titles) {
      if (t.path.toUpperCase() == key) {
        return RemoteDiscHostTitle(
          videoId: t.id,
          memberPath: memberPath,
          discTitle: angle ? memberPath : null,
        );
      }
    }
    for (final RemoteDiscShareTitle t in share.titles) {
      if (isBlurayPlaylistPath(t.path)) {
        return RemoteDiscHostTitle(
          videoId: t.id,
          memberPath: memberPath,
          discTitle: memberPath,
        );
      }
    }
    return null;
  }

  /// [hostTitleFor] 的 DVD 分支：[parts] 是 `<身份根>/VIDEO_TS/TITLE_nn.dvdtitle`。
  RemoteDiscHostTitle? _dvdHostTitleFor(List<String> root, List<String> parts) {
    if (parts.length != root.length + 2) return null;
    for (int i = 0; i < root.length; i++) {
      if (parts[i] != root[i]) return null;
    }
    final List<String> rel = parts.sublist(root.length);
    if (rel[0].toUpperCase() != 'VIDEO_TS') return null;
    final String memberPath = rel.join('/');
    final String key = dvdTitleAngleBasePath(memberPath).toUpperCase();
    final RemoteDiscShareTitle? own = share.titles
        .where((RemoteDiscShareTitle t) => t.path.toUpperCase() == key)
        .firstOrNull;
    final RemoteDiscShareTitle? anchor =
        own ??
        share.titles
            .where((RemoteDiscShareTitle t) => isDvdTitlePath(t.path))
            .firstOrNull;
    return anchor == null
        ? null
        : RemoteDiscHostTitle(
            videoId: anchor.id,
            memberPath: memberPath,
            discTitle: memberPath,
          );
  }

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

  /// [readMenuInfo] 的在途读取 / 已读到的结果。
  Future<BlurayMenuInfo?>? _menuInfo;

  /// 读蓝光主索引（与本地 [readBlurayMenuInfo] 同一回退：主索引坏了读 BACKUP）。
  ///
  /// 一次开盘里播放页（判要不要 Java 运行时）和控制器（开菜单）各要一次，拿的是同一个
  /// 盘源实例：读到的结果记在这里，第二次不再走网络。清单在盘源的一生里不变，所以
  /// 读到的索引不会过期；读不到（null / 抛错）不记，下次调用重新读。
  Future<BlurayMenuInfo?> readMenuInfo() {
    final Future<BlurayMenuInfo?>? known = _menuInfo;
    if (known != null) return known;
    late final Future<BlurayMenuInfo?> reading;
    void forget() {
      if (identical(_menuInfo, reading)) _menuInfo = null;
    }

    reading = _readMenuInfoFromShare().then(
      (BlurayMenuInfo? info) {
        if (info == null) forget();
        return info;
      },
      onError: (Object error, StackTrace stack) {
        forget();
        Error.throwWithStackTrace(error, stack);
      },
    );
    return _menuInfo = reading;
  }

  Future<BlurayMenuInfo?> _readMenuInfoFromShare() async {
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

/// 请 host 把一条原盘 title 的 `[startMs, endMs)` 音频裁好落到本机 [dest]（单音轨 aac）。
/// [audioStreamIndex] / [audioStreamCount] 选会话里当前在听的音轨。
typedef RemoteDiscTitleAudioFetch =
    Future<void> Function(
      RemoteDiscHostTitle title,
      File dest, {
      required int startMs,
      required int endMs,
      int? audioStreamIndex,
      int? audioStreamCount,
    });

/// 远端原盘会话里的一条 title 在 host 上的定位（见 [RemoteDiscMenuSource.hostTitleFor]）。
class RemoteDiscHostTitle {
  const RemoteDiscHostTitle({
    required this.videoId,
    required this.memberPath,
    this.discTitle,
  });

  /// host 库里的视频行：这条 title 自己的行，或（[discTitle] 非 null 时）同一张盘上
  /// 当锚点的那一行。
  final String videoId;

  /// 相对盘根的成员路径（`BDMV/PLAYLIST/00800.mpls`），总有。
  final String memberPath;

  /// host 库里没有这条 title 的行、或要按非第 1 个角度读时，要 host 按（盘, title）定位
  /// 的 title（= [memberPath]）；null = [videoId] 就是这条 title。
  final String? discTitle;

  /// [discTitle] 是多角度 title 的角度成员路径（`00001.a2.mpls`）：host 要声明认角度路径
  /// （字幕任务 `acceptsDiscTitleAngle`、`liveLibrary.videoClipAudioDiscTitleAngle`）才发。
  bool get readsAngle =>
      discTitle != null && parseBlurayAnglePath(discTitle!) != null;

  /// [discTitle] 是 DVD title（`VIDEO_TS/TITLE_nn.dvdtitle`）：host 要声明认 DVD title
  /// （字幕任务 `acceptsDiscTitleDvd`、`liveLibrary.videoClipAudioDiscTitleDvd`）才发。
  bool get readsDvd => discTitle != null && isDvdTitlePath(discTitle!);

  /// [discTitle] 是 DVD 多角度 title 的角度成员路径（`VIDEO_TS/TITLE_03.a2.dvdtitle`）：
  /// host 还要声明认它（字幕任务 `acceptsDiscTitleDvdAngle`、
  /// `liveLibrary.videoClipAudioDiscTitleDvdAngle`）才发。
  bool get readsDvdAngle =>
      discTitle != null && parseDvdTitleAnglePath(discTitle!) != null;

  /// 同一张盘上各条 title 互不相同的稳定标识（任务键、落盘名用）。
  String get key => discTitle == null ? videoId : '$videoId@$discTitle';

  @override
  bool operator ==(Object other) =>
      other is RemoteDiscHostTitle &&
      other.videoId == videoId &&
      other.memberPath == memberPath &&
      other.discTitle == discTitle;

  @override
  int get hashCode => Object.hash(videoId, memberPath, discTitle);

  @override
  String toString() => 'RemoteDiscHostTitle($key)';
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

/// 流式原盘的「反复缓冲」判据（拍板决策：只给一条可关闭的提示，绝不强制切换）。
///
/// 只数**起播之后**的缓冲：开盘时的第一次缓冲是建立连接、预读索引，不说明带宽不够。
/// [window] 内出现 [threshold] 次「播放中 → 缓冲」就该提示；一个会话至多提示一次。
class RemoteDiscBufferingMonitor {
  RemoteDiscBufferingMonitor({
    this.threshold = 3,
    this.window = const Duration(minutes: 2),
  });

  final int threshold;
  final Duration window;
  final List<DateTime> _stalls = <DateTime>[];
  bool _playedOnce = false;
  bool _buffering = false;
  bool _suggested = false;

  /// 喂一次缓冲态；返回 true = 现在该提示。
  bool update({required bool buffering, required DateTime now}) {
    final bool started = buffering && !_buffering;
    if (!buffering) _playedOnce = true;
    _buffering = buffering;
    if (!started || !_playedOnce || _suggested) return false;
    _stalls
      ..add(now)
      ..removeWhere((DateTime at) => now.difference(at) > window);
    if (_stalls.length < threshold) return false;
    _suggested = true;
    return true;
  }
}
