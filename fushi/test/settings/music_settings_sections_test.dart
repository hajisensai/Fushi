import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_music.dart';

List<String> _allIds(SettingsDestination d) => <String>[
  for (final SettingsSection s in d.sections)
    for (final SettingsItem i in s.items) i.id,
];

/// 反馈 983broef-P：音乐设置前三组没有分组标题（与视频 / 有声书不一致），且有一条
/// 「打开曲库」跳页捷径——它不是设置，其他媒体分类也没有。后续：来源管理（本地文件夹 /
/// 插件音源）也照其他媒体，只留在模块页（曲库页顶栏「来源」），设置里不再各挂一份。
void main() {
  test('every music settings section has a title', () {
    final SettingsDestination d = buildMusicDestination();
    final List<String?> titles = <String?>[
      for (final SettingsSection s in d.sections) s.title,
    ];
    expect(titles, isNot(contains(null)));
    expect(titles.where((String? x) => x!.trim().isEmpty), isEmpty);
    // 首组是播放，紧接输出；识别不再是「第一个有标题的组」。
    expect(titles.take(2), <String>[
      t.music_playback_section,
      t.music_output_section,
    ]);
  });

  test(
    'music settings have no shortcut that merely jumps to the music tab',
    () {
      expect(
        _allIds(buildMusicDestination()),
        isNot(contains('music.library')),
      );
    },
  );

  test('music settings carry no source / plugin management (same as other '
      'media categories; managed only from the library "Sources" page)', () {
    final SettingsDestination d = buildMusicDestination();
    final List<String> ids = _allIds(d);
    expect(ids, isNot(contains('music.sources')));
    expect(ids, isNot(contains('music.plugins')));
    expect(
      d.sections.map((SettingsSection s) => s.title),
      isNot(contains(t.music_plugins_title)),
    );
    // 服务器凭据 / 端点与歌词来源仍是设置（对应视频的媒体服务器 / 字幕来源）。
    expect(
      ids,
      containsAll(<String>['music.servers', 'music.lyrics_providers']),
    );
  });
}
