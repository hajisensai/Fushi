import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 用户请求：一个键把 Hibiki 主窗置顶并直接显示查词页
/// （[ShortcutAction.globalExternalOpenLookupPage]）。
///
/// 它与既有的 [ShortcutAction.globalExternalLookup] 是**相反**的产品取舍：那条取
/// 前台程序的选中文本、在不抢焦点的覆盖窗出词卡、主窗一动不动；这条不取任何文本，
/// 只把主窗唤到前台并落在查词页。两者共用同一套注册表与同一条 OS 热键注册路径，
/// 故本文件钉的是「两条同时存在、互不撞键、都真的接上了执行体」。
void main() {
  group('动作定义', () {
    test('落在 globalExternal scope，持久化 key 稳定', () {
      expect(
        ShortcutAction.globalExternalOpenLookupPage.scope,
        ShortcutScope.globalExternal,
      );
      expect(
        ShortcutAction.globalExternalOpenLookupPage.key,
        'global_external_open_lookup_page',
      );
    });

    // 本 scope 的鼠标/手柄通道各自只有**一个**消费者，且都只认
    // globalExternalLookup（native RawInput 侧键 / 进程级单槽
    // GlobalExternalLookupRoute）。继承 scope 的三通道会让设置页给出两条死通道的
    // 录入入口——「能录、能存、能回显，按下去什么都不发生」。
    test('键盘-only：鼠标/手柄通道必须收窄掉（否则是两条死通道）', () {
      expect(
        ShortcutAction.globalExternalOpenLookupPage.channels,
        const <ShortcutChannel>{ShortcutChannel.keyboard},
      );
      // 对照：取选中文本那条确实接得住鼠标侧键，三通道保持开放。
      expect(
        ShortcutAction.globalExternalLookup.channels,
        ShortcutScope.globalExternal.channels,
      );
      expect(
        ShortcutAction.globalExternalLookup.allowedMouseButtons,
        const <int>{3, 4},
      );
    });
  });

  group('默认绑定', () {
    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.windows,
      TargetPlatform.linux,
    ]) {
      test('$platform 默认 Ctrl+Alt+F，且只有键盘一条通道', () {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
          platform,
        )[ShortcutAction.globalExternalOpenLookupPage]!;
        expect(set.keyboardBindings, hasLength(1));
        expect(set.keyboardBindings.first.key, LogicalKeyboardKey.keyF);
        expect(
          set.keyboardBindings.first.modifiers,
          <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
        );
        expect(set.gamepadBindings, isEmpty);
        expect(set.mouseBindings, isEmpty);
        expect(set.wheelBindings, isEmpty);
      });
    }

    test('macOS 把 Ctrl 换成 Meta（与同 scope 的选中文本查词同款）', () {
      final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
        TargetPlatform.macOS,
      )[ShortcutAction.globalExternalOpenLookupPage]!;
      expect(set.keyboardBindings, hasLength(1));
      expect(set.keyboardBindings.first.key, LogicalKeyboardKey.keyF);
      expect(
        set.keyboardBindings.first.modifiers,
        <ModifierKey>{ModifierKey.meta, ModifierKey.alt},
      );
    });

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.android,
      TargetPlatform.iOS,
    ]) {
      test('$platform 无任何绑定（系统不允许第三方注册全局热键）', () {
        final ShortcutBindingSet set = ShortcutDefaults.forPlatform(
          platform,
        )[ShortcutAction.globalExternalOpenLookupPage]!;
        expect(set.keyboardBindings, isEmpty);
        expect(set.gamepadBindings, isEmpty);
        expect(set.mouseBindings, isEmpty);
        expect(set.wheelBindings, isEmpty);
      });
    }

    test('与同 co-active 组里的选中文本查词不撞键', () {
      for (final TargetPlatform platform in <TargetPlatform>[
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        final FushiShortcutRegistry registry = FushiShortcutRegistry();
        registry.loadDefaults(platform);
        final InputBinding binding = registry
            .bindingsFor(ShortcutAction.globalExternalOpenLookupPage)
            .keyboardBindings
            .first;
        expect(
          registry.hasKeyboardConflict(
            ShortcutScope.globalExternal,
            binding,
            exclude: ShortcutAction.globalExternalOpenLookupPage,
          ),
          isNull,
          reason: '$platform 上默认键与 globalExternal 组内其它动作撞键了',
        );
      }
    });
  });

  group('跨 scope 抢占检测', () {
    // globalExternal 的键盘绑定注册成 win32 RegisterHotKey，是全系统级吞键：命中时
    // 连 Hibiki 自己的页面都收不到那次按键。所以给页面动作绑一个**已被 OS 热键占住**
    // 的组合键必须报冲突，否则用户绑完只会发现「阅读器的这个键从此没反应了」，而设置
    // 页一声不吭。手柄侧早有同构处理（_gamepadPreemptingScopes），键盘侧此前是缺口。
    test('页面动作绑到 OS 热键已占的组合键 → 必须报冲突', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
      final InputBinding osHotKey = registry
          .bindingsFor(ShortcutAction.globalExternalOpenLookupPage)
          .keyboardBindings
          .first;

      expect(
        registry.hasKeyboardConflict(
          ShortcutScope.reader,
          osHotKey,
          exclude: ShortcutAction.readerPageForward,
        ),
        ShortcutAction.globalExternalOpenLookupPage,
        reason: 'reader 的键撞上全系统级 OS 热键时必须能被检测到',
      );
    });

    test('反向不报：OS 热键自己改键时只扫自己（抢占是单向的）', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadDefaults(TargetPlatform.windows);
      final InputBinding readerKey = registry
          .bindingsFor(ShortcutAction.readerPageForward)
          .keyboardBindings
          .first;

      expect(
        registry.hasKeyboardConflict(
          ShortcutScope.globalExternal,
          readerKey,
          exclude: ShortcutAction.globalExternalOpenLookupPage,
        ),
        isNull,
        reason: 'OS 热键抢的是页面的键，不是反过来；报成双向会让 globalExternal '
            '几乎绑什么都提示冲突',
      );
    });
  });

  group('升级路径', () {
    test('schema 版本已 bump（新 action 必须随版本号一起发出去）', () {
      expect(kShortcutSchemaVersion, greaterThanOrEqualTo(12));
    });

    test('老快照（无此 key）升级后拿到默认热键，且不误伤已改过的旧绑定', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      // 老用户把「app 外查词」改成了 Ctrl+Alt+J，快照写于 v11。绑定用
      // ShortcutBindingSet.toJson 生成而不是手抄序列化串——序列化格式变了这里应该
      // 跟着变，手抄的串会在格式变更后静默变成「解析不出任何绑定」的空快照。
      final String json = jsonEncode(<String, dynamic>{
        '__schema_version__': 11,
        'global_external_lookup': const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[
            InputBinding(
              key: LogicalKeyboardKey.keyJ,
              modifiers: <ModifierKey>{ModifierKey.ctrl, ModifierKey.alt},
            ),
          ],
        ).toJson(),
      });
      registry.loadFromJsonString(json, TargetPlatform.windows);

      // 新 action 缺席快照 ⇒ 保留默认。
      final ShortcutBindingSet added =
          registry.bindingsFor(ShortcutAction.globalExternalOpenLookupPage);
      expect(added.keyboardBindings, hasLength(1));
      expect(added.keyboardBindings.first.key, LogicalKeyboardKey.keyF);

      // 用户改过的旧绑定原样保留（never break userspace）。
      final ShortcutBindingSet old =
          registry.bindingsFor(ShortcutAction.globalExternalLookup);
      expect(old.keyboardBindings, hasLength(1));
      expect(old.keyboardBindings.first.key, LogicalKeyboardKey.keyJ);
    });

    test('用户清空后不被升级重新填回', () {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      final String json = jsonEncode(<String, dynamic>{
        '__schema_version__': 12,
        'global_external_open_lookup_page': const ShortcutBindingSet().toJson(),
      });
      registry.loadFromJsonString(json, TargetPlatform.windows);
      expect(
        registry
            .bindingsFor(ShortcutAction.globalExternalOpenLookupPage)
            .keyboardBindings,
        isEmpty,
      );
    });
  });

  group('接线', () {
    test('设置页有可显示的标签（漏了会在 label getter 处编译期漏 case）', () {
      final String labelsSrc = File(
        'lib/src/shortcuts/shortcut_labels.dart',
      ).readAsStringSync();
      expect(
        labelsSrc.contains('case ShortcutAction.globalExternalOpenLookupPage:'),
        isTrue,
      );
    });

    // 执行体的两步都必须复用既有出口：唤前台走 DesktopLookupService（已含「已在
    // 前台就 no-op」与任务栏闪烁清理，绕过它直接调 windowManager 会让任务栏图标
    // 闪烁回归，TODO-341/615），落地面走 requestHomeDictionaryTab（HomePage 侧的
    // _revealDictionary 负责 tab 在/不在两种承载）。
    test('执行体复用 bringMainWindowToFront + requestHomeDictionaryTab', () {
      final String src = File(
        'lib/src/lookup/global_lookup_controller.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final int body = src.indexOf(
        'Future<void> openLookupPageInMainWindow() async {',
      );
      expect(body, greaterThan(0),
          reason: '执行体必须收口在 openLookupPageInMainWindow 这一个地方');
      final int end = src.indexOf('\n  }', body);
      expect(end, greaterThan(body));
      final String fn = src.substring(body, end);

      expect(
        fn.contains('DesktopLookupService.instance.bringMainWindowToFront()'),
        isTrue,
        reason: '唤前台必须走 DesktopLookupService 的统一出口',
      );
      expect(
        fn.contains('requestHomeDictionaryTab()'),
        isTrue,
        reason: '落地面必须走 AppModel.requestHomeDictionaryTab',
      );
      expect(
        fn.contains('windowManager.'),
        isFalse,
        reason: '不得绕过统一出口直接调 windowManager（任务栏闪烁会回归）',
      );
    });
  });
}
