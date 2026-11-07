import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_music.dart';

/// 反馈 983broef-P：音乐设置前三组没有分组标题（与视频 / 有声书不一致），且有一条
/// 「打开曲库」跳页捷径——它不是设置，其他媒体分类也没有。
void main() {
  test('every music settings section has a title', () {
    final SettingsDestination d = buildMusicDestination();
    final List<String?> titles = <String?>[
      for (final SettingsSection s in d.sections) s.title,
    ];
    expect(titles, isNot(contains(null)));
    expect(titles.where((String? x) => x!.trim().isEmpty), isEmpty);
    // 首组是曲库（来源管理），紧接播放与输出，识别不再是「第一个有标题的组」。
    expect(titles.take(3), <String>[
      t.music_library_section,
      t.music_playback_section,
      t.music_output_section,
    ]);
  });

  test(
    'music settings have no shortcut that merely jumps to the music tab',
    () {
      final SettingsDestination d = buildMusicDestination();
      final List<String> ids = <String>[
        for (final SettingsSection s in d.sections)
          for (final SettingsItem i in s.items) i.id,
      ];
      expect(ids, isNot(contains('music.library')));
      // 来源管理是真设置（共用来源对话框），保留且在首组。
      expect(d.sections.first.items.map((SettingsItem i) => i.id), <String>[
        'music.sources',
      ]);
    },
  );
}
