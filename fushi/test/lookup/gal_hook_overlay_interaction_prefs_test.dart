import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 用户在 galgame 浮窗上提的四条：
///   ①「鼠标穿透开/关时这功能栏样式还不一样，统一用这个短的舒服点」
///   ②「加个 luna 那样的：鼠标移动到栏位的地方才显现功能栏，平时功能栏隐藏」
///   ③「这个 hook 文本框，能关闭鼠标单击不要查词吗，至少开启穿透的时候……
///      还是习惯用侧键查」
///   ④「穿透不彻底等于彻底不穿透……我想点击文字底下的东西点不到了」
///
/// ①② 落在 runner 的 C++ 里（下半段的源码守卫），③④ 需要偏好 + 通道 + 设置项
/// 三段接线，这里咬住偏好这一段与「设置项必须 live 下发」这条纪律。
FushiDatabase _testDb() => FushiDatabase.forTesting(NativeDatabase.memory());

/// 精确截取一个 C++ 函数体（花括号配平）。
///
/// **不要**改回「从签名往后取固定长度窗口」：这几个函数是挨着定义的，窗口一溢出就
/// 会读到下一个函数——`CursorInToolbarRevealZone` 后面紧跟的 `SyncPassThroughToolbar`
/// 里也有 `ComputePassThroughToolbarLayout()`，于是「揭示区算不算工具条矩形」这条
/// 断言恒真。变异实测抓到过这一次空转。
///
/// 前提：传进来的 source 已经剥过注释。
String cppBody(String source, String signature) {
  final int at = source.indexOf(signature);
  expect(at, isNonNegative, reason: '找不到 $signature');
  final int braceAt = source.indexOf('{', at + signature.length);
  expect(braceAt, isNonNegative, reason: '$signature 后面找不到函数体');
  int depth = 0;
  for (int j = braceAt; j < source.length; j++) {
    if (source[j] == '{') depth++;
    if (source[j] == '}') {
      depth--;
      if (depth == 0) return source.substring(at, j + 1);
    }
  }
  fail('找不到 $signature 的函数体结尾');
}

File runnerFile(String name) {
  // 测试的 cwd 是 fushi/。
  return File('windows/runner/$name');
}

void main() {
  group('偏好：默认值与值域', () {
    late FushiDatabase db;
    late PreferencesRepository prefs;

    setUp(() async {
      db = _testDb();
      prefs = PreferencesRepository(db);
      await prefs.loadFromDb();
    });

    tearDown(() async {
      prefs.dispose();
      await db.close();
    });

    test('单击查词默认开（不改变老用户的手感）', () {
      expect(prefs.galHookClickLookup, isTrue);
    });

    test('触发方式默认左键，写入后读得回来', () async {
      expect(prefs.galHookLookupTrigger, 0);
      await prefs.setGalHookLookupTrigger(2);
      expect(prefs.galHookLookupTrigger, 2);
    });

    test('触发方式越界值退回默认，而不是让 native 分派到「哪个键都不触发」', () async {
      await prefs.setPref('gal_hook_lookup_trigger', 9);
      expect(prefs.galHookLookupTrigger, 0);
      await prefs.setPref('gal_hook_lookup_trigger', -1);
      expect(prefs.galHookLookupTrigger, 0);
    });

    test('写入时先夹再落库（坏值不进 DB）', () async {
      await prefs.setGalHookLookupTrigger(7);
      expect(prefs.getPref('gal_hook_lookup_trigger'), 2);
    });

    test('工具条自动隐藏默认开（用户明确要 luna 那样的行为）', () {
      expect(prefs.galHookToolbarAutoHide, isTrue);
    });

    test('穿透时仍拦截鼠标默认开（点字查词是既有行为，不能被这次改动掀掉）', () {
      expect(prefs.galHookPassThroughBlocksMouse, isTrue);
    });

    test('四个键都登记进了偏好键名单', () {
      // preference_keys.dart 是唯一的新增键入口，守卫测试会扫调用点的字面量键；
      // 漏登记 = 那条守卫红。
      expect(
        kKnownPreferenceKeys,
        containsAll(<String>[
          'gal_hook_click_lookup',
          'gal_hook_lookup_trigger',
          'gal_hook_toolbar_auto_hide',
          'gal_hook_passthrough_blocks_mouse',
        ]),
      );
    });
  });

  group('设置项必须 live 下发（只落盘 = 本局不生效）', () {
    late String schema;

    setUpAll(() {
      schema = maskComments(
        File('lib/src/settings/settings_schema_game.dart').readAsStringSync(),
      );
    });

    test('四个开关各自接了对应的 channel setter', () {
      // 这一页自己的注释就写着这条纪律：「写完 pref 立刻推给编排器，否则开关只落了
      // 盘，本局游戏里不生效（要退出重进一局）」。
      expect(schema, contains('setClickLookupEnabled('));
      expect(schema, contains('setLookupTrigger('));
      expect(schema, contains('setToolbarAutoHide('));
      expect(schema, contains('setPassThroughBlocksMouse('));
    });

    test('每个 setter 都紧跟在对应的 pref 写入之后', () {
      for (final List<String> pair in <List<String>>[
        <String>['setGalHookClickLookup(', 'setClickLookupEnabled('],
        <String>['setGalHookLookupTrigger(', 'setLookupTrigger('],
        <String>['setGalHookToolbarAutoHide(', 'setToolbarAutoHide('],
        <String>[
          'setGalHookPassThroughBlocksMouse(',
          'setPassThroughBlocksMouse(',
        ],
      ]) {
        final int writeAt = schema.indexOf(pair[0]);
        final int pushAt = schema.indexOf(pair[1]);
        expect(writeAt, isNonNegative, reason: '找不到 ${pair[0]}');
        expect(pushAt, greaterThan(writeAt),
            reason: '${pair[1]} 必须排在 ${pair[0]} 之后。');
      }
    });
  });

  group('通道：show 载荷带上四项（此前 clickLookupEnabled 写死 true）', () {
    late String channel;

    setUpAll(() {
      channel = maskComments(
        File('lib/src/platform/gal_hook_text_overlay_channel.dart')
            .readAsStringSync(),
      );
    });

    test('clickLookupEnabled 不再是硬编码的 true', () {
      expect(channel.contains("'clickLookupEnabled': true"), isFalse,
          reason: 'native 侧一直支持这个开关，缺的就是 Dart 这一层——写死 true 等于'
              '设置里永远没有它。');
      expect(channel, contains("'clickLookupEnabled': clickLookupEnabled"));
    });

    test('三个新字段随会话下发', () {
      expect(channel, contains("'lookupTrigger': lookupTrigger"));
      expect(channel, contains("'toolbarAutoHide': toolbarAutoHide"));
      expect(channel,
          contains("'passThroughBlocksMouse': passThroughBlocksMouse"));
    });
  });

  group('runner C++：功能栏统一 + 自动隐藏 + 触发方式', () {
    late String window;

    setUpAll(() {
      window = maskComments(
        runnerFile('floating_lyric_window.cpp').readAsStringSync(),
      );
    });

    test('① hook 台词模式一律不在正文窗里画工具栏（两副长相收敛成一副）', () {
      expect(
          window, contains('const bool draw_body_toolbar = !hook_text_mode_;'),
          reason: '此前是 !(hook_text_mode_ && pass_through_)：穿透关时画正文内的'
              '全窗宽长条，穿透开时才用独立短药丸 —— 同一个功能栏两副长相。');
    });

    test('① 正文里的按钮命中一起撤掉（否则是一排看不见却点得中的幽灵按钮）', () {
      expect(
          cppBody(window, 'std::string FloatingLyricWindow::ControlActionAt'),
          contains('if (hook_text_mode_ || !hovered_)'));
    });

    test('① 工具条窗不再以 pass_through_ 为条件', () {
      expect(
        window,
        contains('const bool want_toolbar = hook_text_mode_ && visible_;'),
        reason: '统一之后工具条在两种穿透状态下都是同一个独立窗。',
      );
    });

    test('② 自动隐藏是真隐藏，不是降 alpha', () {
      final String body =
          cppBody(window, 'bool FloatingLyricWindow::ApplyToolbarVisibility');
      final int branchAt = body.indexOf('ToolbarAutoHideActive() && !toolbar_revealed_');
      expect(branchAt, isNonNegative);
      // **必须只在自动隐藏那一支里取 Hide()**：函数上面还有一个「不是 hook 台词
      // 模式 / 不可见」的 early-return，它也调 Hide()。整段 contains 会被那一处顶着
      // ——把自动隐藏分支里的 Hide() 换成降 alpha 的 Sync(...)，断言照样绿，而这条
      // 用例的 reason 说的恰恰就是「不许降 alpha」。
      final int branchEnd = body.indexOf('  }', branchAt);
      expect(branchEnd, greaterThan(branchAt));
      expect(body.substring(branchAt, branchEnd),
          contains('pass_through_toolbar_.Hide()'),
          reason: '这个窗口盖在游戏上，留一条低 alpha 的催化带 = 一直偷着游戏那块'
              '区域，正是用户抱怨的「穿透不彻底」。');
    });

    test('② 穿透态一律不自动隐藏（工具条是那时唯一的逃生口）', () {
      final String body =
          cppBody(window, 'bool FloatingLyricWindow::ToolbarAutoHideActive');
      expect(body, contains('toolbar_auto_hide_ && !pass_through_'),
          reason: '穿透时正文窗不吃点击，工具条是屏幕上唯一还能点的东西 —— '
              'BUG-951/PR#460 把「永远可点、没有状态可竞争」写成了不变式，'
              '让一张 120ms 的轮询表有权 SW_HIDE 它就是把它变回可竞争状态。');

      // 判据必须真的被两个消费点用上，否则改了这个函数也白改。
      final String apply =
          cppBody(window, 'bool FloatingLyricWindow::ApplyToolbarVisibility');
      expect(apply, contains('ToolbarAutoHideActive()'));
      final String update =
          cppBody(window, 'void FloatingLyricWindow::UpdateToolbarReveal');
      expect(update, contains('ToolbarAutoHideActive()'));
    });

    test('② Show 失败必须回滚 toolbar_revealed_，否则工具条再也回不来', () {
      final String body =
          cppBody(window, 'void FloatingLyricWindow::UpdateToolbarReveal');
      expect(body, contains('if (!ApplyToolbarVisibility()) {'),
          reason: '返回值不能丢：false = 期望显示却没能上屏');
      final int failAt = body.indexOf('if (!ApplyToolbarVisibility()) {');
      expect(body.substring(failAt), contains('toolbar_revealed_ = !want;'),
          reason: '不回滚的话 toolbar_revealed_ 已是 true 而窗口不在屏幕上，'
              '下一拍 want == toolbar_revealed_ 直接早退 —— 逃生口永久消失');
    });

    test('② 揭示区包含工具条矩形，不只是正文窗', () {
      final String body = cppBody(
          window, 'bool FloatingLyricWindow::CursorInToolbarRevealZone');
      expect(body, contains('ComputePassThroughToolbarLayout()'),
          reason: '工具条画在正文窗上沿之上；只圈正文窗的话，鼠标一往工具条方向移'
              '就被判成「离开」，工具条会在指针到达之前先消失。');
      expect(body, contains('InflateRect'));
    });

    test('② 揭示轮询有独立定时器，且随隐藏停表', () {
      expect(window, contains('kToolbarRevealTimerId'));
      final int hideAt = window.indexOf('void FloatingLyricWindow::Hide()');
      expect(hideAt, isNonNegative);
      expect(window.substring(hideAt, hideAt + 1400),
          contains('StopToolbarRevealPolling()'),
          reason: '隐藏后表留着就是后台空转（与悬停轮询同一条纪律）。');
    });

    test('② 切进穿透时先把工具条亮出来（它是唯一的回退入口）', () {
      final String body =
          cppBody(window, 'void FloatingLyricWindow::ApplyPassThroughExStyle');
      final int revealAt = body.indexOf('toolbar_revealed_ = true;');
      final int refuseAt = body.indexOf('ApplyToolbarVisibility()');
      expect(revealAt, isNonNegative, reason: '自动隐藏 + 穿透 = 用户可能找不到关掉穿透的按钮。');
      expect(refuseAt, greaterThan(revealAt));
      expect(body, contains('on_pass_through_(false)'),
          reason: '工具条上不了屏就必须拒绝开启穿透，而不是把用户困住。');
    });

    test('③ 左键查词受触发方式门控', () {
      expect(
        window,
        contains('click_lookup_enabled_ && lookup_trigger_ == 0 &&'),
        reason: '触发方式不是左键时，左键按下只用来拖窗，不再顺手查词。',
      );
    });

    test('③ 中键 / 侧键各自映射到 1 / 2，且复用同一条查词出口', () {
      expect(window, contains('case WM_MBUTTONUP:'));
      expect(window, contains('case WM_XBUTTONUP:'));
      final int at = window.indexOf('case WM_MBUTTONUP:');
      final String body =
          window.substring(at, window.indexOf('case WM_NCHITTEST:', at));
      expect(body, contains('lookup_trigger_ == 1'));
      expect(body, contains('lookup_trigger_ == 2'));
      expect(body, contains('DispatchLookupAt('),
          reason: '走与左键完全相同的出口，「查到什么、制卡拿到哪句」不因触发键而变。');
      expect(body, contains('click_lookup_enabled_'), reason: '总开关关掉时任何键都不该查。');
    });

    test('④ 穿透态的行盒 catch fill 受开关门控', () {
      expect(
        window,
        contains(
            'hook_text_mode_ && pass_through_ && passthrough_blocks_mouse_'),
        reason: '关掉后行盒内也是真 alpha 0，整窗对游戏彻底透明。',
      );
    });

    test('有声书悬浮歌词条不受影响（判据仍以 hook_text_mode_ 分流）', () {
      // 这两条路径共用同一个窗口类；统一工具栏时若把 text_only_ 也一起卷进去，
      // 有声书那条歌词条会连按钮一起消失。
      expect(window, contains('draw_body_toolbar = !hook_text_mode_'));
      expect(window.contains('draw_body_toolbar = !text_only_'), isFalse);
    });
  });

  group('runner C++：通道接线', () {
    late String flutterWindow;

    setUpAll(() {
      flutterWindow =
          maskComments(runnerFile('flutter_window.cpp').readAsStringSync());
    });

    test('三个 live setter 都接上了', () {
      expect(flutterWindow, contains('"setLookupTrigger"'));
      expect(flutterWindow, contains('"setToolbarAutoHide"'));
      expect(flutterWindow, contains('"setPassThroughBlocksMouse"'));
    });

    test('show 载荷读得到四项', () {
      expect(flutterWindow, contains('IntFromValue(args, "lookupTrigger", 0)'));
      expect(flutterWindow,
          contains('BoolFromValue(args, "toolbarAutoHide", true)'));
      expect(flutterWindow,
          contains('BoolFromValue(args, "passThroughBlocksMouse", true)'));
      expect(flutterWindow,
          contains('BoolFromValue(args, "clickLookupEnabled", true)'));
    });
  });
}
