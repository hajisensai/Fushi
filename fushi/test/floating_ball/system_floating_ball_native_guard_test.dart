import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_floating_ball.dart';

/// BUG-2793：Android 应用外悬浮球吸边不对、点球会闪、旋转后消失、菜单与应用内不一致。
///
/// 原生侧没有 JVM 单测装置，这里按源码钉住四个根因各自的修法——任何一条退回，
/// 对应的症状就会回来（真机证据见 docs/bugs/BUG-2793-system-floating-ball.md）。
const String _dir = 'android/app/src/main/java/app/fushi/reader';

String _read(String name) =>
    File('$_dir/$name').readAsStringSync().replaceAll('\r\n', '\n');

int _intConst(String src, String name) => int.parse(
  RegExp('static final int $name = (\\d+);').firstMatch(src)!.group(1)!,
);

double _floatConst(String src, String name) => double.parse(
  RegExp('static final float $name = ([\\d.]+)f;').firstMatch(src)!.group(1)!,
);

void main() {
  final String geometry = _read('FloatingBallGeometry.java');
  final String service = _read('FloatingBallService.java');

  test('几何常量与应用内球同值（两边观感一致）', () {
    expect(_intConst(geometry, 'BALL_DP').toDouble(), kReaderFloatingBallSize);
    expect(
      _intConst(geometry, 'BUTTON_DP').toDouble(),
      kReaderFloatingBallButtonSize,
    );
    expect(_intConst(geometry, 'GAP_DP').toDouble(), kReaderFloatingBallGap);
    expect(
      _intConst(geometry, 'MARGIN_DP').toDouble(),
      kReaderFloatingBallMargin,
    );
    expect(
      _floatConst(geometry, 'IDLE_OPACITY'),
      closeTo(kReaderFloatingBallIdleOpacity, 1e-6),
    );
    // 收起外缩比例：Dart 写在 tuck getter 里（ballSize * 0.34）。
    expect(
      File(
        'lib/src/reader/reader_floating_ball.dart',
      ).readAsStringSync().contains('double get tuck => ballSize * 0.34;'),
      isTrue,
    );
    expect(_floatConst(geometry, 'TUCK_RATIO'), closeTo(0.34, 1e-6));
  });

  test('吸边：窗口坐标与视口同一个坐标系（整块显示区 + 自己扣 inset）', () {
    final int start = service.indexOf(
      'private void configureOverlayParams(WindowManager.LayoutParams lp) {',
    );
    expect(start, isNot(-1));
    final String body = service.substring(
      start,
      service.indexOf('\n    }\n', start),
    );
    expect(body, contains('lp.setFitInsetsTypes(0);'));
    expect(body, contains('FLAG_LAYOUT_IN_SCREEN'));
    expect(body, contains('LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS'));
    // 视口 = 显示区扣系统栏与刘海，不能再拿整屏当活动范围。
    expect(
      service,
      contains(
        'WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()',
      ),
    );
  });

  test('点球不闪：球窗固定尺寸，按钮在另一个按最终几何建好的窗口里', () {
    final int start = service.indexOf(
      'protected WindowManager.LayoutParams createLayoutParams() {',
    );
    final String body = service.substring(
      start,
      service.indexOf('\n    }\n', start),
    );
    expect(body, isNot(contains('WRAP_CONTENT')));
    expect(body, contains('lp.width = size;'));
    expect(body, contains('lp.height = size;'));
    expect(service, contains('private void ensureMenuWindow() {'));
    // 旧实现的「窗口先变宽、下一帧再挪回来」那一步不能回来。
    expect(service, isNot(contains('rootView.post(this::snapToEdge)')));
  });

  test('旋转不丢：位置存停靠边 + 比例，显示变化按新视口重摆', () {
    final int start = service.indexOf('protected void savePosition() {');
    final String body = service.substring(
      start,
      service.indexOf('\n    }\n', start),
    );
    expect(body, contains('PREF_DOCK'));
    expect(body, contains('PREF_FRACTION'));
    expect(body, isNot(contains('POS_X')));
    expect(service, contains('public void onConfigurationChanged('));
    expect(service, contains('registerDisplayListener(displayListener'));
    expect(service, contains('relayoutForDisplayChange();'));
    // 显示事件远不止旋转：视口没变不能收起，否则高刷设备上刚展开就被收掉。
    expect(service, contains('if (vp.equals(lastViewport)) return;'));
  });

  test('拖动不被系统边缘返回手势抢走：球从系统手势里排除', () {
    // 球贴边（收起还外缩 1/3），整颗在手势导航的边缘返回热区里；不排除的话从球上
    // 起手的横向拖动会被系统抢走（ACTION_CANCEL），球挪一点就弹回原边。
    expect(service, contains('setSystemGestureExclusionRects('));
  });

  test('按钮图标 / 配色来自 Dart（与应用内同一颗 IconData、同一套主题色）', () {
    expect(service, contains('PREF_ICONS'));
    expect(service, contains('PREF_COLORS'));
    // 图标是 FushiIcons 语义图标（FushiSymbols 字体码位），不再是 Material Icons。
    expect(service, contains('assets/icon_fonts/FushiSymbolsRounded.ttf'));
    expect(service, isNot(contains('MaterialIcons-Regular.otf')));
    // 球面 = 主题色 FAB + 与应用内同一只吉祥物、同一放大倍数。
    expect(service, contains('"$kReaderFloatingBallIconAsset"'));
    expect(
      _floatConst(service, 'MASCOT_SCALE'),
      closeTo(kReaderFloatingBallMascotScale, 1e-6),
    );
    // M3E 配色角色：球本体 / tonal 圆钮 / 墨水屏描边都取 Dart 下发的主题色。
    for (final String key in <String>[
      'ballContainer',
      'buttonContainer',
      'onButtonContainer',
      'outline',
    ]) {
      expect(service, contains('"$key"'));
    }
    final String channel = _read('FloatingBallChannel.java');
    expect(channel, contains('intMap(call.argument("icons"))'));
    expect(channel, contains('intMap(call.argument("colors"))'));
  });
}
