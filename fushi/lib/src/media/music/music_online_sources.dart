import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:fushi_music/fushi_music.dart' show MusicPluginManifest;

import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/models/preferences_repository.dart';

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
/// 原顺序追加在末尾、默认显示。偏好里有、这次没加载到的来源（插件被停用、服务器被停用、
/// 数据库还没就绪）只是不出现在结果里——偏好本身不动，写回走 [applyMusicOnlineSourceEdits]。
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

/// 把「来源」页上可见行的新顺序与开关合并回已存的完整列表，写回用。
///
/// 已存但这次不在场的条目（插件停用、服务器停用等）**原样保留**在原来的相对位置：
/// 可见行只在它们自己原来占的那几个位置之间按新顺序重排，没登记过的可见行追加在末尾。
/// 这样暂时不在的来源重新出现时，它的顺序与「隐藏」都还在。只有用户明确删掉来源时才经
/// [forgetMusicOnlineSource] 清掉条目。
List<LyricsProviderEntry> applyMusicOnlineSourceEdits(
  List<LyricsProviderEntry> stored,
  List<LyricsProviderEntry> visible,
) {
  final Set<String> visibleIds = <String>{
    for (final LyricsProviderEntry e in visible) e.id,
  };
  final Iterator<LyricsProviderEntry> next = visible.iterator;
  final Set<String> placed = <String>{};
  final List<LyricsProviderEntry> out = <LyricsProviderEntry>[];
  for (final LyricsProviderEntry e in stored) {
    if (!visibleIds.contains(e.id)) {
      out.add(e);
    } else if (next.moveNext()) {
      // 可见行占的槽位依次换成新顺序里的下一项。
      out.add(next.current);
      placed.add(next.current.id);
    }
  }
  for (final LyricsProviderEntry e in visible) {
    if (placed.add(e.id)) out.add(e);
  }
  return out;
}

/// 用户明确删除了来源（卸载插件 / 删除服务器）：从顺序与开关偏好里清掉它的条目。
Future<void> forgetMusicOnlineSource(
  PreferencesRepository prefs,
  String key,
) async {
  final List<LyricsProviderEntry> stored = parseLyricsProviders(
    prefs.musicOnlineSourcesRaw,
  );
  if (!stored.any((LyricsProviderEntry e) => e.id == key)) return;
  await prefs.setMusicOnlineSourcesRaw(
    serializeLyricsProviders(<LyricsProviderEntry>[
      for (final LyricsProviderEntry e in stored)
        if (e.id != key) e,
    ]),
  );
}
