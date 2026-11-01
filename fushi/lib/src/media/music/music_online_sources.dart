import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginManifest;

import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';

/// 音乐模块的一个在线来源：插件音源或服务器（Jellyfin / Emby、OpenSubsonic、Apple Music）。
///
/// 曲库页「推荐」的来源 chip、统一搜索的来源 chip、「来源」管理页都按同一份顺序与启停
/// （偏好 `music_online_sources`，与歌词来源同一 `[{id, enabled}]` JSON 形状）列它们。
abstract class MusicOnlineSource {
  const MusicOnlineSource();

  /// 排序 / 启停偏好里的稳定 id（Apple Music 不带 storefront：换地区不丢顺序）。
  String get key;

  String get name;
}

final class MusicPluginOnlineSource extends MusicOnlineSource {
  const MusicPluginOnlineSource(this.manifest);

  final MusicPluginManifest manifest;

  @override
  String get key => musicPluginSourceKey(manifest.id);

  @override
  String get name => manifest.name;
}

final class MusicServerOnlineSource extends MusicOnlineSource {
  const MusicServerOnlineSource(this.browser);

  final MusicServerBrowser browser;

  @override
  String get key => musicServerSourceKey(browser);

  @override
  String get name => browser.displayName;
}

/// Apple Music 在排序偏好里的固定 id。
const String kAppleMusicSourceKey = 'apple-music';

String musicPluginSourceKey(String pluginId) => 'plugin:$pluginId';

String musicServerSourceKey(MusicServerBrowser browser) =>
    browser.kind == MusicServerKind.appleMusic
    ? kAppleMusicSourceKey
    : 'server:${browser.serverId}';

/// 一个来源连同它在「推荐 / 搜索」里是否显示。
typedef MusicOrderedSource = ({MusicOnlineSource source, bool enabled});

/// 按偏好排好序：偏好里有的按偏好的顺序与启停，没登记过的（新装 / 新加）按 [sources]
/// 原顺序追加在末尾、默认显示；偏好里已不存在的来源丢掉。
List<MusicOrderedSource> orderMusicOnlineSources(
  List<MusicOnlineSource> sources,
  List<LyricsProviderEntry> stored,
) {
  final Map<String, MusicOnlineSource> byKey = <String, MusicOnlineSource>{
    for (final MusicOnlineSource s in sources) s.key: s,
  };
  final List<LyricsProviderEntry> merged = mergeLyricsProviders(
    stored,
    byKey.keys,
  );
  return <MusicOrderedSource>[
    for (final LyricsProviderEntry e in merged)
      (source: byKey[e.id]!, enabled: e.enabled),
  ];
}

/// 只留显示中的来源。
List<MusicOnlineSource> enabledMusicOnlineSources(
  List<MusicOrderedSource> ordered,
) => <MusicOnlineSource>[
  for (final MusicOrderedSource o in ordered)
    if (o.enabled) o.source,
];

/// 系统地区 → Apple Music storefront 的默认值（[choices] 里没有就落 `jp`）。
String appleMusicStorefrontForCountry(
  String? countryCode,
  List<String> choices,
) {
  final String c = (countryCode ?? '').trim().toLowerCase();
  return choices.contains(c) ? c : 'jp';
}
