import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/scan_scale.dart';
import '../helpers/source_guard.dart';

/// BUG-4387 / BUG-4893：Windows 上「画面在动、鼠标键盘全失灵」的两道结构守卫。
///
/// 1. `lib` 下不得调 `SchedulerBinding.scheduleTask`。它在调度策略不放行时用零延迟
///    定时器把自己一圈圈重排，Windows 嵌入层每圈一条 posted 消息，输入永远排不上。
///    等空闲用 `waitForUiIdle`（按帧复查，不空转）。
/// 2. 每个调 `.repeat(` 的文件都要表态：应用级常驻装饰（必须走 ambient ticker，不算
///    「有动画在跑」），还是随某个状态存续（播放 / 加载 / 录制，状态结束就停）。
///    吉祥物光晕就是没表态的常驻装饰——开着它启动，等空闲的工作永远等不到。
const String _ambientMixin = 'AmbientTickerProviderStateMixin';

/// 应用级常驻装饰动画：只要开关开着就一直循环，与用户在哪一页、在做什么无关。
const Set<String> _ambientRepeatFiles = <String>{
  'lib/src/utils/components/mascot_glow.dart',
  'lib/src/utils/components/page_backdrop_layer.dart',
};

/// 随状态存续的循环动画 → 它跟着哪个状态停。新增条目前先想清楚：启动后不经任何用户
/// 操作就会一直转的，属于上面那一类。
const Map<String, String> _stateBoundRepeatFiles = <String, String>{
  'lib/src/media/video/video_danmaku_overlay.dart': '弹幕：视频在播且弹幕开着',
  'lib/src/media/video/video_m3e_chrome.dart': '进度条波浪：视频在播',
  'lib/src/pages/implementations/home_widget_grid.dart': '编辑态抖动：主页小组件在编辑态',
  'lib/src/pages/implementations/music/music_lyrics_page.dart': '唱片旋转：音乐在播',
  'lib/src/pages/implementations/shortcut_settings/shortcut_browser.part.dart':
      '录制脉冲：正在录快捷键',
  'lib/src/utils/components/fushi_expressive_progress.dart': '进度指示器：不定态或进度在变',
  'lib/src/utils/components/fushi_m3e_feedback.dart': '骨架屏扫光：有限圈数',
  'lib/src/utils/components/glass/fushi_glass_feedback.dart': '玻璃进度条：不定态',
};

final RegExp _scheduleTaskCall = RegExp(
  r'(?<![A-Za-z0-9_$])scheduleTask\s*(?:<[^>()]*>)?\s*\(',
);
final RegExp _repeatCall = RegExp(r'\.\s*repeat\s*\(');

void main() {
  test('判据自校验：只认真正的 scheduleTask 调用', () {
    expect(
      _scheduleTaskCalls('''
// SchedulerBinding.instance.scheduleTask(() {}, Priority.idle);
/* binding.scheduleTask<void>(() {}, Priority.idle) */
final String hint = 'scheduleTask(() {}, Priority.idle)';
void _scheduleTask() {}
void run() => _scheduleTask();
final Future<void> a = SchedulerBinding.instance.scheduleTask<void>(
  () {},
  Priority.idle,
);
final Future<int> b = binding.scheduleTask(() => 1, Priority.animation);
final Future<void> c = binding.scheduleTask <void> (() {}, Priority.touch);
'''),
      3,
    );
  });

  test('lib 下不调 SchedulerBinding.scheduleTask（等空闲用 waitForUiIdle）', () {
    final List<String> offenders = <String>[];
    int scanned = 0;
    for (final File file in _dartFiles()) {
      scanned++;
      if (_scheduleTaskCalls(file.readAsStringSync()) > 0) {
        offenders.add(_normalize(file.path));
      }
    }
    expectScanScale(
      scanned,
      what: 'fushi/lib + packages/*/lib 的 .dart',
      atLeast: 3000,
      measured: 3972,
    );
    expect(
      offenders,
      isEmpty,
      reason:
          'scheduleTask 在调度策略不放行时零延迟空转，饿死 Windows 输入（BUG-4387 / '
          'BUG-4893）。等空闲改用 lib/src/utils/scheduling/ambient_ticker.dart 的 '
          'waitForUiIdle。',
    );
  });

  test('判据自校验：只认真正的 .repeat( 调用', () {
    expect(
      _repeatCalls('''
// controller.repeat();
final String hint = 'controller.repeat(reverse: true)';
const ImageRepeat tile = ImageRepeat.repeat;
void run(AnimationController controller) {
  controller.repeat(reverse: true);
  controller
    ..stop()
    ..repeat();
}
'''),
      2,
    );
  });

  test('每个循环动画都表了态：常驻装饰走 ambient ticker，其余写明跟着什么停', () {
    final Set<String> actual = <String>{};
    int scanned = 0;
    for (final File file in _dartFiles(includePackages: false)) {
      scanned++;
      if (_repeatCalls(file.readAsStringSync()) > 0) {
        actual.add(_normalize(file.path));
      }
    }
    expectScanScale(
      scanned,
      what: 'fushi/lib 的 .dart',
      atLeast: 2200,
      measured: 2786,
    );
    final Set<String> declared = <String>{
      ..._ambientRepeatFiles,
      ..._stateBoundRepeatFiles.keys,
    };
    expect(
      _ambientRepeatFiles.intersection(_stateBoundRepeatFiles.keys.toSet()),
      isEmpty,
      reason: '一个文件只能归一类',
    );
    expect(
      actual.difference(declared),
      isEmpty,
      reason:
          '新的 .repeat( 循环动画没表态。开关开着就一直转、与页面无关的装饰 → 用 '
          '$_ambientMixin 并登记进 _ambientRepeatFiles；随播放 / 加载等状态存续的 → '
          '登记进 _stateBoundRepeatFiles 并写明跟着什么停。',
    );
    expect(
      declared.difference(actual),
      isEmpty,
      reason: '清单里的文件已经没有 .repeat( 了，把陈旧条目删掉',
    );
    for (final String path in _ambientRepeatFiles) {
      final String code = maskCommentsAndStrings(File(path).readAsStringSync());
      expect(
        code.contains(_ambientMixin),
        isTrue,
        reason: '$path 登记为常驻装饰动画，ticker 必须由 $_ambientMixin 提供',
      );
      expect(
        RegExp(
          r'\b(?:Single)?TickerProviderStateMixin\b',
        ).hasMatch(code.replaceAll(_ambientMixin, '')),
        isFalse,
        reason: '$path 里的常驻装饰动画不能再混用普通 ticker provider',
      );
    }
  });
}

/// 私有同名 helper（`_scheduleTask()`）由正则的前瞻排除，不算。
int _scheduleTaskCalls(String source) =>
    _scheduleTaskCall.allMatches(maskCommentsAndStrings(source)).length;

int _repeatCalls(String source) =>
    _repeatCall.allMatches(maskCommentsAndStrings(source)).length;

String _normalize(String path) => path.replaceAll(r'\', '/');

Iterable<File> _dartFiles({bool includePackages = true}) sync* {
  final List<Directory> roots = <Directory>[Directory('lib')];
  if (includePackages) {
    for (final FileSystemEntity package in Directory(
      '../packages',
    ).listSync()) {
      if (package is! Directory) continue;
      final Directory lib = Directory('${package.path}/lib');
      if (lib.existsSync()) roots.add(lib);
    }
  }
  for (final Directory root in roots) {
    for (final FileSystemEntity entry in root.listSync(recursive: true)) {
      if (entry is! File) continue;
      final String path = _normalize(entry.path);
      if (!path.endsWith('.dart') || path.endsWith('.g.dart')) continue;
      yield entry;
    }
  }
}
