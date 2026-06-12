import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-154 防回归源码守卫：跨字幕录制特性（TODO-102，参考 asbplayer 的多句拼接制卡）
/// 已整特性下线（用户决策档 B，字幕列表可替代）。本守卫钉死该特性的所有 symbol /
/// i18n key / 独立文件都不再出现，防止后续误把它重新引入。
///
/// media_kit 跑不了 headless，故按既有视频守卫范式（见 video_controls_cleanup_guard_test）
/// 在源码层断言不变量。
void main() {
  /// 跨字幕录制相关的所有源码 symbol（任一出现即视为特性复活）。
  const List<String> bannedSymbols = <String>[
    'CrossSubtitleRecorder',
    'CrossSubtitleSelection',
    'CrossSubtitleAudioRange',
    '_crossSubRecorder',
    '_toggleCrossSubtitleRecording',
    '_mineCrossSubtitleSelection',
    '_buildCrossSubtitleRecordButton',
    '_buildCrossSubtitleRecordingOverlay',
    'toggleCrossSubtitleRecording',
    'videoToggleCrossSubtitleRecording',
    '_lastMineFields',
  ];

  /// 跨字幕录制相关的所有 i18n key 前缀（任一出现即视为特性复活）。
  const List<String> bannedI18nKeys = <String>[
    'video_cross_subtitle',
    'video_menu_cross_subtitle',
    'shortcut_action_video_toggle_cross_subtitle_recording',
  ];

  test('独立文件 cross_subtitle_recorder.dart 已删除', () {
    expect(
      File('lib/src/media/video/cross_subtitle_recorder.dart').existsSync(),
      isFalse,
      reason: '跨字幕录制独立文件必须删除（TODO-154 整特性下线）',
    );
  });

  test('视频页 / 快捷键源码无任何跨字幕录制 symbol', () {
    final List<String> sources = <String>[
      'lib/src/pages/implementations/video_hibiki_page.dart',
      'lib/src/media/video/video_player_shortcuts.dart',
      'lib/src/shortcuts/shortcut_action.dart',
      'lib/src/shortcuts/shortcut_defaults.dart',
      'lib/src/pages/implementations/shortcut_settings_page.dart',
    ];
    for (final String path in sources) {
      final String src = File(path).readAsStringSync();
      for (final String symbol in bannedSymbols) {
        expect(src.contains(symbol), isFalse,
            reason: '$path 仍含已下线的跨字幕录制 symbol「$symbol」');
      }
    }
  });

  test('i18n 源文件无任何跨字幕录制 key', () {
    final Directory i18nDir = Directory('lib/i18n');
    for (final FileSystemEntity entity in i18nDir.listSync()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.i18n.json')) continue;
      final String content = entity.readAsStringSync();
      for (final String key in bannedI18nKeys) {
        expect(content.contains(key), isFalse,
            reason: '${entity.path} 仍含已下线的跨字幕录制 i18n key「$key」');
      }
    }
  });
}
