// 游戏「游玩状态」的外显（文案 + 色点），游戏库 / 游戏首页（两套版面）/ 详情 / 条目
// 菜单共用。单独成叶子文件：首页的 Apple 版面要用它，而 `games_library_page.dart`
// 在 lib/ 的大 import 环里（`test/build/import_cycle_guard_test.dart`）。
// `games_library_page.dart` 与 `galgame_home_blocks.dart` 原样 re-export。

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/galgame_library.dart';

/// 游玩状态的用户可读标签（枚举 `.name` 直接上屏是 17 语言用户的灾难）。
String galgamePlayStatusLabel(GalgamePlayStatus status) => switch (status) {
  GalgamePlayStatus.unset => t.game_status_unset,
  GalgamePlayStatus.wantToPlay => t.game_status_want_to_play,
  GalgamePlayStatus.played => t.game_status_played,
  GalgamePlayStatus.playing => t.game_status_playing,
  GalgamePlayStatus.onHold => t.game_status_on_hold,
  GalgamePlayStatus.dropped => t.game_status_dropped,
};

/// 6 档游玩状态的色点（设计稿第 6 节，深 / 浅两套；chip 底 = 色点 24% 叠在容器
/// 色上，文字用容器 onColor，两套都 ≥4.5:1）。
Color galgamePlayStatusDotColor(GalgamePlayStatus status, Brightness b) {
  final bool dark = b == Brightness.dark;
  return switch (status) {
    GalgamePlayStatus.unset =>
      dark ? const Color(0xFF8F8B96) : const Color(0xFF6B6E7B),
    GalgamePlayStatus.wantToPlay =>
      dark ? const Color(0xFFA9C8FF) : const Color(0xFF2F62C9),
    GalgamePlayStatus.playing =>
      dark ? const Color(0xFF9BE0AB) : const Color(0xFF1D8A45),
    GalgamePlayStatus.played =>
      dark ? const Color(0xFFE7CF6F) : const Color(0xFF8A6A00),
    GalgamePlayStatus.onHold =>
      dark ? const Color(0xFFC9C6CF) : const Color(0xFF5D5A66),
    GalgamePlayStatus.dropped =>
      dark ? const Color(0xFFFF9B9B) : const Color(0xFFB3261E),
  };
}
