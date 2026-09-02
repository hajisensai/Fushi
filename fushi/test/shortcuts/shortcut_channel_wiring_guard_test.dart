import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import '../helpers/scan_scale.dart';

/// 「某个 scope 开放了某个输入通道，就必须真的存在该通道的解析入口」。
///
/// 与 `shortcut_action_wiring_guard_test` 的区别，也正是它抓不到的那类：那条守卫
/// 只扫「`ShortcutAction.<名>` 这个符号在某个执行体文件里出现过没有」。漫画页把
/// `ShortcutAction.mangaPageForward` 用在**键盘**路径上，符号出现了，于是那条守卫
/// 全绿——而同一个 action 的**手柄**默认绑定（RB / LB / dpad / B）压根没有消费者：
/// 漫画页既没有 `resolveGamepad`，也没有 `GamepadButtonIntent` 的 Action，Android
/// 的 `gameButton*` 键事件同样匹配不到纯键盘绑定。结果是用户在设置里能配手柄、按下
/// 去毫无反应——**比压根没有这个选项更糟**，用户会以为是自己手柄坏了。
///
/// 判据因此不是「符号出现过」，而是「**这个通道有没有解析入口**」：
/// 消费一个通道只有两种真实写法，缺一不可地都算证据——
///   ① 按 scope 解析：`registry.resolveKeyboard/resolveGamepad/resolveMouse(
///      …, scope: ShortcutScope.X)`；
///   ② 按 action 取绑定表：`registry.bindingsFor(<该 scope 的某个 action>)
///      .keyboardBindings / .gamepadBindings / .mouseBindings / .wheelBindings`
///      （video 的键盘、globalExternal 的 OS 级热键、查词弹窗的滚轮都走这条）。
/// 一个文件只有同时出现「该 scope 的身份」（`ShortcutScope.X` 或它名下某个
/// `ShortcutAction.<名>`）和「该通道的取用」，才算这个 (scope, channel) 的消费者。
void main() {
  /// 通道 → 该通道在源码里的取用写法（命中任一即算取用）。
  const Map<ShortcutChannel, List<String>> channelTokens =
      <ShortcutChannel, List<String>>{
    ShortcutChannel.keyboard: <String>['resolveKeyboard(', '.keyboardBindings'],
    ShortcutChannel.gamepad: <String>['resolveGamepad(', '.gamepadBindings'],
    // 第三种写法是本轮新增的**共享解析阶梯**：页面不再各自写
    // `registry.resolveMouse(...)`，而是把「折按钮号 + 按 scope 阶梯解析」收进
    // `mouse_binding_dispatch.dart` 的两个函数里（判据与设置页的按键录制共用同一个
    // 折叠函数，杜绝「录到侧键、运行时按另一个号解析」）。
    //
    // ⚠️ `'resolveMouse('` 匹配不到它们：`resolveMouseBindingAction(` 里紧跟在
    // `resolveMouse` 后面的是 `B` 而不是 `(`。不把这两个 token 列进来，所有改用共享
    // 函数的表面都会被判成「开了通道却没有消费者」——那正是本守卫最该避免的假红。
    ShortcutChannel.mouse: <String>[
      'resolveMouse(',
      '.mouseBindings',
      'resolveMouseBindingAction(',
      'resolveMouseBindingActionForButton(',
    ],
    // wheel 只有 `.wheelBindings` 一种写法：registry 上没有、也从未有过
    // `resolveWheel` —— 滚轮不按「事件 → 查表 → action」解析，而是查词弹窗
    // （唯一开放本通道的 scope）在 popup_settings_injection.dart 里把绑定表
    // 序列化成 JSON 注入 WebView，由 JS 侧自己比对。列一个指向不存在方法的
    // token 只会让后来人以为该方法存在，故删除。
    ShortcutChannel.wheel: <String>['.wheelBindings'],
  };

  /// 定义/展示层：这些文件按定义列举所有 scope 与通道，不构成任何「消费」证据。
  /// 不排掉它们，每个 scope 的每个通道都会因为设置页而假绿。
  const List<String> definitionOnly = <String>[
    'lib/src/shortcuts/shortcut_action.dart',
    'lib/src/shortcuts/shortcut_defaults.dart',
    'lib/src/shortcuts/shortcut_registry.dart',
    'lib/src/shortcuts/input_binding.dart',
    'lib/src/shortcuts/shortcut_labels.dart',
    'lib/src/pages/implementations/shortcut_settings_page.dart',
    'lib/src/pages/implementations/shortcut_settings',
  ];

  /// 既有欠账：**开放了通道但至今没有消费者**的 (scope, channel)。
  ///
  /// **现在是空的**——本守卫落地时登记的 7 条已全部销账，全部走「摘掉通道」而非
  /// 「接上解析入口」，因为它们无一例外是按构造不可接：
  ///   · `home/global.mouse`：mouse 通道在本 app 原本的唯一运行时输入源是 WebView
  ///     的 DOM `mousedown`，这两个页面都是纯 Flutter 表面，Flutter 侧不存在
  ///     PointerDownEvent → MouseBinding → 派发的管线；
  ///     （`video.mouse` 曾与它们同列，BUG-1995 已按「接上解析入口」那一侧销账：
  ///     `video_fushi_page.dart` 的页面根 Listener 现在真的收 onPointerDown 并
  ///     `resolveMouse(scope: video)` 派发，所以它不再出现在本清单里。）
  ///   · `gamepad.keyboard/mouse`：dpad 四向只由 `GamepadService._dispatchButton` 按
  ///     `GamepadButton` 解析，键盘/鼠标绑定没有也不可能有读取方；
  ///   · `globalExternal.gamepad/mouse`：OS 级热键走 win32 `RegisterHotKey`，
  ///     `HotKey.key` 类型就是 `KeyboardKey`，手柄/鼠标压根无法表达。
  /// 详见 `ShortcutScope.channels` 各 case 的注释。
  ///
  /// 本清单是**棘轮**：下面断言的是「实际欠账集合 == 本清单」，因此
  ///   · 新增任何死通道 → 红（这正是漫画那处会被拦下的原因）；
  ///   · 接上某个通道后忘了从清单里划掉 → 也红，逼你把账销掉。
  /// 修的方向是二选一：要么接上解析入口，要么把该通道从 `scope.channels` 摘掉。
  /// 往这里加条目 = 明知故犯地放一个死通道进设置页，必须在 commit 里说明理由。
  const Set<String> knownUnconsumedChannels = <String>{};

  Map<ShortcutScope, List<ShortcutAction>> actionsByScope() {
    final Map<ShortcutScope, List<ShortcutAction>> byScope =
        <ShortcutScope, List<ShortcutAction>>{};
    for (final ShortcutAction action in ShortcutAction.values) {
      byScope.putIfAbsent(action.scope, () => <ShortcutAction>[]).add(action);
    }
    return byScope;
  }

  List<File> consumerFiles() {
    return Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((File f) => f.path.endsWith('.dart'))
        .where((File f) {
      final String p = f.path.replaceAll('\\', '/');
      return !definitionOnly.any((String d) => p.startsWith(d));
    }).toList();
  }

  test('扫描规模哨兵：消费方文件确实被枚举到了', () {
    expectScanScale(consumerFiles().length,
        what: 'lib/ 下的 .dart（已排除纯定义目录）', atLeast: 750, measured: 931);
  });

  /// 实际存在消费者的 (scope, channel)。
  Set<String> consumedPairs() {
    final Map<ShortcutScope, List<ShortcutAction>> byScope = actionsByScope();
    final Set<String> consumed = <String>{};
    for (final File file in consumerFiles()) {
      final String source = file.readAsStringSync();
      for (final MapEntry<ShortcutScope, List<ShortcutAction>> entry
          in byScope.entries) {
        final bool identifiesScope =
            source.contains('ShortcutScope.${entry.key.name}') ||
                entry.value.any((ShortcutAction a) =>
                    source.contains('ShortcutAction.${a.name}'));
        if (!identifiesScope) continue;
        for (final MapEntry<ShortcutChannel, List<String>> ch
            in channelTokens.entries) {
          if (ch.value.any((String token) => source.contains(token))) {
            consumed.add('${entry.key.name}.${ch.key.name}');
          }
        }
      }
    }
    return consumed;
  }

  test('默认表里配了某通道的绑定 → 该通道必须开放且有解析入口（零豁免）', () {
    // 这是硬断言，没有豁免清单：**开箱就带着默认绑定**的通道，用户不做任何配置就
    // 会去按，按不动就是纯粹的谎报。漫画页的手柄绑定正是死在这一条上。
    final Set<String> consumed = consumedPairs();
    final List<String> violations = <String>[];
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      final Map<ShortcutAction, ShortcutBindingSet> table =
          ShortcutDefaults.forPlatform(platform);
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> entry
          in table.entries) {
        final ShortcutScope scope = entry.key.scope;
        final Map<ShortcutChannel, bool> declared = <ShortcutChannel, bool>{
          ShortcutChannel.keyboard: entry.value.keyboardBindings.isNotEmpty,
          ShortcutChannel.gamepad: entry.value.gamepadBindings.isNotEmpty,
          ShortcutChannel.mouse: entry.value.mouseBindings.isNotEmpty,
          ShortcutChannel.wheel: entry.value.wheelBindings.isNotEmpty,
        };
        for (final MapEntry<ShortcutChannel, bool> ch in declared.entries) {
          if (!ch.value) continue;
          final String pair = '${scope.name}.${ch.key.name}';
          if (!scope.channels.contains(ch.key)) {
            violations.add('$platform ${entry.key.key}：默认表配了 '
                '${ch.key.name} 绑定，但 ${scope.name}.channels 没开放该通道');
          } else if (!consumed.contains(pair)) {
            violations.add('$platform ${entry.key.key}：默认表配了 '
                '${ch.key.name} 绑定，但全仓找不到 $pair 的解析入口'
                '（${channelTokens[ch.key]!.join(" / ")} 一个都没出现）');
          }
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason: '开箱即带默认绑定却无人解析 = 用户配了/直接按都没反应，'
          '比没有这个选项更糟。要么接上解析入口，要么把默认绑定和通道一起撤掉。'
          '命中：\n${violations.join('\n')}',
    );
  });

  test('开放但无人消费的通道集合 == 已登记的既有欠账（棘轮，只许缩不许涨）', () {
    final Set<String> consumed = consumedPairs();
    final Set<String> unconsumed = <String>{};
    for (final ShortcutScope scope in ShortcutScope.values) {
      for (final ShortcutChannel channel in scope.channels) {
        final String pair = '${scope.name}.${channel.name}';
        if (!consumed.contains(pair)) unconsumed.add(pair);
      }
    }

    final Set<String> newlyDead =
        unconsumed.difference(knownUnconsumedChannels);
    expect(
      newlyDead,
      isEmpty,
      reason: '新增了「设置页开放、却没有任何解析入口」的通道：$newlyDead。'
          '用户能在设置里配，按下去不会有任何反应。要么接上解析入口，'
          '要么别在 channels 里开放它。',
    );

    final Set<String> alreadyFixed =
        knownUnconsumedChannels.difference(unconsumed);
    expect(
      alreadyFixed,
      isEmpty,
      reason: '$alreadyFixed 已经有解析入口（或通道已摘掉），'
          '请从 knownUnconsumedChannels 里删掉，别让欠账清单虚高。',
    );
  });

  test('漫画 scope 开放键盘+手柄+鼠标，翻页动作双通道默认齐全', () {
    // 历史教训（原「只开放键盘」回归钉的反转）：这批 action 曾带着 RB/LB/dpad/B
    // 默认绑定发出去而页面没有任何手柄解析入口——「设置里能配、按了没反应」。
    // 现在漫画页有真实入口（`_handleGamepadButton` → resolveGamepad manga →
    // universal，见 manga_fushi_page.dart），通道随之打开；本测试钉住新不变式：
    //   · 通道恰为 keyboard+gamepad+mouse；
    //   · 翻页动作必须键盘+手柄默认双全（RB/dpad右=前进、LB/dpad左=后退）；
    //   · **不得**有任何 manga 动作默认绑手柄 B——退出/关弹窗归 universal
    //     globalBack 的 B，两级阶梯不许被 manga scope 遮蔽（universal_back_test）。
    //
    // mouse 于本轮接上：本页正文是原生 WebView，指针归谁按平台不同，故**两条腿**
    // 互斥安装——指针归宿主时走页面根 Listener 的 `_handleMangaPointerDown`，归
    // WebView 时走页内 JS 鼠标桥（`onMangaMouseButton`）回传
    // `_handleNativeNavigationKey`。两者都汇进与键盘/手柄同一个
    // `_executeReaderInputAction`，故不是第二套语义。
    expect(ShortcutScope.manga.channels, <ShortcutChannel>{
      ShortcutChannel.keyboard,
      ShortcutChannel.gamepad,
      ShortcutChannel.mouse,
    });
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.macOS,
      TargetPlatform.android,
    ]) {
      final Map<ShortcutAction, ShortcutBindingSet> table =
          ShortcutDefaults.forPlatform(platform);
      for (final ShortcutAction action in ShortcutAction.values
          .where((ShortcutAction a) => a.scope == ShortcutScope.manga)) {
        expect(
            table[action]!
                .gamepadBindings
                .where((GamepadBinding b) => b.button == GamepadButton.b),
            isEmpty,
            reason: '$platform ${action.key} 不得默认绑手柄 B'
                '（B 归 universal globalBack 的两级阶梯）');
        // mangaDismissDict 是**有意**留空的可选动作：Esc 已归全 app 唯一的
        // 「返回上一级」(globalBack)，它在这里再绑一个键盘默认就会在 manga scope
        // 先命中，把「无弹窗时退出漫画」那一级永久遮蔽（v8 统一的核心不变式，
        // 见 universal_back_test）。翻页动作仍必须有键盘默认。
        if (action == ShortcutAction.mangaDismissDict) continue;
        expect(table[action]!.keyboardBindings, isNotEmpty,
            reason: '$platform ${action.key} 必须有键盘默认绑定');
      }
      for (final ShortcutAction action in const <ShortcutAction>[
        ShortcutAction.mangaPageForward,
        ShortcutAction.mangaPageBackward,
      ]) {
        expect(table[action]!.gamepadBindings, isNotEmpty,
            reason: '$platform ${action.key} 必须有手柄默认绑定'
                '（v8→v9 迁移补发的就是这组，删了老用户就拿不到）');
      }
    }
  });

  /// BUG-2031：**每个表面的鼠标解析阶梯都必须含 `universal`**。
  ///
  /// 「返回上一级」（[ShortcutAction.globalBack]）住在 universal scope，而每个页面都
  /// 有自己的**逐级退出**执行体（视频先关面板 / 退全屏，漫画先关弹窗，阅读器先退光标
  /// ……最后才退页）。页面的键盘阶梯本来就带 universal，所以键盘 Esc 走的是那条逐级。
  ///
  /// 本轮第一版把鼠标阶梯**修窄**成「只有本页 scope」，理由写的是「universal / global
  /// 留给 app 根兜底，页面再解析一遍会双派发」。两处都错：
  ///
  /// 1. 防双派发的机制是 [dispatchClaimedMouseAction] 的认领，跟阶梯宽窄无关；
  /// 2. 修窄的实际后果是**动作降级**——`globalBack` 在页内解析不到，只能落到 app 根
  ///    那份平铺的 `Navigator.maybePop()`，于是同一个「返回上一级」用键盘按是逐级退出、
  ///    用鼠标侧键按是一步退整页。同一动作两条通道两种行为。
  ///
  /// 用**枚举**而不是固定四条清单：新表面加自己的阶梯时会自动落进扫描面。钉住单页的
  /// 守卫对「第五个表面又修窄了一次」结构上挑不到。
  test('GUARD: 所有鼠标解析阶梯都含 universal（否则「返回上一级」降级成平 pop）', () {
    final RegExp decl = RegExp(
      r'MouseLadder\s*=\s*<ShortcutScope>\[(.*?)\]',
      dotAll: true,
    );
    final List<String> found = <String>[];
    for (final FileSystemEntity e
        in Directory('lib').listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final String src = e.readAsStringSync();
      for (final RegExpMatch m in decl.allMatches(src)) {
        final String body = m.group(1)!;
        found.add(e.path);
        expect(
          body.contains('ShortcutScope.universal'),
          isTrue,
          reason: '${e.path} 的鼠标阶梯不含 universal：'
              '该表面的「返回上一级」会绕过页面自己的逐级退出，'
              '直接落到 app 根的平 Navigator.maybePop()，与键盘 Esc 行为分叉',
        );
      }
    }
    expectScanScale(
      found.length,
      what: 'lib/ 下的鼠标解析阶梯声明',
      atLeast: 3,
      measured: 4,
    );
  });

  /// BUG-2031 审查②：WebView 背书的表面上，**Flutter 腿与 JS 腿必须构造性互斥**。
  ///
  /// 第一版只门控了 JS 那一侧（`if (hostOwnsWebViewPointerInput) return;` /
  /// 注入处 `if (!hostOwnsWebViewPointerInput)`），Flutter 侧的页面根 [Listener] 是
  /// **无条件挂载**的，注释却写着「两条路按平台互斥」。
  ///
  /// 那个判据是从查词弹窗提上来的：弹窗在 Android 上是独立 Activity，确实在 Flutter
  /// 命中树之外。但阅读器 / 漫画正文的 WebView 是**树内 platform view**，祖先
  /// [Listener] 照样收得到指针（与「opaque 只排除兄弟、不排除祖先」同源）。于是非
  /// Windows 上同一次按下可能被两条腿各执行一次，而 JS 腿没有 `pointer` id、**无法**
  /// 参与认领协议兜住这件事。
  ///
  /// 所以两侧必须各带一道方向相反的门。这条守卫钉住 Flutter 侧那一道。
  test('GUARD: WebView 表面的 Flutter 鼠标腿必须带 hostOwnsWebViewPointerInput 门', () {
    const Map<String, String> handlers = <String, String>{
      'lib/src/pages/implementations/reader_fushi/caret.part.dart':
          '_handleReaderPointerDown',
      'lib/src/media/manga/reader/manga_fushi_page.dart':
          '_handleMangaPointerDown',
    };
    handlers.forEach((String path, String handler) {
      final String src = File(path).readAsStringSync();
      final int sig = src.indexOf('void $handler(PointerDownEvent event) {');
      expect(sig, greaterThanOrEqualTo(0), reason: '$path 必须有 $handler');
      final int open = src.indexOf('{', sig);
      int depth = 0;
      int close = open;
      for (int k = open; k < src.length; k++) {
        if (src[k] == '{') depth++;
        if (src[k] == '}') {
          depth--;
          if (depth == 0) {
            close = k;
            break;
          }
        }
      }
      final String body = src.substring(open, close + 1);
      expect(
        body.contains('if (!hostOwnsWebViewPointerInput) return;'),
        isTrue,
        reason: '$path 的 $handler 必须在指针归 WebView 的平台让位给 JS 腿；'
            '缺这道门 = 同一次按下被 Flutter 腿与 JS 腿各执行一次'
            '（JS 腿没有 pointer id，认领协议兜不住）',
      );
    });
  });
}
