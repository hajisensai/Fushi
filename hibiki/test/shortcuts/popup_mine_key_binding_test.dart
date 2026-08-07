import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
// services.dart 自己也导出一个同名 ModifierKey（raw_keyboard），与本仓的
// shortcuts/input_binding.dart 那个撞名，故只取需要的符号。
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/popup_settings_injection.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';

/// 制卡快捷键（用户请求：「点那个加号的动作」要能用键盘触发，app 内 / app 外 / 浏览器都要）。
///
/// 各表面复用同一套 popup.js 制卡入口（加号只有那一颗 `.mine-button`），
/// 按**键盘焦点归属**分三条互斥执行路径：
///   · app 内 → Dart 派发（阅读器沿用 readerCreateCardFromPopup；视频页本次补上）
///   · app 外裸 WebView2 → 只有点入后可聚焦的剪贴板面板能收键；瞬态覆盖窗
///     带 WS_EX_NOACTIVATE，保持无快捷键
///   · 浏览器扩展 → 没有注入通道，吃 popup.js 内置默认
///
/// 本文件锁两件事：绑定表序列化的**值**，以及三条路径「各归各」的**接线**。
void main() {
  HibikiShortcutRegistry registryFor(TargetPlatform platform) =>
      HibikiShortcutRegistry()..loadDefaults(platform);

  Map<String, dynamic> decode(String json) =>
      jsonDecode(json) as Map<String, dynamic>;

  group('popupKeyBindingsJson', () {
    test('默认下发 Ctrl+Enter 制卡；词条导航键盘默认为空（它走 Alt+滚轮）', () {
      final Map<String, dynamic> cfg = decode(popupKeyBindingsJson(
        registryFor(TargetPlatform.windows),
        TargetPlatform.windows,
      ));
      expect(cfg['mine'], <Map<String, Object>>[
        <String, Object>{
          'key': 'enter',
          'mods': <String>['ctrl'],
        },
      ]);
      expect(cfg['next'], isEmpty);
      expect(cfg['prev'], isEmpty);
    });

    test('三个动作全在表里——通道是按 scope 开的，漏一个就造出死绑定', () {
      // ShortcutScope.channels 按 scope 开通道：弹窗 scope 开了键盘，设置页就会给它名下
      // **每个**动作渲染「添加键盘快捷键」入口。若注入表只认 mine，词条导航那两个入口就是
      // 「能配、按了没反应」——正是 shortcut_channel_wiring_guard_test 判定为「比压根没有
      // 这个选项更糟」的情形。
      final Map<String, dynamic> cfg = decode(popupKeyBindingsJson(
        registryFor(TargetPlatform.windows),
        TargetPlatform.windows,
      ));
      expect(cfg.keys.toSet(), <String>{'mine', 'next', 'prev'});
      expect(
        ShortcutAction.actionsForScope(ShortcutScope.dictionaryPopup).length,
        cfg.keys.length,
        reason: '弹窗 scope 新增动作时，注入表必须同步跟上',
      );
    });

    test('macOS 把 Ctrl 换成 Meta（跟随平台默认表）', () {
      final Map<String, dynamic> cfg = decode(popupKeyBindingsJson(
        registryFor(TargetPlatform.macOS),
        TargetPlatform.macOS,
      ));
      expect((cfg['mine'] as List<dynamic>).single, <String, Object>{
        'key': 'enter',
        'mods': <String>['meta'],
      });
    });

    test('用户改键后下发的是改后的键', () {
      final HibikiShortcutRegistry registry =
          registryFor(TargetPlatform.windows);
      registry.updateBinding(
        ShortcutAction.popupMineEntry,
        const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            InputBinding(
              key: LogicalKeyboardKey.keyM,
              modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.shift},
            ),
          ],
        ),
      );
      final Map<String, dynamic> cfg = decode(
        popupKeyBindingsJson(registry, TargetPlatform.windows),
      );
      // mods 排序后下发，JS 侧做集合全等比对。
      expect((cfg['mine'] as List<dynamic>).single, <String, Object>{
        'key': 'm',
        'mods': <String>['ctrl', 'shift'],
      });
    });

    test('用户清空绑定 → 下发空表（而不是回退默认，否则「清空」等于没清）', () {
      final HibikiShortcutRegistry registry =
          registryFor(TargetPlatform.windows);
      registry.updateBinding(
        ShortcutAction.popupMineEntry,
        const ShortcutBindingSet(),
      );
      final Map<String, dynamic> cfg = decode(
        popupKeyBindingsJson(registry, TargetPlatform.windows),
      );
      expect(cfg['mine'], isEmpty);
    });

    test('注册表未装载 → 回落平台默认（弹窗进程的精简初始化早于 loadShortcutRegistry）', () {
      // 裸 registry（isLoaded=false）若照读空绑定，Ctrl+Enter 会在弹窗进程里静默失效。
      final Map<String, dynamic> cfg = decode(popupKeyBindingsJson(
        HibikiShortcutRegistry(),
        TargetPlatform.windows,
      ));
      expect((cfg['mine'] as List<dynamic>).single, <String, Object>{
        'key': 'enter',
        'mods': <String>['ctrl'],
      });
    });
  });

  group('默认表', () {
    test('桌面默认 Ctrl+Enter，与阅读器既有的「从弹窗制卡」同键', () {
      final Map<ShortcutAction, ShortcutBindingSet> desktop =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      const InputBinding ctrlEnter = InputBinding(
        key: LogicalKeyboardKey.enter,
        modifiers: <ModifierKey>{ModifierKey.ctrl},
      );
      expect(desktop[ShortcutAction.popupMineEntry]!.keyboardBindings,
          contains(ctrlEnter));
      // 同键但不冲突：两者在不同 co-active 组，永不同时解析。键位一致是有意的——
      // 用户不该为「在阅读器里制卡」和「在 app 外查词窗里制卡」记两个键。
      expect(
          desktop[ShortcutAction.readerCreateCardFromPopup]!.keyboardBindings,
          contains(ctrlEnter));
      expect(ShortcutAction.popupMineEntry.scope.coactiveScopes,
          isNot(contains(ShortcutScope.reader)));
    });

    test('移动端不给制卡键（两个移动端弹窗宿主都没有 Dart 侧接线，给了也按不动）', () {
      final Map<ShortcutAction, ShortcutBindingSet> mobile =
          ShortcutDefaults.forPlatform(TargetPlatform.android);
      expect(mobile[ShortcutAction.popupMineEntry]!.keyboardBindings, isEmpty);
      // 词条导航的滚轮默认在移动端保留（平板/DeX 接鼠标可用），不受本次改动影响。
      expect(mobile[ShortcutAction.popupNextEntry]!.wheelBindings, isNotEmpty);
    });
  });

  group('接线守卫（源码扫描）', () {
    test('README 区分可聚焦面板与 NOACTIVATE 瞬态窗，且两份镜像一致', () {
      final String tools =
          File('../tools/browser-extension/README.md').readAsStringSync();
      final String bundled =
          File('assets/browser_extension/README.md').readAsStringSync();
      expect(bundled, tools, reason: '扩展 README 的 tools 源与 app 内镜像必须同步');
      expect(tools, contains('只有在用户点入并获得键盘焦点后'));
      expect(tools, contains('WS_EX_NOACTIVATE'));
      expect(tools, contains('没有制卡快捷键'));
      expect(tools, contains('不注册全局热键'));
      expect(tools, isNot(contains('三端同源')), reason: '共享渲染代码不等于三个表面都能收到键盘事件');
      expect(tools, isNot(contains('app 内 / app 外全局查词窗共用同一个可改键动作')),
          reason: '瞬态 no-activate 查词窗没有快捷键，不能宣称 app 外全局共用');
    });

    test('popup.js：读注入表、null 关掉自己，且只复用既有的加号点击入口', () {
      final String js = File('assets/popup/popup.js').readAsStringSync();
      expect(js, contains('window.__hoshiPopupKeyBindings'));
      expect(js, contains("document.addEventListener('keydown'"));
      // null = 本宿主由 Dart 派发 → JS 必须整个不参与，否则 WebView 键盘桥一旦把同一次
      // 按键既给 JS 又冒泡回 Flutter，就会制出两张卡。
      expect(js, contains('if (raw === null) return null;'));
      // IME 组词期间的 Enter 属于输入法（确认候选词）。在一个日语学习工具里抢掉它是回归。
      expect(js, contains('e.isComposing'));
      // 必须复用 hoshiPopupMineFirstEntry 去点那颗按钮：三态/单飞门/查重全在按钮 onclick
      // 里，另起一条 mine 桥既绕过它们，也会撞上「mineEntry 桥有且只有一处」的既有守卫。
      expect(js, contains('hoshiPopupMineFirstEntry()'));
      expect(
        "callHandler('mineEntry'".allMatches(js).length,
        1,
        reason: '键盘制卡不得新增第二条 mineEntry 桥调用',
      );
    });

    test('注入端：只有 app 外表面下发真绑定，app 内显式收 null', () {
      // 扫剥注释后的源码：讲「为什么 app 内要收 null」的注释里就写着 globalLookup /
      // __hoshiPopupKeyBindings，连注释一起扫等于让文档给自己背书。
      //
      // 剥离交给共享原语（等长空白，不再改变长度/行数）。这里用
      // `maskCommentsAndScriptLines` 而不是 `maskComments`：本文件把大段 JS 放在
      // 三引号串里（`maskComments` 按设计保留串内容，串里的 JS 注释会原样留下），
      // 前者额外把整行 `//` 也掩掉，正好是旧行式剥离与 Dart 词法掩码的并集——
      // 既补上了块注释 / 行尾注释两个洞，又不放松串内 JS 注释。
      final String dart = maskCommentsAndScriptLines(
        File('lib/src/pages/implementations/popup_settings_injection.dart')
            .readAsStringSync(),
      );
      final String norm = dart.replaceAll(RegExp(r'\s+'), ' ');
      // 判据必须钉住**分流结构本身**，不能只查这几个符号各自出现过：`globalLookup` 在本
      // 文件里到处都是（类字段、主题类名、图标字体），把三元拆掉改成无条件下发照样能让
      // 「符号存在」型断言全绿——而那正是最危险的回归：app 内宿主一旦也拿到真绑定，同一
      // 次按键会被 JS 和 Flutter 各处理一遍，直接制出两张卡。变异实测证实过这条假绿。
      expect(
          norm,
          matches(RegExp(
              r"options\.globalLookup \? popupKeyBindingsJson\([^;]*?: 'null';")),
          reason: 'app 外才下发真绑定、app 内必须显式收 null——'
              '两边都开就会双触发制出两张卡');
      expect(norm,
          contains(r'window.__hoshiPopupKeyBindings = $popupKeyBindings;'));
    });

    test('视频页：制卡键合并在「浮层可见先关浮层」守卫之后', () {
      // 这是本次接线最容易做错、且做错了完全没功能的一处：
      // guardVideoShortcutsWithPopupDismiss 把整张视频快捷键表包成「浮层可见时先关浮层
      // 并吞掉按键」，其前提是「视频 scope 没有任何作用于浮层本身的快捷键」。而制卡恰恰
      // 只在浮层可见时才有意义——若把它放进被守卫的表里，按下去只会关掉浮层。
      final String dart =
          File('lib/src/pages/implementations/video_hibiki_page.dart')
              .readAsStringSync();
      final int guardAt = dart.indexOf('guardVideoShortcutsWithPopupDismiss(');
      final int mineAt = dart.indexOf('ShortcutAction.popupMineEntry');
      expect(guardAt, greaterThanOrEqualTo(0));
      expect(mineAt, greaterThan(guardAt),
          reason: '制卡绑定必须在守卫产物之后合并，才不会被改判成「关浮层」');
      expect(dart, contains('.keyboardBindings'));
      expect(dart, contains('mineFirstVisibleEntry()'));
    });
  });
}
