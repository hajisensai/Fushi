import 'plugin_models.dart';

/// 一个插件「能被调用」的那一面：[MusicPluginSource] 只经它调能力、核对封面与媒体地址。
///
/// 两种实现：
/// - [MusicPluginInstance]：本机 JS 沙箱里跑的插件（带插件运行时的平台）；
/// - 经互联中继的插件（拍板台 wOMR4_Er7s 方案 b，`docs/specs/2026-11-16-interconnect-source-share.md`
///   §5）：没有插件运行时的设备（iOS）把调用转给已配对 host，由 host 上的实例代跑，
///   本机不执行第三方代码、不连插件的平台取流 / 调接口。封面图例外：host 只核对地址，图片仍由
///   本机直接从插件平台的图片 CDN 加载（见 [checkCoverUrls]）。
///
/// 两种实现给出的结果形状一致（插件原始返回值 + 宿主核对过的地址），类型化解析只在
/// [MusicPluginSource] 写一次。
abstract interface class MusicPluginRuntime {
  /// 这个插件的校验摘要（清单 / 包摘要 / 签名者）。
  MusicPluginPackageInfo get info;

  /// 实例还能用；false 时管理器丢掉它，下次使用重开。
  bool get isAlive;

  /// 调一个能力（[method] = [MusicPluginCapability.wire]），返回插件的原始返回值。
  Future<Object?> invoke(
    String method,
    Map<String, Object?> args, {
    Duration? timeout,
  });

  /// 按插件网络授权核对登录页 / App 确认链接：「原地址 → 规范化地址」，越权的不出现。
  Map<String, String> checkRequestUrls(Iterable<String> urls);

  /// 封面地址批量核对：「原地址 → 可交给图片加载器的地址」，越权 / 落私网的不出现。
  Future<Map<String, String>> checkCoverUrls(Iterable<String> urls);

  /// 插件交给宿主播放的媒体地址 → 可交给播放器的最终地址与请求头；不可用抛
  /// `MusicPluginHttpException`。
  Future<({String url, Map<String, String> headers})> resolveMediaStream(
    String url,
    Map<String, String> headers,
  );
}

/// 经互联中继可用的一个插件（host 上已装且启用的音乐 / 歌词插件）。
class MusicPluginRelayedPlugin {
  const MusicPluginRelayedPlugin({required this.info, required this.via});

  /// host 给的校验摘要；清单里的能力已去掉不经中继的那几项（见
  /// [kMusicPluginRelayExcludedCapabilities]）。
  final MusicPluginPackageInfo info;

  /// 代跑它的那台设备的展示名。
  final String via;

  String get id => info.manifest.id;
}

/// 不经中继的能力：登录是在**那台设备**上给插件授权（扫码 / 网页登录 / 凭据进那台设备的
/// 保险库），换到另一台设备上操作既看不到登录页的地址核对结果，也不该替 host 主人登录或退出。
/// host 的中继目录把它们从清单里去掉，中继端点也拒绝调用。
const Set<String> kMusicPluginRelayExcludedCapabilities = <String>{'login'};

/// 本机没有插件运行时时，经互联用别的设备上的插件（[MusicPluginManager] 的 `relay`）。
abstract interface class MusicPluginRelay {
  /// 可用插件可能变了（换了 host、host 装卸插件、开关变了）：订阅方重新 [list]。
  Stream<void> get changes;

  /// 此刻经中继可用的插件（取不到时为空，不抛）。
  Future<List<MusicPluginRelayedPlugin>> list();

  /// 打开插件 [id] 的中继实例。不再可用抛 `MusicPluginUnavailableException`。
  Future<MusicPluginRuntime> open(String id);
}
