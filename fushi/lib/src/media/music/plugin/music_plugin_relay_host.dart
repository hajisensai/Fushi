/// 互联「插件中继」的 host 侧（拍板台 wOMR4_Er7s 方案 b，协议见
/// `package:fushi_engine/sync/interconnect_plugin_relay.dart`）：用本机的插件管理器替没有插件
/// 运行时的「我的设备」代跑音乐 / 歌词插件，并把媒体字节转发过去。
///
/// 核对全部在这里、按本机插件的网络授权做，与本机自己播放同一套判据：能力必须是清单声明过且
/// 不在 [kMusicPluginRelayExcludedCapabilities] 里的；封面 / 媒体地址经实例核对；取流时连接只连
/// 核对过的 IP（[MusicPluginGuardedHttp]），上游再重定向一律不跟。
///
/// 只中继 host 主人在「选择要共享的来源」里勾过的插件（`musicPlugin/<id>`，与来源共享同一份
/// 勾选）：没勾的插件不进目录，按 id 直接调也当「不可用」。
library;

import 'dart:async';
import 'dart:io';

import 'package:fushi_engine/sync/interconnect_plugin_relay.dart';
import 'package:fushi_music/fushi_music.dart';

/// 取流请求的建连 / 等响应头时限。
const Duration kMusicPluginRelayUpstreamTimeout = Duration(seconds: 20);

class AppMusicPluginRelayHost implements InterconnectPluginRelayHost {
  AppMusicPluginRelayHost({
    required MusicPluginManager Function() manager,
    required Future<bool> Function() enabled,
    required Future<bool> Function(String peerToken) isOwnerDevicePeer,
    required MusicPluginHttpClientFactory httpClientFactory,
    required Future<Set<String>> Function() sharedItems,
    MusicPluginResolver? resolver,
    MusicPluginAddressBlocker? addressBlocker,
  }) : _manager = manager,
       _enabled = enabled,
       _isOwnerDevicePeer = isOwnerDevicePeer,
       _sharedItems = sharedItems,
       _httpClientFactory = httpClientFactory,
       _resolver = resolver,
       _addressBlocker = addressBlocker;

  final MusicPluginManager Function() _manager;
  final Future<bool> Function() _enabled;
  final Future<bool> Function(String peerToken) _isOwnerDevicePeer;

  /// host 主人勾选共享的来源（`kind/id`）。
  final Future<Set<String>> Function() _sharedItems;
  final MusicPluginHttpClientFactory _httpClientFactory;
  final MusicPluginResolver? _resolver;
  final MusicPluginAddressBlocker? _addressBlocker;

  @override
  Future<bool> isPluginRelayEnabled() => _enabled();

  @override
  Future<bool> isOwnerDevicePeer(String peerToken) =>
      _isOwnerDevicePeer(peerToken);

  static String _shareKey(String pluginId) => 'musicPlugin/$pluginId';

  @override
  Future<List<Map<String, Object?>>> pluginRelayCatalog() async {
    final Set<String> shared = await _sharedItems();
    return <Map<String, Object?>>[
      for (final InstalledMusicPlugin p in await _manager().listInstalled())
        if (p.usable &&
            p.info!.manifest.isMusic &&
            shared.contains(_shareKey(p.id)))
          MusicPluginPackageInfo(
            manifest: p.info!.manifest.withoutCapabilities(
              kMusicPluginRelayExcludedCapabilities,
            ),
            digest: p.info!.digest,
            signer: p.info!.signer,
            files: p.info!.files,
          ).toJson(),
    ];
  }

  /// 本机已装、启用的插件实例；不可用折成 [kPluginRelayNotAvailable]。
  Future<MusicPluginInstance> _instance(String pluginId) async {
    if (!(await _sharedItems()).contains(_shareKey(pluginId))) {
      throw const InterconnectPluginRelayError(
        kPluginRelayNotAvailable,
        '主人没有共享这个插件',
      );
    }
    try {
      return await _manager().instance(pluginId);
    } on MusicPluginUnavailableException catch (e) {
      throw InterconnectPluginRelayError(kPluginRelayNotAvailable, e.message);
    } on MusicPluginException catch (e) {
      throw InterconnectPluginRelayError(kPluginRelayPluginError, e.message);
    }
  }

  @override
  Future<Object?> pluginRelayInvoke(
    String pluginId,
    String method,
    Map<String, Object?> args,
  ) async {
    if (kMusicPluginRelayExcludedCapabilities.contains(method)) {
      throw InterconnectPluginRelayError(kPluginRelayUnsupported, method);
    }
    final MusicPluginInstance inst = await _instance(pluginId);
    if (!inst.info.manifest.capabilities.contains(method)) {
      throw InterconnectPluginRelayError(kPluginRelayUnsupported, method);
    }
    try {
      return await inst.invoke(method, args);
    } on MusicPluginException catch (e) {
      throw InterconnectPluginRelayError(kPluginRelayPluginError, e.message);
    }
  }

  @override
  Future<Map<String, String>> pluginRelayCheckCovers(
    String pluginId,
    List<String> urls,
  ) async => (await _instance(pluginId)).checkCoverUrls(urls);

  @override
  Future<InterconnectPluginRelayMediaTarget> pluginRelayResolveMedia(
    String pluginId,
    String url,
    Map<String, String> headers,
  ) async {
    final MusicPluginInstance inst = await _instance(pluginId);
    try {
      final ({String url, Map<String, String> headers}) m = await inst
          .resolveMediaStream(url, headers);
      return InterconnectPluginRelayMediaTarget(
        pluginId: pluginId,
        url: m.url,
        headers: m.headers,
      );
    } on MusicPluginHttpException catch (e) {
      throw InterconnectPluginRelayError(
        kPluginRelayMediaUnavailable,
        e.message,
      );
    }
  }

  @override
  Future<InterconnectPluginRelayUpstream> pluginRelayOpenMedia(
    InterconnectPluginRelayMediaTarget target, {
    String? range,
    required bool head,
  }) async {
    final Uri uri = Uri.parse(target.url);
    final MusicPluginGuardedHttp net = MusicPluginGuardedHttp(
      _httpClientFactory()..autoUncompress = false,
      resolve: _resolver ?? InternetAddress.lookup,
      isBlocked: _addressBlocker ?? isMusicPluginPrivateAddress,
    );
    final HttpClientResponse res;
    try {
      await net.pin(uri);
      final HttpClientRequest req = await net.client
          .openUrl(head ? 'HEAD' : 'GET', uri)
          .timeout(kMusicPluginRelayUpstreamTimeout);
      req.followRedirects = false;
      target.headers.forEach(req.headers.set);
      // 字节原样转发：压缩过的响应长度对不上 Range，播放器也不认。
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (range != null && range.isNotEmpty) {
        req.headers.set(HttpHeaders.rangeHeader, range);
      }
      res = await req.close().timeout(kMusicPluginRelayUpstreamTimeout);
    } on Object catch (e) {
      net.close(force: true);
      throw InterconnectPluginRelayError(
        kPluginRelayMediaUnavailable,
        e is MusicPluginHttpException ? e.message : '$e',
      );
    }
    // 解析时已逐跳核对过重定向；此刻再跳就是没核对过的目标，不跟、也不把 Location 交出去。
    if (res.isRedirect) {
      await res.listen(null).cancel();
      net.close(force: true);
      throw const InterconnectPluginRelayError(
        kPluginRelayMediaUnavailable,
        '媒体地址又发生了重定向',
      );
    }
    final Map<String, String> headers = <String, String>{
      for (final String name in kInterconnectPluginRelayForwardedHeaders)
        if (res.headers.value(name) case final String v) name: v,
    };
    if (head) {
      await res.listen(null).cancel();
      net.close(force: true);
      return InterconnectPluginRelayUpstream(
        statusCode: res.statusCode,
        headers: headers,
        body: const Stream<List<int>>.empty(),
      );
    }
    return InterconnectPluginRelayUpstream(
      statusCode: res.statusCode,
      headers: headers,
      body: _forward(res, net),
    );
  }

  /// 上游响应体 → client；播完、出错或 client 断开（订阅被取消）都关掉上游连接。
  static Stream<List<int>> _forward(
    HttpClientResponse res,
    MusicPluginGuardedHttp net,
  ) async* {
    try {
      yield* res;
    } finally {
      net.close(force: true);
    }
  }
}
