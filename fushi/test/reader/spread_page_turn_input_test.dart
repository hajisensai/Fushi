import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show
        buildSpreadPageHtml,
        kSpreadBridgedActions,
        resolveSpreadKeyBridgeAction,
        spreadKeyBridgeScopes,
        spreadKeyBridgeTokens;
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-1426 守卫：进了双页 spread 页面，滚轮和左右翻页一起失效。
///
/// 根因是 BUG-1280 ③ 的守卫留下的账：spread 是第四种独立文档，
/// `_onChapterLoadComplete` 判到 `_spreadDocumentLoaded` 就早退、绝不注入正文引擎，
/// 而**滚轮 / 横扫 / 键桥全长在那份引擎里**。Windows 侧从来就没被注入过（`loadData`
/// 丢 baseUrl → onLoadStop 判 stale），所以那边的 spread 页自始至终没有滚轮翻页；
/// Android 侧是 BUG-1280 修复时连同误注入一起失去的（该 BUG 备注已明确记账并留
/// TODO：「给 spread 独立文档补它自己的 onSwipe + 键桥」）。本次把这笔账还上。
///
/// 修法：三条通道都由 spread 文档**自带**，且都直连**既有** Dart handler
/// （`onWheelPaginate` / `onSwipe` / 新的 `onSpreadKey`），Dart 侧不新增翻页语义——
/// 节流、跨章冷却、虚拟页翻页仍是 `_paginate` → `_handlePageTurnLimit` 那一份。
void main() {
  const String leftUrl = 'fushi.local/OEBPS/img/left.png';
  const String rightUrl = 'fushi.local/OEBPS/img/right.png';

  String htmlWith({String keyBridgeScript = ''}) => buildSpreadPageHtml(
        leftUrl: leftUrl,
        rightUrl: rightUrl,
        swipeDistThreshold: 44,
        swipeFastDistThreshold: 22,
        keyBridgeScript: keyBridgeScript,
      );

  group('spread 文档自带翻页输入 (BUG-1426)', () {
    test('滚轮桥直连既有 onWheelPaginate，且带主轴与输入设备参数', () {
      final String html = htmlWith();
      expect(html, contains("callHandler('onWheelPaginate'"),
          reason: 'spread 页没有 wheel 桥 = 滚轮完全无反应（用户报的第一个症状）');
      expect(html, contains("document.addEventListener('wheel'"),
          reason: 'wheel 必须挂文档级，两张整页图铺满视口时滚轮落在哪都要算数');
      expect(html, contains("horizontal ? 'horizontal' : 'vertical'"),
          reason: 'Dart 侧 onWheelPaginate 的第 2 个实参是主轴，少一个直接早退');
      // BUG-1745：第 3 个实参是输入设备。少了它就落进 Dart 侧的 2 参兼容回落
      // （纵向恒判 mouse → 绕过触摸板闸门 → 上下滑一次翻 3 页）。「两个注入点拼的
      // 是同一份常量」由 pr912_paged_wheel_single_source_test.dart 单独守。
      expect(html, contains("_isTrackpadWheel(e) ? 'trackpad' : 'mouse'"),
          reason: 'spread 也必须回传 trackpad/mouse，否则触摸板聚合闸门在双页模式失效');
    });

    test('横扫桥直连既有 onSwipe，阈值来自入参而非另立默认', () {
      final String html = buildSpreadPageHtml(
        leftUrl: leftUrl,
        rightUrl: rightUrl,
        swipeDistThreshold: 77,
        swipeFastDistThreshold: 33,
      );
      expect(html, contains("callHandler('onSwipe'"));
      expect(html, contains('77'), reason: '阈值必须从调用方（随灵敏度设置缩放的真值）插进来');
      expect(html, contains('33'));
    });

    test('键桥脚本原样嵌入，空串则不装键桥', () {
      const String marker = '/*__SPREAD_KEY_BRIDGE_MARKER__*/';
      expect(htmlWith(keyBridgeScript: marker), contains(marker),
          reason: '调用方生成的键桥必须真的进文档，否则 WebView2 持焦时按键全丢');
      expect(htmlWith(), isNot(contains(marker)));
    });

    // 上面三条只断言字面量在不在。把生产 HTML 里的脚本原样丢进 node 真跑，断言的是
    // **行为**：滚轮方向映射、横扫阈值判定、横扫后合成 click 不再误触发图片查看器。
    test('spread 脚本真跑：滚轮方向 / 横扫阈值 / 合成 click 抑制（行为级）', () {
      final String payload = jsonEncode(<String, String>{'html': htmlWith()});
      final Directory temp =
          Directory.systemTemp.createTempSync('hibiki-spread-input-js-');
      final File payloadFile = File('${temp.path}/payload.json')
        ..writeAsStringSync(payload);
      late final ProcessResult result;
      try {
        result = Process.runSync(
          'node',
          <String>['-e', _spreadInputRunner, payloadFile.path],
          stdoutEncoding: utf8,
          stderrEncoding: utf8,
        );
      } finally {
        temp.deleteSync(recursive: true);
      }
      expect(
        result.exitCode,
        0,
        reason: 'spread input runner failed:\n'
            'stdout=${result.stdout}\nstderr=${result.stderr}',
      );
      expect(result.stdout.toString().trim(), 'OK');
    });
  });

  group('键桥 token 表按注册表当前绑定导出 (BUG-1426)', () {
    test('未装载的注册表给空表（与「用户清空绑定」同等对待）', () {
      expect(spreadKeyBridgeTokens(FushiShortcutRegistry()), isEmpty);
    });

    test('导出翻页/唤栏/退出的当前绑定，且恒排除裸 Space', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);

      final List<String> tokens = spreadKeyBridgeTokens(registry);
      expect(tokens, isNotEmpty, reason: '装载后应导出默认绑定，空表 = 键桥是死的');

      // 裸 Space 归 onSpaceKey 桥（有声书激活时它解析成播放/暂停）。两座桥都在本
      // document 上装 keydown，同一次按下各命中一次就会翻两页——这条是真实的双触发
      // 风险，不是洁癖。
      const String bareSpace = 'Space';
      expect(tokens.contains(bareSpace), isFalse,
          reason: '裸 Space 必须留给 onSpaceKey 桥，否则空格翻两页');

      // 表里的每个 token 都必须能反解析回本表声明的动作之一——否则 Dart 侧
      // onSpreadKey 收到后 resolveKeyboard 得到别的动作（或 null），键桥形同虚设。
      for (final String token in tokens) {
        final InputBinding? binding = InputBinding.deserialize(token);
        expect(binding, isNotNull, reason: '$token 不是合法 InputBinding token');
        final ShortcutAction? action =
            resolveSpreadKeyBridgeAction(registry, binding!);
        expect(kSpreadBridgedActions.contains(action), isTrue,
            reason: '$token 解析成 $action，不在 spread 声明的动作集里');
      }

      // 翻页是本 bug 的主诉，必须真的在表里（默认绑定含方向键）。
      final Set<ShortcutAction> covered = tokens
          .map(InputBinding.deserialize)
          .whereType<InputBinding>()
          .map((InputBinding b) => resolveSpreadKeyBridgeAction(registry, b))
          .whereType<ShortcutAction>()
          .toSet();
      expect(covered, contains(ShortcutAction.readerPageForward));
      expect(covered, contains(ShortcutAction.readerPageBackward));
    });

    test('改键后 token 表跟着变（不是硬编码键名）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows)
        ..updateBinding(
          ShortcutAction.readerPageForward,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.keyN),
            ],
          ),
        );
      expect(spreadKeyBridgeTokens(registry), contains('KeyN'),
          reason: '漫画页旧桥写死 ArrowLeft/ArrowRight 的教训（BUG-1347）不得重演');
    });
  });

  /// BUG-1442：键桥的「导出哪些动作」与「解析哪个 scope」此前是两份真值——动作集
  /// 是数据、scope 是 onSpreadKey 里硬编码的 `ShortcutScope.reader`。往动作集里加
  /// 任何非 reader scope 的动作都会**静默失效**：token 进了 JS 表、按下也回传了
  /// Dart，但 resolveKeyboard 在 reader scope 里找不到它，handler 直接早退。
  ///
  /// 修法：scope 列表从动作集自身导出（[spreadKeyBridgeScopes]），解析按该顺序逐
  /// 个试（[resolveSpreadKeyBridgeAction]）。本组锁定这条能力，并钉住两条不得回归
  /// 的既有性质：页面专属 scope 优先于兜底 scope、裸 Space 恒不进表。
  group('键桥跨 scope 解析 (BUG-1442)', () {
    /// 一个确定不在任何 reader 默认绑定里的键，用来当「兜底 scope 专属键」。
    const InputBinding fallbackOnly =
        InputBinding(key: LogicalKeyboardKey.keyJ);

    /// reader 与兜底 scope **同时**绑上的键，用来验优先级。
    const InputBinding shared = InputBinding(key: LogicalKeyboardKey.keyK);

    /// 绑给一个**不在生产动作集里**的 scope（global）的键，用来验「没进动作集的
    /// scope 一概不试」。
    const InputBinding notBridged = InputBinding(key: LogicalKeyboardKey.keyL);

    FushiShortcutRegistry loadedRegistry() =>
        FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

    /// PR#722 落地后生产动作集里已经混进了 universal scope 的「返回上一级」
    /// （[ShortcutAction.globalBack]），这正是 BUG-1442 修完要让它跑起来的那件事：
    /// 解析侧不需要任何改动就跟着动作集走。
    test('生产动作集导出 reader + universal 两个 scope，reader 在前', () {
      expect(
        spreadKeyBridgeScopes(),
        <ShortcutScope>[ShortcutScope.reader, ShortcutScope.universal],
        reason: 'kSpreadBridgedActions 前三个是 reader 动作、末位是 universal 的'
            'globalBack，导出的 scope 列表就该是 [reader, universal]——顺序反了会让'
            '「返回」把 spread 页的翻页键夺舍',
      );
    });

    test('scope 列表按动作集出现序去重导出，不是硬编码', () {
      expect(
        spreadKeyBridgeScopes(actions: const <ShortcutAction>[
          ShortcutAction.readerPageForward,
          ShortcutAction.globalBack,
          ShortcutAction.readerToggleChrome,
          ShortcutAction.globalToggleFullscreen,
        ]),
        <ShortcutScope>[
          ShortcutScope.reader,
          ShortcutScope.universal,
          ShortcutScope.global,
        ],
        reason: '两个 reader 必须去重成一个，且三个 scope 按首次出现序排'
            '（reader → universal → global）',
      );
      expect(
        spreadKeyBridgeScopes(actions: const <ShortcutAction>[
          ShortcutAction.globalBack,
          ShortcutAction.readerPageForward,
        ]),
        <ShortcutScope>[ShortcutScope.universal, ShortcutScope.reader],
        reason: '顺序必须真的跟着动作集走，不能返回固定列表',
      );
    });

    test('动作集里混入别的 scope 时，那个 scope 的键真能解析到', () {
      final FushiShortcutRegistry registry = loadedRegistry()
        ..updateBinding(
          ShortcutAction.globalBack,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[fallbackOnly],
          ),
        )
        ..updateBinding(
          ShortcutAction.globalToggleFullscreen,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[notBridged],
          ),
        );

      // globalBack 是 universal scope，靠的就是它在动作集里 → 解析侧才试 universal。
      // 这正是 PR#722 撞上的那堵墙，现在已经拆掉。
      expect(resolveSpreadKeyBridgeAction(registry, fallbackOnly),
          ShortcutAction.globalBack,
          reason: '解析侧若还硬编码 reader scope，进了动作集的兜底动作永远解析成 null，'
              '键桥对它形同虚设');

      // 没进动作集的 scope 一概不试——键桥不是「什么都解析」。
      expect(resolveSpreadKeyBridgeAction(registry, notBridged), isNull,
          reason: 'globalToggleFullscreen（global scope）不在生产动作集里，它的键就'
              '不该被 spread 键桥解析到');

      // 把它加进动作集，解析侧无需任何改动就跟着生效。
      expect(
        resolveSpreadKeyBridgeAction(
          registry,
          notBridged,
          actions: const <ShortcutAction>[
            ShortcutAction.readerPageForward,
            ShortcutAction.globalToggleFullscreen,
          ],
        ),
        ShortcutAction.globalToggleFullscreen,
        reason: 'scope 列表从动作集导出 ⇒ 往集合里加一个新 scope 的动作，解析侧零改动'
            '就该跟着生效',
      );
    });

    test('同键被页面 scope 与兜底 scope 都绑时，页面专属胜出', () {
      final FushiShortcutRegistry registry = loadedRegistry()
        ..updateBinding(
          ShortcutAction.readerPageForward,
          const ShortcutBindingSet(keyboardBindings: <InputBinding>[shared]),
        )
        ..updateBinding(
          ShortcutAction.globalBack,
          const ShortcutBindingSet(keyboardBindings: <InputBinding>[shared]),
        );

      expect(
        resolveSpreadKeyBridgeAction(
          registry,
          shared,
          actions: const <ShortcutAction>[
            ShortcutAction.readerPageForward,
            ShortcutAction.globalBack,
          ],
        ),
        ShortcutAction.readerPageForward,
        reason: '兜底 scope 排在动作集后面 = 解析时也排在后面；反过来会让翻页被'
            '「返回」夺舍，spread 页直接退书',
      );
    });

    test('裸 Space 的排除与 scope 无关：兜底 scope 的动作绑裸 Space 也进不了表', () {
      final FushiShortcutRegistry registry = loadedRegistry()
        ..updateBinding(
          ShortcutAction.globalBack,
          const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.space),
              InputBinding(
                key: LogicalKeyboardKey.space,
                modifiers: <ModifierKey>{ModifierKey.ctrl},
              ),
            ],
          ),
        );

      final List<String> tokens = spreadKeyBridgeTokens(
        registry,
        actions: const <ShortcutAction>[
          ShortcutAction.readerPageForward,
          ShortcutAction.globalBack,
        ],
      );

      // App 已把裸空格中和为 DoNothingIntent、焦点确认统一走 Enter/手柄 A；spread
      // 页的裸 Space 又归 onSpaceKey 那座桥。两座桥都装 keydown，裸 Space 一旦进本
      // 表就是同一次按下触发两次。
      expect(tokens, isNot(contains('Space')),
          reason: '裸 Space 必须恒排除，跨 scope 动作也不例外——否则空格在 spread 里'
              '复活成双触发');
      expect(tokens, contains('Ctrl+Space'),
          reason: '排除的判据只是「裸」Space，带修饰键的 Space 仍是正常绑定，不该被'
              '一起误杀');
    });

    test('spread 专属键（翻页/唤栏/退书）解析结果一字不变', () {
      final FushiShortcutRegistry registry = loadedRegistry();
      // 默认绑定下逐个动作的每条键盘绑定都必须解析回它自己（裸 Space 那条走
      // onSpaceKey 桥，不在本表，故按同一规则跳过）。
      for (final ShortcutAction action in kSpreadBridgedActions) {
        for (final InputBinding binding
            in registry.bindingsFor(action).keyboardBindings) {
          if (binding.key == LogicalKeyboardKey.space &&
              binding.modifiers.isEmpty) {
            continue;
          }
          expect(resolveSpreadKeyBridgeAction(registry, binding), action,
              reason: '${binding.serialize()} 本该解析成 $action；spread 专属键的行为'
                  '不允许因为解析改成多 scope 而漂动');
        }
      }
    });
  });

  group('Dart 侧接线 (BUG-1426)', () {
    final String source = readReaderPageSource();

    test('注册了 onSpreadKey 处理器，走注册表解析并 reclaim 焦点', () {
      // `handlerName: 'onSpreadKey'` 在合并语料里出现两次——一次是 _loadSpreadPage
      // 生成桥脚本时的入参，一次才是 handler 注册。裸 indexOf 会切到前者（那段只有
      // 一行，任何断言都红），所以锚点必须连着 addJavaScriptHandler 一起匹配。
      final int idx = source.indexOf(
        RegExp(r"addJavaScriptHandler\(\s*handlerName: 'onSpreadKey'"),
      );
      expect(idx, greaterThan(0), reason: 'JS 发了键桥而 Dart 不接 = 桥是死的');
      final int end = source.indexOf('addJavaScriptHandler', idx + 1);
      expect(end, greaterThan(idx));
      final String body = source.substring(idx, end);

      expect(body, contains('InputBinding.deserialize'),
          reason: 'token 必须反解析，不能按字面量比键名');
      expect(body, contains('resolveSpreadKeyBridgeAction('),
          reason: '必须走与 Flutter 焦点路径同一个解析（该 helper 内部就是 '
              'resolveKeyboard），改键才会对两条路一起生效');
      // BUG-1442：handler 体内**不许**再出现任何 `ShortcutScope.xxx` 字面量——
      // 硬编码单 scope 正是「动作集里加了跨 scope 动作却静默解析不到」的根因。
      // 要试哪些 scope 由 spreadKeyBridgeScopes 从动作集导出。
      expect(body, isNot(contains('ShortcutScope.')),
          reason: 'onSpreadKey 里硬编码 scope = 动作集与解析侧两份真值，必然漂开');
      expect(body, contains('_executeShortcutAction('),
          reason: '解析出动作却不执行 = 按键仍然没反应');
      expect(body, contains('FocusReclaimCause.gesture'),
          reason: '不夺回 Flutter 焦点，后续按键还是只到 DOM（BUG-136 同族）');
    });

    test('_loadSpreadPage 真的把三样都传进 HTML', () {
      final String body =
          methodBody(source, 'Future<void> _loadSpreadPage(SpreadEntry entry)');
      expect(containsCodeLine(body, 'swipeDistThreshold:'), isTrue,
          reason: '不传阈值，横扫判据就退回不到正文那套手感');
      expect(containsCodeLine(body, 'swipePageTurnDistThresholds('), isTrue,
          reason: '阈值必须来自 ReaderSettings 的同一真值（随灵敏度设置缩放）');
      expect(containsCodeLine(body, 'keyBridgeScript:'), isTrue);
      expect(body, contains("handlerName: 'onSpreadKey'"),
          reason: '键桥脚本必须在装载 spread 时生成，改键下次进页即生效');
      expect(body, contains("handlerName: 'onSpaceKey'"),
          reason: '裸 Space 桥与正文逐字同款，spread 页的空格翻页靠它');
    });

    // 滚轮/横扫桥只有在 Dart 侧 handler 仍然存在时才有意义。它们是**既有** handler，
    // 本次没动；这条钉住「以后谁把它们改名/删掉，spread 的滚轮会静默失效」。
    test('spread 复用的既有 handler 仍在', () {
      expect(source, contains("handlerName: 'onWheelPaginate'"));
      expect(source, contains("handlerName: 'onSwipe'"));
    });
  });

  group('滑动灵敏度默认值单一真值 (BUG-1426)', () {
    test('getter 的兜底默认就是 defaultSwipePageTurnSensitivity', () {
      const String kSettingsFile = 'lib/src/reader/reader_settings.dart';
      final String settingsSrc = File(kSettingsFile).readAsStringSync();
      expect(
        settingsSrc,
        contains("'swipe_page_turn_sensitivity',\n"
            '          defaultSwipePageTurnSensitivity,'),
        reason: 'getter 里写回字面量 1.0 = 又有两处默认，改手感只会改到一半',
      );
      expect(ReaderSettings.defaultSwipePageTurnSensitivity, 1.0);
    });
  });
}

/// 把生产 spread HTML 里的 `<script>` 原样丢进 node 跑，用最小假 DOM 复现三条真实
/// 路径：滚轮 tick、单指横扫、横扫之后浏览器合成的那次 click。
const String _spreadInputRunner = r"""
const fs = require('fs');
const data = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
function assert(value, message) {
  if (!value) throw new Error(message);
}
const html = data.html;
const open = html.indexOf('<script>');
const close = html.indexOf('</script>', open);
assert(open >= 0 && close > open, 'spread script block missing');
const script = html.slice(open + '<script>'.length, close);

function node(tagName, src) {
  return {
    tagName: tagName,
    src: src,
    listeners: {},
    complete: true,
    naturalWidth: 100,
    addEventListener(type, fn) {
      (this.listeners[type] = this.listeners[type] || []).push(fn);
    },
    removeEventListener(type, fn) {
      const list = this.listeners[type] || [];
      this.listeners[type] = list.filter(f => f !== fn);
    }
  };
}

const imgs = [node('IMG', 'L'), node('IMG', 'R')];
const docListeners = {};
function bucket(type, capture) {
  const key = type + (capture ? ':capture' : '');
  return (docListeners[key] = docListeners[key] || []);
}
const document = {
  querySelectorAll() { return imgs; },
  addEventListener(type, fn, options) {
    const capture = options === true || (options && options.capture === true);
    bucket(type, capture).push(fn);
  }
};
const calls = [];
const window = {
  flutter_inappwebview: {callHandler: (...args) => calls.push(args)}
};
new Function('window', 'document', script)(window, document);
calls.length = 0;

function fire(type, event, capture) {
  (docListeners[type + (capture ? ':capture' : '')] || [])
    .slice().forEach(fn => fn(event));
}
function wheelEvent(deltaX, deltaY) {
  let prevented = false;
  return {
    deltaX: deltaX,
    deltaY: deltaY,
    preventDefault() { prevented = true; },
    get prevented() { return prevented; }
  };
}

// ── 滚轮：纵向鼠标滚轮 ────────────────────────────────────────────────
assert((docListeners['wheel'] || []).length === 1, 'wheel listener missing');
const down = wheelEvent(0, 120);
fire('wheel', down);
assert(calls.length === 1, 'one wheel tick must emit exactly one bridge call');
assert(calls[0][0] === 'onWheelPaginate' && calls[0][1] === 'forward' &&
  calls[0][2] === 'vertical',
  'scrolling down must page forward on the vertical axis, got ' +
  JSON.stringify(calls));
assert(down.prevented, 'wheel must preventDefault, else the doc scrolls instead');

calls.length = 0;
fire('wheel', wheelEvent(0, -120));
assert(calls[0][1] === 'backward', 'scrolling up must page backward');

// 主轴取绝对值更大的那个（横向触控板惯性走 horizontal，Dart 侧另有手势闸门）。
calls.length = 0;
fire('wheel', wheelEvent(-200, 10));
assert(calls[0][1] === 'backward' && calls[0][2] === 'horizontal',
  'dominant horizontal delta must report the horizontal axis, got ' +
  JSON.stringify(calls));

// 零位移不应产生翻页（触控板惯性收尾会连发 0）。
calls.length = 0;
fire('wheel', wheelEvent(0, 0));
assert(calls.length === 0, 'zero delta must not turn a page');

// ── 横扫：阈值 44px / 快速短滑 22px + 900px/s ────────────────────────
function touchStart(x, y) {
  fire('touchstart', {touches: [{clientX: x, clientY: y}]});
}
function touchEnd(x, y) {
  fire('touchend', {
    changedTouches: [{clientX: x, clientY: y}],
    preventDefault() {}
  });
}

calls.length = 0;
touchStart(300, 200);
touchEnd(200, 205);            // dx=-100 横向占优，过 44px
assert(calls.length === 1 && calls[0][0] === 'onSwipe' && calls[0][1] === 'left',
  'a leftward swipe must report left, got ' + JSON.stringify(calls));

calls.length = 0;
touchStart(200, 200);
touchEnd(300, 205);            // dx=+100
assert(calls[0][1] === 'right', 'a rightward swipe must report right');

// 纵向为主的滑动不是翻页（图片页竖着划拉不该翻页）。
calls.length = 0;
touchStart(200, 200);
touchEnd(210, 400);
assert(calls.length === 0, 'a vertical drag must not turn a page');

// 短于阈值且不够快 = 点击抖动，不翻页。
calls.length = 0;
touchStart(200, 200);
touchEnd(215, 202);
assert(calls.length === 0, 'a sub-threshold nudge must not turn a page');

// ── 横扫之后的合成 click 必须被吞掉 ──────────────────────────────────
calls.length = 0;
touchStart(300, 200);
touchEnd(200, 205);
assert(calls.length === 1 && calls[0][0] === 'onSwipe', 'swipe precondition');
calls.length = 0;
let stopped = false;
const synthetic = {
  target: imgs[0],
  stopPropagation() { stopped = true; },
  preventDefault() {}
};
fire('click', synthetic, true);
assert(stopped,
  'the click synthesised right after a swipe must be stopped in capture, ' +
  'otherwise a page turn also pops the image viewer');
if (!stopped) {
  (imgs[0].listeners['click'] || []).slice().forEach(fn => fn(synthetic));
}
assert(calls.length === 0, 'swallowed click must not reach any bridge, got ' +
  JSON.stringify(calls));

// 而**不是**横扫之后的普通点击照常工作（吞噬是一次性 + 700ms 窗口，不许粘住）。
calls.length = 0;
let stopped2 = false;
const realTap = {
  target: imgs[1],
  stopPropagation() { stopped2 = true; },
  preventDefault() {}
};
fire('click', realTap, true);
assert(!stopped2, 'a later real tap must not be swallowed');
(imgs[1].listeners['click'] || []).slice().forEach(fn => fn(realTap));
assert(calls.length === 1 && calls[0][0] === 'onImageTap',
  'tapping an image after a swipe must still open the viewer, got ' +
  JSON.stringify(calls));

process.stdout.write('OK');
""";
