// Flutter services 也导出一个 ModifierKey（raw_keyboard），与快捷键注册表的同名
// 类型撞车；这里只需要 LogicalKeyboardKey，把它 hide 掉。
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';

/// BUG-1269：宿主要交回弹窗的 token 表怎么算出来的。
///
/// 契约是**整份 scope**，不是点名几个动作：弹窗持焦时断掉的是宿主的整条输入通道，
/// 只放行点名动作等于「弹窗开着时用户只准用这几个键」——翻页/播放暂停/有声书控制
/// 照样全部落空，那是同一个 bug 的其它未报症状。名单本身就是补丁。
///
/// 代价是撞键面从「几个动作」扩到「整个 scope」，所以减去 dictionaryPopup scope
/// （切词条/制卡是弹窗内动作）这一条必须锁死，否则弹窗里的交互会被宿主抢走。
void main() {
  HibikiShortcutRegistry registryWith(
    Map<ShortcutAction, ShortcutBindingSet> bindings,
  ) {
    final HibikiShortcutRegistry registry = HibikiShortcutRegistry();
    registry.loadFromJson(<String, dynamic>{
      for (final MapEntry<ShortcutAction, ShortcutBindingSet> e
          in bindings.entries)
        e.key.key: e.value.toJson(),
    });
    return registry;
  }

  test('导出整份 scope 的当前键盘/鼠标绑定（改键自动跟随）', () {
    final HibikiShortcutRegistry registry =
        registryWith(<ShortcutAction, ShortcutBindingSet>{
      ShortcutAction.readerDismissDict: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyD,
            modifiers: <ModifierKey>{ModifierKey.ctrl},
          ),
        ],
        mouseBindings: <MouseBinding>[MouseBinding(3)],
      ),
      // 同 scope 的另一个动作：证明导出的是整份 scope 而不是点名的那一个。
      ShortcutAction.readerExitBook: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(
            key: LogicalKeyboardKey.keyW,
            modifiers: <ModifierKey>{ModifierKey.ctrl},
          ),
        ],
      ),
    });

    final DictionaryPopupInputSpec spec = dictionaryPopupInputSpecFor(
      registry: registry,
      scope: ShortcutScope.reader,
    );

    expect(spec.keyTokens, contains('Ctrl+KeyD'),
        reason: 'token 直接取 InputBinding.serialize()，与 JS 侧判据同一套字面量');
    expect(spec.mouseButtons, contains(3));
    expect(spec.keyTokens, contains('Ctrl+KeyW'),
        reason: '同 scope 的其它动作（退出书籍）也必须进表——弹窗持焦时断掉的是整条'
            '输入通道，只放行「关闭词典」等于让其它键继续失效');
  });

  test('恒减去 dictionaryPopup scope 已占用的键（弹窗内动作优先于宿主）', () {
    // 用户把视频的某个动作和弹窗「上一个词条」绑到了同一个键 / 同一个鼠标键。
    final HibikiShortcutRegistry registry =
        registryWith(<ShortcutAction, ShortcutBindingSet>{
      ShortcutAction.videoTogglePlayPause: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.arrowLeft),
          InputBinding(key: LogicalKeyboardKey.escape),
        ],
        mouseBindings: <MouseBinding>[MouseBinding(3), MouseBinding(4)],
      ),
      ShortcutAction.popupPrevEntry: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.arrowLeft),
        ],
        mouseBindings: <MouseBinding>[MouseBinding(4)],
      ),
    });

    final DictionaryPopupInputSpec spec = dictionaryPopupInputSpecFor(
      registry: registry,
      scope: ShortcutScope.video,
    );

    expect(spec.keyTokens, <String>['Escape'],
        reason: 'ArrowLeft 被弹窗的「上一个词条」占着，宿主不得抢走');
    expect(spec.mouseButtons, <int>[3], reason: '鼠标侧同理：4 号键归弹窗，只留 3');
  });

  test('注册表未装载时返回空表（空表 ≠ 用户清空了绑定，但下发空表安全）', () {
    expect(
      dictionaryPopupInputSpecFor(
        registry: HibikiShortcutRegistry(),
        scope: ShortcutScope.reader,
      ).isEmpty,
      isTrue,
    );
  });

  test('token → 动作解析：键盘与鼠标取值域不相交，共用一个入口', () {
    final HibikiShortcutRegistry registry =
        registryWith(<ShortcutAction, ShortcutBindingSet>{
      ShortcutAction.readerDismissDict: const ShortcutBindingSet(
        keyboardBindings: <InputBinding>[
          InputBinding(key: LogicalKeyboardKey.escape),
        ],
        mouseBindings: <MouseBinding>[MouseBinding(3)],
      ),
    });

    expect(
      resolveDictionaryPopupInputToken(
        registry: registry,
        token: 'Escape',
        scope: ShortcutScope.reader,
      ),
      ShortcutAction.readerDismissDict,
    );
    expect(
      resolveDictionaryPopupInputToken(
        registry: registry,
        token: 'Mouse3',
        scope: ShortcutScope.reader,
      ),
      ShortcutAction.readerDismissDict,
      reason: '弹窗回传的鼠标 token 形如 Mouse<n>，须能被 MouseBinding 吃下',
    );
    expect(
      resolveDictionaryPopupInputToken(
        registry: registry,
        token: 'Mouse1',
        scope: ShortcutScope.reader,
      ),
      isNull,
      reason: '未绑定的按钮不得解析出动作',
    );
  });
}
