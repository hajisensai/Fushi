import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 各库页「继续」主卡交互一致性守卫。
///
/// 书架 / 漫画「继续阅读」卡、视频首页「继续观看」首屏、游戏首页「继续游戏」
/// 主卡、首页 dashboard 主卡、音乐曲库主卡必须是同一套交互：整卡可点 + 长按 /
/// 右键次动作 + 外包 [FushiHoverLift] 悬停抬升。此前视频主卡只有 FushiCard 状态层
/// （被铺满的大图盖住，鼠标放上去毫无反馈），游戏主卡整卡不可点、只有两枚按钮
/// 有反馈。
///
/// 2026-10-31 起这套交互收口在一个共享件里：书 / 游戏 / 音乐 / 视频首屏走
/// `FushiContinueSpotlight`（竖封面主卡皮是 `FushiContinueHero`，横图剧照是叠层
/// 皮），首页 dashboard 同样走它。守卫钉两头：共享件自身带悬停
/// 抬升 + 整卡点按 + 右键；各页面的继续卡都经共享件而不是另画一张。
void main() {
  String src(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '缺失 $path');
    return maskComments(file.readAsStringSync());
  }

  test('共享继续卡 FushiContinueHero：悬停抬升 + 整卡点按 + 右键次动作', () {
    final String s = src('lib/src/utils/components/fushi_continue_hero.dart');
    expect(s.contains('FushiHoverLift('), isTrue);
    expect(s.contains('onTap: onOpen'), isTrue);
    expect(s.contains('onSecondaryTap: onLongPress'), isTrue);
  });

  test('继续区 FushiContinueSpotlight：剧照主卡与封面行都外包悬停抬升、整卡可点', () {
    final String s = src('lib/src/utils/components/fushi_continue_hero.dart');
    expect(
      'FushiHoverLift('.allMatches(s).length,
      greaterThanOrEqualTo(3),
      reason: '竖封面主卡、剧照主卡与封面行都必须外包悬停抬升',
    );
    expect('onTap: entry.onOpen'.allMatches(s).length, greaterThanOrEqualTo(2));
    expect(
      'onSecondaryTap: entry.onLongPress'.allMatches(s).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('封面取色并列卡 FushiContinueCardRow：悬停抬升 + 整卡点按 + 右键次动作', () {
    final String s = src(
      'lib/src/utils/components/fushi_continue_card_row.dart',
    );
    expect(s.contains('FushiHoverLift('), isTrue);
    expect(s.contains('onTap: entry.onOpen'), isTrue);
    expect(s.contains('onSecondaryTap: entry.onLongPress'), isTrue);
  });

  test('各库页继续卡都经共享件', () {
    // 2026-11-01 起书架 / 游戏库的继续区改走封面取色并列卡 FushiContinueCardRow
    // （视频首页宽屏时作为大卡旁的 sideBuilder 用它，大卡仍是 Spotlight）。
    const Map<String, String> pages = <String, String>{
      'lib/src/pages/implementations/reader_fushi_history_page.dart':
          'FushiContinueCardRow.grid(',
      'lib/src/pages/implementations/games_library_page.dart':
          'FushiContinueCardRow.grid(',
      'lib/src/pages/implementations/galgame_home_page.dart':
          'FushiContinueSpotlight(',
      'lib/src/pages/implementations/home_dashboard_page.dart':
          'FushiContinueSpotlight(',
      'lib/src/pages/implementations/music/music_library_page.dart':
          'FushiContinueSpotlight(',
      'lib/src/pages/implementations/home_video_page.dart':
          'FushiContinueSpotlight(',
    };
    for (final MapEntry<String, String> e in pages.entries) {
      expect(
        src(e.key).contains(e.value),
        isTrue,
        reason: '${e.key} 的继续卡必须用 ${e.value}',
      );
    }
  });

  test('游戏首页继续游戏：整卡点按 = 启动，长按 / 右键 = 详情', () {
    final String s = src(
      'lib/src/pages/implementations/galgame_home_page.dart',
    );
    final int start = s.indexOf('Widget _buildHero(');
    expect(start, greaterThanOrEqualTo(0));
    final String body = s.substring(start, s.indexOf('\n  Widget ', start + 1));
    expect(body.contains('onOpen: () => unawaited(_launchGame(game))'), isTrue);
    expect(
      body.contains('onLongPress: () => unawaited(_openDetail(game))'),
      isTrue,
    );
  });
}
