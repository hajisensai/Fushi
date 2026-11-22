/// 起播期补查服务器曲目的响度（`music_server_loudness.dart` 的 app 侧装配）。
///
/// 从服务器页列表直接播的曲目已经带着服务器给的响度（[MusicServerTrack.loudness] →
/// `MusicPlayItem.rg*`）；从音乐库 / 本地歌单还原的服务器曲目（v149 行里不存响度）、或列表里
/// 只带了曲目增益（Jellyfin 的专辑增益在专辑条目上）的，由播放后端在取流时按
/// [MusicPlayItem.serverTrack] 向当前配置的那台服务器补查一次（[MusicServerLoudnessLookup]），
/// 结果按曲目缓存在进程内——同一首再播不再问。查询失败不缓存（下次再问）、不打断播放：
/// 没有响度时按 0 dB 播，与本地没标签、还没扫描的曲目一致。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi_engine/media/music/server/music_server_loudness.dart';
import 'package:fushi_engine/media/music/server/subsonic_music_client.dart'
    show redactSubsonicCredentials;

import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_remote_tracks.dart'
    show MusicServerBinding, MusicServerBindingLoader, musicServerKindStorable;

/// 播放后端用的补查接口（测试注入替身）。
abstract interface class MusicServerLoudnessResolver {
  /// [ref] 那首曲目的服务器响度；服务器没有 / 没配这台服务器 / 查询失败回 null。不抛。
  Future<MusicServerLoudness?> resolve(MusicServerTrackRef ref);
}

/// 进程级装配点：`AppModel` 建音乐会话时装上；未装配（测试 / 无头入口）时不补查。
MusicServerLoudnessResolver? musicServerLoudnessResolver;

/// 这一项要不要起播期补查：Jellyfin / Subsonic 曲目，且还缺专辑增益（缺曲目增益时专辑增益
/// 也必然缺：两家服务器都是曲目增益先有）。专辑模式要专辑增益，所以只有曲目增益也要补。
bool musicItemNeedsServerLoudness(MusicPlayItem item) {
  final MusicServerTrackRef? ref = item.serverTrack;
  if (ref == null || !musicServerKindStorable(ref.kind)) return false;
  return item.rgAlbumGain == null;
}

/// 把补查到的响度并进播放项已有的值（已有的优先：那是列表接口当场给的）。
({double? trackGain, double? trackPeak, double? albumGain, double? albumPeak})
musicItemLoudnessWith(MusicPlayItem item, MusicServerLoudness? extra) => (
  trackGain: item.rgTrackGain ?? extra?.trackGainDb,
  trackPeak: item.rgTrackGain != null ? item.rgTrackPeak : extra?.trackPeak,
  albumGain: item.rgAlbumGain ?? extra?.albumGainDb,
  albumPeak: item.rgAlbumGain != null ? item.rgAlbumPeak : extra?.albumPeak,
);

/// 真 app 实现：按 [MusicServerTrackRef.serverId] 找当前配置的服务器（[loader]），浏览器
/// 实现了 [MusicServerLoudnessLookup] 才问。
class BindingMusicServerLoudnessResolver
    implements MusicServerLoudnessResolver {
  BindingMusicServerLoudnessResolver(this._loader);

  final MusicServerBindingLoader _loader;

  /// 已有结论（含「服务器没有」= null）的曲目；进行中的请求也在这里，并发的同一首只问一次。
  final Map<String, Future<MusicServerLoudness?>> _cache =
      <String, Future<MusicServerLoudness?>>{};

  static String _key(MusicServerTrackRef ref) =>
      '${ref.serverId}\u0000${ref.trackId}';

  @override
  Future<MusicServerLoudness?> resolve(MusicServerTrackRef ref) {
    if (!musicServerKindStorable(ref.kind)) {
      return Future<MusicServerLoudness?>.value();
    }
    final String key = _key(ref);
    return _cache[key] ??= _fetch(ref).catchError((Object e) {
      // 失败不留缓存：服务器暂时连不上时，下次播到再问。原因进日志（经凭据脱敏）。
      _cache.remove(key);
      debugPrint(
        '[music-loudness] server lookup failed: '
        '${redactSubsonicCredentials('$e')}',
      );
      return null;
    });
  }

  Future<MusicServerLoudness?> _fetch(MusicServerTrackRef ref) async {
    final Map<String, MusicServerBinding> bound = await _loader();
    final MusicServerBinding? binding = bound[ref.serverId];
    if (binding == null) return null;
    final Object browser = binding.browser;
    if (binding.browser.kind != ref.kind ||
        browser is! MusicServerLoudnessLookup) {
      return null;
    }
    return browser.loudnessOf(ref);
  }
}
