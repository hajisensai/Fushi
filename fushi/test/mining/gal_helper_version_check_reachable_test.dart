import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-1448：`ensureInjector` 被「injector 文件在不在」挡在门外，随包新组件永不换入。
///
/// 用户现场（本体 `1.3.1+1171`，2026-08-02）：
/// - `galgame_helper/voice_hook_x86.zip.sha256` = `3a1c4192…`（随包，8/2）
/// - `voice_hook/x86/installed.sha256`          = `b72b437a…`（已装，7/28）
/// - 两者不符，且 `fushi_voice_hook.dll` / `fushi_voice_injector.exe` 与随包版本
///   逐字节不同（LunaHook/LunaHost 相同——正是 IPC v13 只改自编两件的指纹）
///
/// 版本对账逻辑（`_ensureBundledVersion`，BUG-1246）本身是对的，但三个启动入口都写着
/// `if (defaultInjectorResolver(...) == null) { ensureInjector(...) }`，而该 resolver
/// 只判断 `fushi_voice_injector.exe` 是否存在（`gal_hook_session_controller.dart:940`）。
/// 文件在 ⇒ 整个分支跳过 ⇒ 对账从不执行 ⇒ 旧 hook DLL 建出旧契约共享内存段 ⇒
/// 本体 `ProtocolMatches` 判否 ⇒ `protocol_mismatch` + 降级 loopback。
///
/// 「要不要装」用文件存在性近似，是这条 bug 的全部成因——近似错了：真正的判据是
/// 「版本对不对」。本守卫钉死三个入口都必须**无条件**走到 `ensureInjector`。
void main() {
  const List<String> entryPoints = <String>[
    'lib/src/pages/implementations/games_library_page.dart',
    'lib/src/pages/implementations/galgame_home_page.dart',
    'lib/src/pages/implementations/texthooker_page.dart',
  ];

  group('三个启动入口都必须无条件做 helper 版本对账 (BUG-1448)', () {
    for (final String path in entryPoints) {
      test('$path 不拿 injector 存在性当前置门', () {
        final File file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason: '启动入口文件不在了？守卫失去锚点，先修路径再谈断言',
        );
        final String src = file.readAsStringSync();

        // 前提：这个入口确实还在调 ensureInjector。否则下面的「没有短路」会因为
        // 「压根没调用」而假绿——那是比短路更严重的回归，必须先判红。
        expect(
          containsIdentifierCall(src, 'ensureInjector'),
          isTrue,
          reason: '$path 不再调用 ensureInjector，helper 版本对账整条链断了',
        );

        // 真正的判据：resolver 的返回值不得被用来决定「要不要 ensureInjector」。
        // 该入口一旦重新出现 defaultInjectorResolver，就说明短路回来了。
        expect(
          containsCodeLine(src, 'defaultInjectorResolver'),
          isFalse,
          reason: '$path 又用 defaultInjectorResolver 当前置门：'
              '文件在但版本旧时会跳过换入，正是 BUG-1448 的原始形态',
        );
      });
    }
  });
}
