import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// 各库页「继续」主卡交互一致性守卫。
///
/// 书架 / 漫画「继续阅读」卡、视频首页「继续观看」主卡、游戏首页「继续游戏」
/// 主卡、首页 dashboard 主卡必须是同一套交互：整卡可点 + 外包 [FushiHoverLift]
/// 悬停抬升。此前视频主卡只有 FushiCard 状态层（被铺满的大图盖住，鼠标放上去
/// 毫无反馈），游戏主卡整卡不可点、只有两枚按钮有反馈。
void main() {
  String src(String path) {
    final File file = File(path);
    expect(file.existsSync(), isTrue, reason: '缺失 $path');
    return maskComments(file.readAsStringSync());
  }

  test('书架 / 漫画继续阅读卡：整卡外包 FushiHoverLift', () {
    final String s = src(
      'lib/src/pages/implementations/reader_fushi_history_page.dart',
    );
    final int start = s.indexOf('Widget _buildContinueReadingHero(');
    expect(start, greaterThanOrEqualTo(0));
    final String body = s.substring(start, s.indexOf('\n  Widget ', start + 1));
    expect(body.contains('FushiHoverLift('), isTrue);
  });

  test('视频首页继续观看：竖排卡与横排卡两处调用点都经 _liftHomeHero', () {
    final String s = src('lib/src/pages/implementations/home_video_page.dart');
    expect(
      '_liftHomeHero(_buildHomeHeroCard('.allMatches(s).length,
      1,
      reason: '竖排主卡必须外包悬停抬升',
    );
    expect(
      '_liftHomeHero(_buildHomeHeroOverlay('.allMatches(s).length,
      '_buildHomeHeroOverlay('.allMatches(s).length - 1,
      reason: '横排主卡的每个调用点都必须外包悬停抬升',
    );
    final int def = s.indexOf('Widget _liftHomeHero(');
    expect(def, greaterThanOrEqualTo(0));
    expect(s.substring(def, def + 200).contains('FushiHoverLift('), isTrue);
  });

  test('游戏首页继续游戏：整卡可点 + 外包 FushiHoverLift', () {
    final String s = src(
      'lib/src/pages/implementations/galgame_home_page.dart',
    );
    final int start = s.indexOf('Widget _buildHero(');
    expect(start, greaterThanOrEqualTo(0));
    final String body = s.substring(start, s.indexOf('\n  Widget ', start + 1));
    expect(body.contains('onTap: () => unawaited(_launchGame(game))'), isTrue);
    expect(body.contains('onSecondaryTap:'), isTrue);
    expect(body.contains('FushiHoverLift('), isTrue);
  });
}
