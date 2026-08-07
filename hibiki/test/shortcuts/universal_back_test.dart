import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

import '../helpers/source_guard.dart';

/// schema v7 → v8（用户拍板）：「返回上一级」全 app 统一成**一个**配置项。
///
/// Esc 一键从任何界面退一层：关词典 / 退出书籍 / 退出漫画 / 退出视频 / 退出设置页
/// 全部走 [ShortcutAction.globalBack]（[ShortcutScope.universal]，默认
/// Esc + Alt+← + 手柄 B）。此前它们是 4 个各自为政的配置项 + 1 处硬编码 Escape：
///   · readerDismissDict（Esc，只关词典，无弹窗时靠**最外层硬编码 Esc**才退书）
///   · readerExitBook（Ctrl+W，退书）—— 已删除
///   · videoEscape（Esc，逐级退出）—— 已删除
///   · mangaDismissDict（Esc，只关词典；漫画**根本没有**退出动作，Esc 是死键）
///
/// 本文件钉死四层不变式：默认表、跨 scope 无遮蔽、老快照迁移（含用户自定义搬运）、
/// 各表面执行体的源码切片。
void main() {
  const InputBinding esc = InputBinding(key: LogicalKeyboardKey.escape);
  const InputBinding altLeft = InputBinding(
    key: LogicalKeyboardKey.arrowLeft,
    modifiers: <ModifierKey>{ModifierKey.alt},
  );
  const InputBinding ctrlW = InputBinding(
    key: LogicalKeyboardKey.keyW,
    modifiers: <ModifierKey>{ModifierKey.ctrl},
  );

  const List<TargetPlatform> platforms = <TargetPlatform>[
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.android,
    TargetPlatform.iOS,
  ];

  group('默认表', () {
    test('globalBack 在每个平台都绑 Esc + Alt+← + 手柄 B', () {
      for (final TargetPlatform platform in platforms) {
        final ShortcutBindingSet back =
            ShortcutDefaults.forPlatform(platform)[ShortcutAction.globalBack]!;
        expect(back.keyboardBindings, contains(esc),
            reason: 'Esc 必须是「返回上一级」的默认键（$platform）');
        expect(back.keyboardBindings, contains(altLeft),
            reason: 'Alt+← 旧默认保留，不破坏老用户肌肉记忆（$platform）');
        expect(
          back.gamepadBindings.map((GamepadBinding b) => b.button),
          contains(GamepadButton.b),
          reason: '手柄 B = 返回（$platform）',
        );
      }
    });

    test('两个「只关词典」动作默认无键盘绑定（否则会遮蔽 Esc 的退出阶梯）', () {
      for (final TargetPlatform platform in platforms) {
        final Map<ShortcutAction, ShortcutBindingSet> defaults =
            ShortcutDefaults.forPlatform(platform);
        for (final ShortcutAction action in <ShortcutAction>[
          ShortcutAction.readerDismissDict,
          ShortcutAction.mangaDismissDict,
        ]) {
          expect(
            defaults[action]!.keyboardBindings,
            isEmpty,
            reason: '${action.key} 默认绑了键盘键就会在页面 scope 先命中，'
                '把 globalBack 的退出阶梯永久遮蔽（$platform）',
          );
        }
      }
    });

    test('universal 只装「返回上一级」一个动作（一个配置项，不是一组）', () {
      expect(
        ShortcutAction.actionsForScope(ShortcutScope.universal),
        <ShortcutAction>[ShortcutAction.globalBack],
      );
    });
  });

  group('跨 scope 无遮蔽（universal 是兜底解析，被页面 scope 绑同键就永不触发）', () {
    // universal 自成 co-active 组，故注册表的冲突检测**看不见**这类跨组遮蔽；
    // 这条守卫是它唯一的防线。
    const Set<GamepadButton> knownShadowedGamepad = <GamepadButton>{
      // 有意例外（TODO-700 约束2/4）：书内手柄 B = 有声书「上一句」，全程可用、
      // 不被返回夺舍。用户要在书里用手柄退出，走返回手势 / 底栏 / 改键。
      GamepadButton.b,
    };

    test('没有任何页面 scope 的默认键盘绑定与 globalBack 撞键', () {
      for (final TargetPlatform platform in platforms) {
        final Map<ShortcutAction, ShortcutBindingSet> defaults =
            ShortcutDefaults.forPlatform(platform);
        final Set<InputBinding> backKeys =
            defaults[ShortcutAction.globalBack]!.keyboardBindings.toSet();
        for (final ShortcutAction action in ShortcutAction.values) {
          if (action.scope == ShortcutScope.universal) continue;
          for (final InputBinding kb in defaults[action]!.keyboardBindings) {
            expect(
              backKeys.contains(kb),
              isFalse,
              reason: '${action.key}（${action.scope.name}）绑了 ${kb.serialize()}，'
                  '会在该页面遮蔽「返回上一级」（$platform）',
            );
          }
        }
      }
    });

    test('手柄侧同理，且已登记的有意例外只有有声书的 B', () {
      final Map<ShortcutAction, ShortcutBindingSet> defaults =
          ShortcutDefaults.forPlatform(TargetPlatform.windows);
      final Set<GamepadButton> backButtons = defaults[ShortcutAction.globalBack]!
          .gamepadBindings
          .map((GamepadBinding b) => b.button)
          .toSet();
      for (final ShortcutAction action in ShortcutAction.values) {
        if (action.scope == ShortcutScope.universal) continue;
        for (final GamepadBinding gp in defaults[action]!.gamepadBindings) {
          if (!backButtons.contains(gp.button)) continue;
          expect(
            knownShadowedGamepad.contains(gp.button),
            isTrue,
            reason: '${action.key} 占用了返回键 ${gp.button.name}，'
                '既不在例外表里 ⇒ 该页面的「返回上一级」被静默遮蔽',
          );
          expect(
            action.scope,
            ShortcutScope.audiobook,
            reason: 'B 的唯一合法占用者是有声书「上一句」',
          );
        }
      }
    });
  });

  group('schema v7 → v8 迁移', () {
    /// 造一份 v7 老快照：globalBack 只有 Alt+←，两个 dismissDict 绑 Esc，
    /// 已删除的 reader_exit_book / video_escape 仍在（各自旧默认）。
    Map<String, dynamic> v7Snapshot({
      ShortcutBindingSet? readerExitBook,
      ShortcutBindingSet? videoEscape,
      ShortcutBindingSet? readerDismissDict,
      ShortcutBindingSet? globalBack,
    }) {
      return <String, dynamic>{
        kShortcutSchemaVersionKey: 7,
        ShortcutAction.globalBack.key: (globalBack ??
                const ShortcutBindingSet(
                  keyboardBindings: <InputBinding>[altLeft],
                  gamepadBindings: <GamepadBinding>[
                    GamepadBinding(GamepadButton.b),
                  ],
                ))
            .toJson(),
        ShortcutAction.readerDismissDict.key: (readerDismissDict ??
                const ShortcutBindingSet(
                  keyboardBindings: <InputBinding>[esc],
                ))
            .toJson(),
        ShortcutAction.mangaDismissDict.key: const ShortcutBindingSet(
          keyboardBindings: <InputBinding>[esc],
        ).toJson(),
        'reader_exit_book': (readerExitBook ??
                const ShortcutBindingSet(
                  keyboardBindings: <InputBinding>[ctrlW],
                ))
            .toJson(),
        'video_escape': (videoEscape ??
                const ShortcutBindingSet(
                  keyboardBindings: <InputBinding>[esc],
                  gamepadBindings: <GamepadBinding>[
                    GamepadBinding(GamepadButton.b),
                  ],
                ))
            .toJson(),
      };
    }

    FushiShortcutRegistry load(Map<String, dynamic> json) {
      final FushiShortcutRegistry registry = FushiShortcutRegistry();
      registry.loadFromJsonString(jsonEncode(json), TargetPlatform.windows);
      return registry;
    }

    test('没动过任何键的老用户：Esc 补进 globalBack，两个 dismissDict 的 Esc 收回', () {
      final FushiShortcutRegistry registry = load(v7Snapshot());
      expect(
        registry.bindingsFor(ShortcutAction.globalBack).keyboardBindings,
        containsAll(<InputBinding>[esc, altLeft]),
      );
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.escape,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.universal,
        ),
        ShortcutAction.globalBack,
      );
      for (final ShortcutAction action in <ShortcutAction>[
        ShortcutAction.readerDismissDict,
        ShortcutAction.mangaDismissDict,
      ]) {
        expect(
          registry.bindingsFor(action).keyboardBindings,
          isEmpty,
          reason: '${action.key} 留着 Esc 会遮蔽退出阶梯',
        );
      }
      // 页面 scope 里 Esc 已无归属 ⇒ 兜底解析必然轮到 universal。
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.escape,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.reader,
        ),
        isNull,
      );
    });

    test('用户改过「关闭词典」键：保留其自定义，不强行收回', () {
      final FushiShortcutRegistry registry = load(
        v7Snapshot(
          readerDismissDict: const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.keyQ),
            ],
          ),
        ),
      );
      expect(
        registry.bindingsFor(ShortcutAction.readerDismissDict).keyboardBindings,
        contains(const InputBinding(key: LogicalKeyboardKey.keyQ)),
      );
    });

    test('用户绑在「关闭词典」上的鼠标侧键必须活下来（BUG-1071 的唯一鼠标通道）', () {
      final FushiShortcutRegistry registry = load(
        v7Snapshot(
          readerDismissDict: const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[esc],
            mouseBindings: <MouseBinding>[MouseBinding(3)],
          ),
        ),
      );
      final ShortcutBindingSet after =
          registry.bindingsFor(ShortcutAction.readerDismissDict);
      expect(after.keyboardBindings, isEmpty, reason: '键盘 Esc 按默认收回');
      expect(after.mouseBindings, contains(const MouseBinding(3)),
          reason: '鼠标绑定与本次统一无关，绝不能被顺手抹掉');
    });

    test('已删除动作：默认值直接丢弃（不给 globalBack 塞多余键位）', () {
      final FushiShortcutRegistry registry = load(v7Snapshot());
      final List<InputBinding> keys =
          registry.bindingsFor(ShortcutAction.globalBack).keyboardBindings;
      expect(keys, isNot(contains(ctrlW)),
          reason: '没改过的 Ctrl+W 是旧默认，其语义已被 Esc 覆盖，不该搬过来');
    });

    test('已删除动作：用户改过的键搬进 globalBack（改键不丢）', () {
      const InputBinding f4 = InputBinding(key: LogicalKeyboardKey.f4);
      final FushiShortcutRegistry registry = load(
        v7Snapshot(
          readerExitBook: const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[f4],
          ),
        ),
      );
      expect(
        registry.bindingsFor(ShortcutAction.globalBack).keyboardBindings,
        contains(f4),
        reason: '用户特意把退书改到 F4，统一之后必须仍能用 F4 退出',
      );
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.f4,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.universal,
        ),
        ShortcutAction.globalBack,
      );
    });

    test('已删除动作的 legacy key 不会永久回写（迁移后从快照里消失）', () {
      final FushiShortcutRegistry registry = load(
        v7Snapshot(
          videoEscape: const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.f9),
            ],
          ),
        ),
      );
      final Map<String, dynamic> out = registry.toJson();
      expect(out.containsKey('video_escape'), isFalse);
      expect(out.containsKey('reader_exit_book'), isFalse);
      expect(out[kShortcutSchemaVersionKey], kShortcutSchemaVersion);
    });

    test('用户改过 globalBack 自己的键：不被新默认覆盖', () {
      final FushiShortcutRegistry registry = load(
        v7Snapshot(
          globalBack: const ShortcutBindingSet(
            keyboardBindings: <InputBinding>[
              InputBinding(key: LogicalKeyboardKey.backspace),
            ],
          ),
        ),
      );
      final List<InputBinding> keys =
          registry.bindingsFor(ShortcutAction.globalBack).keyboardBindings;
      expect(
        keys,
        contains(const InputBinding(key: LogicalKeyboardKey.backspace)),
      );
      expect(keys, isNot(contains(esc)), reason: '用户已自定义返回键，迁移不得塞回 Esc');
    });
  });

  group('执行体源码切片守卫（页面过重，pumpWidget 不现实故走静态断言）', () {
    /// 切出某个 case 分支：从 `case ShortcutAction.<name>:` 起到下一个
    /// `case ShortcutAction.` 止。
    ///
    /// 定位与切片都跑在**等长掩码**后的源码上（共享 `maskComments`）：注释里的
    /// 同名 case 标签不会把窗口锚歪，分支体内的注释也不再能给下面的断言背书。
    /// 掩码与原文逐字节等长，故 indexOf/substring 的下标语义不变。
    String caseSlice(String source, String name) {
      final String code = maskComments(source);
      final String start = 'case ShortcutAction.$name:';
      final int startIdx = code.indexOf(start);
      expect(startIdx, greaterThanOrEqualTo(0), reason: '$name 的 case 分支应存在');
      final int endIdx =
          code.indexOf('case ShortcutAction.', startIdx + start.length);
      expect(endIdx, greaterThan(startIdx));
      return code.substring(startIdx, endIdx);
    }

    const String readerPath =
        'lib/src/pages/implementations/reader_hibiki/caret.part.dart';

    test('阅读器 readerDismissDict 分支只关词典、绝不退书', () {
      final String slice =
          caseSlice(File(readerPath).readAsStringSync(), 'readerDismissDict');
      expect(
        slice.contains('maybePop') || slice.contains('.pop('),
        isFalse,
        reason: '「只关词典」动作绝不退书——退出是 globalBack 的职责',
      );
      expect(slice.contains('clearDictionaryResult'), isTrue);
      expect(slice.contains('KeyEventResult.ignored'), isTrue,
          reason: '无弹窗时不消费（ignored），不得吞键');
    });

    test('阅读器 globalBack 分支 = 先关词典、再 maybePop 退书（BUG-782 闸门）', () {
      final String slice =
          caseSlice(File(readerPath).readAsStringSync(), 'globalBack');
      expect(slice.contains('isDictionaryShown'), isTrue,
          reason: '第一级：词典弹窗可见时只关弹窗，留在书里');
      expect(slice.contains('clearDictionaryResult'), isTrue);
      expect(slice.contains('maybePop('), isTrue,
          reason: '第二级：退书必须经 maybePop 触发 PopScope→onWillPop');
      expect(
        RegExp(r'(?<!maybe)\.pop\(').hasMatch(slice),
        isFalse,
        reason: '不得出现绕过 PopScope 的裸 pop()（BUG-782）',
      );
    });

    test('阅读器键盘/手柄解析都以 universal 兜底（否则 Esc 到不了执行体）', () {
      final String code = maskComments(File(readerPath).readAsStringSync());
      expect(
        'scope: ShortcutScope.universal'.allMatches(code).length,
        2,
        reason: '键盘 (_resolveReaderKeyboardShortcut) 与手柄 (_handleGamepadButton) '
            '各一处兜底解析；少一处就有一条通道退不出书',
      );
    });

    test('漫画：globalBack 有弹窗关弹窗、无弹窗退出（此前 Esc 是死键）', () {
      const String path = 'lib/src/media/manga/reader/manga_hibiki_page.dart';
      final String code = maskComments(File(path).readAsStringSync());
      expect(code.contains('MangaReaderInputAction.backOrExit'), isTrue,
          reason: '漫画必须有「退出」这个落点动作');
      expect(code.contains('scope: ShortcutScope.universal'), isTrue,
          reason: '解析必须兜底 universal，否则 Esc 仍解析不到任何动作');
      final int idx = code.indexOf('if (action == ShortcutAction.globalBack)');
      expect(idx, greaterThanOrEqualTo(0));
      final String slice = code.substring(idx, idx + 260);
      expect(slice.contains('dismissDictionary'), isTrue,
          reason: '第一级：弹窗可见先关弹窗');
      expect(slice.contains('backOrExit'), isTrue, reason: '第二级：否则退出漫画');
    });

    test('视频：逐级退出阶梯挂在 globalBack 上（原 videoEscape 已删除）', () {
      const String path = 'lib/src/media/video/video_player_shortcuts.dart';
      final String code = maskComments(File(path).readAsStringSync());
      expect(code.contains('ShortcutAction.globalBack: actions.escape'), isTrue,
          reason: '视频页的退出阶梯必须由统一的「返回上一级」驱动');
      expect(code.contains('videoEscape'), isFalse,
          reason: '旧的 video 专属退出动作已删除，不得残留引用');
    });

    test('全局兜底按注册表绑定解析，不再硬编码 Escape', () {
      const String path = 'lib/src/shortcuts/global_navigation.dart';
      final String code = maskComments(File(path).readAsStringSync());
      expect(code.contains('scope: ShortcutScope.universal'), isTrue,
          reason: '最外层兜底必须按 universal 解析 globalBack');
      // 唯一允许残留的硬编码 Escape 判定：注册表缺席（测试宿主）时的降级，以及
      // 「Esc 落在弹层上让给框架」那一条既有语义。
      expect(
        'LogicalKeyboardKey.escape'.allMatches(code).length,
        2,
        reason: '硬编码 Escape 只允许出现在无注册表降级 + 弹层让路两处；'
            '多出来的就是又一条改不动的隐形返回路径',
      );
    });
  });
}
