// 音乐在线来源的顺序与「推荐 / 搜索里显示」开关（偏好 `music_online_sources`）：
// 排序合并、写回时保留这次没加载到的来源、明确删除时才清条目。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/lyrics_provider_list.dart';
import 'package:fushi/src/media/music/music_online_sources.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 只有 key / 名字的来源替身（排序逻辑只看 key）。
final class _Source extends MusicOnlineSource {
  const _Source(this.key);

  @override
  final String key;

  @override
  String get name => key;
}

LyricsProviderEntry _e(String id, {bool enabled = true}) =>
    LyricsProviderEntry(id: id, enabled: enabled);

List<String> _keys(List<MusicOrderedSource> ordered) => <String>[
  for (final MusicOrderedSource o in ordered) o.source.key,
];

void main() {
  group('orderMusicOnlineSources', () {
    test('按已存顺序与开关排；没登记过的按加载顺序追加在末尾、默认显示', () {
      final List<MusicOrderedSource> ordered = orderMusicOnlineSources(
        const <MusicOnlineSource>[_Source('a'), _Source('new'), _Source('b')],
        <LyricsProviderEntry>[_e('b', enabled: false), _e('a')],
      );
      expect(_keys(ordered), <String>['b', 'a', 'new']);
      expect(ordered[0].enabled, isFalse, reason: '已存的 enabled=false 保留');
      expect(ordered[2].enabled, isTrue);
      expect(
        enabledMusicOnlineSources(ordered).map((MusicOnlineSource s) => s.key),
        <String>['a', 'new'],
      );
    });

    test('已存但这次没加载到的来源不出现在结果里', () {
      final List<MusicOrderedSource> ordered = orderMusicOnlineSources(
        const <MusicOnlineSource>[_Source('a')],
        <LyricsProviderEntry>[_e('gone'), _e('a')],
      );
      expect(_keys(ordered), <String>['a']);
    });
  });

  group('applyMusicOnlineSourceEdits', () {
    test('不在场的条目原样保留在原相对位置，可见行在自己的槽位里按新顺序排', () {
      final List<LyricsProviderEntry> stored = <LyricsProviderEntry>[
        _e('a'),
        _e('off', enabled: false),
        _e('b'),
        _e('c'),
      ];
      // 可见：a b c（off 被停用、没加载到）；用户把 c 挪到最前并关掉 a。
      final List<LyricsProviderEntry> out = applyMusicOnlineSourceEdits(
        stored,
        <LyricsProviderEntry>[_e('c'), _e('a', enabled: false), _e('b')],
      );
      expect(out, <LyricsProviderEntry>[
        _e('c'),
        _e('off', enabled: false),
        _e('a', enabled: false),
        _e('b'),
      ]);
    });

    test('没登记过的可见行追加在末尾', () {
      expect(
        applyMusicOnlineSourceEdits(
          <LyricsProviderEntry>[_e('x', enabled: false), _e('a')],
          <LyricsProviderEntry>[_e('a'), _e('new')],
        ),
        <LyricsProviderEntry>[_e('x', enabled: false), _e('a'), _e('new')],
      );
    });

    test('停用插件 → 排序 → 重新启用：它的顺序与隐藏都还在', () {
      List<LyricsProviderEntry> stored = <LyricsProviderEntry>[
        _e('plugin:p', enabled: false),
        _e('server:s1'),
        _e('server:s2'),
      ];
      // 插件停用：来源页只看到两台服务器，用户交换它俩。
      final List<MusicOrderedSource> visible = orderMusicOnlineSources(
        const <MusicOnlineSource>[_Source('server:s1'), _Source('server:s2')],
        stored,
      );
      stored = applyMusicOnlineSourceEdits(stored, <LyricsProviderEntry>[
        for (final MusicOrderedSource o in visible.reversed)
          _e(o.source.key, enabled: o.enabled),
      ]);
      // 插件重新启用。
      final List<MusicOrderedSource> back = orderMusicOnlineSources(
        const <MusicOnlineSource>[
          _Source('server:s1'),
          _Source('server:s2'),
          _Source('plugin:p'),
        ],
        stored,
      );
      expect(_keys(back), <String>['plugin:p', 'server:s2', 'server:s1']);
      expect(back.first.enabled, isFalse);
    });
  });

  test('forgetMusicOnlineSource：明确删除才清条目，其余不动', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setMusicOnlineSourcesRaw(
      serializeLyricsProviders(<LyricsProviderEntry>[
        _e('plugin:p', enabled: false),
        _e('server:s1'),
      ]),
    );
    await forgetMusicOnlineSource(prefs, 'plugin:p');
    expect(
      parseLyricsProviders(prefs.musicOnlineSourcesRaw),
      <LyricsProviderEntry>[_e('server:s1')],
    );
    // 不在列表里：no-op。
    await forgetMusicOnlineSource(prefs, 'plugin:missing');
    expect(
      parseLyricsProviders(prefs.musicOnlineSourcesRaw),
      <LyricsProviderEntry>[_e('server:s1')],
    );
  });
}
