import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:fushi_cli/fushi_cli.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/mining/galgame_hook_code_profile.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/ops/op_context.dart';

/// Galgame Hook Code 配置（`luna_hook_profiles.tsv`）的控制通道路由：文本 Hook 页「导入 /
/// 导出 Hook Code」两个按钮背后的 [LunaHookCodeProfileStore.replaceFrom] /
/// [LunaHookCodeProfileStore.exportTo]，文件选择器换成路径参数（拍板台 PGpPujl99g）。
/// 只做 Windows（Galgame Hook 的平台边界，见 `docs/agent/galgame-hooking.md`）。
///
/// CLI 侧是 `fushi_cli game hook-codes / hook-codes-export / hook-codes-import`。
List<CtlRoute> buildGameHookCodeCtlRoutes(OpContext context) =>
    buildGameHookCodeCtlRoutesFor(gameHookCodeCtlDeps(context));

final Expando<GameHookCodeCtlDeps> _depsByContext =
    Expando<GameHookCodeCtlDeps>('gameHookCodeCtlDeps');

/// [context] 上的依赖（路由与 `op_descriptions_game_hook_codes.dart` 的撤销共用同一份）。
GameHookCodeCtlDeps gameHookCodeCtlDeps(OpContext context) =>
    _depsByContext[context] ??= GameHookCodeCtlDeps(
      store: LunaHookCodeProfileStore.openDefault,
      available: () => Platform.isWindows,
      gamesEnabled: () =>
          context.appModel.moduleVisibility.isEnabled(ModuleId.games),
    );

/// 测试：给 [context] 换上假依赖（临时目录下的 store、平台判据）。
@visibleForTesting
void debugOverrideGameHookCodeCtlDeps(
  OpContext context,
  GameHookCodeCtlDeps deps,
) => _depsByContext[context] = deps;

/// [store] 当前整份内容的指纹（导入的撤销据此判断之后有没有被改过）。
Future<String> hookCodeStoreRevision(LunaHookCodeProfileStore store) async =>
    sha1
        .convert(utf8.encode(await store.file.readAsString(encoding: utf8)))
        .toString();

/// 路由根。
const String kGameHookCodeCtlRoot = '/api/admin/game/hook-codes';

/// 路由依赖（测试注入临时目录下的 store）。
class GameHookCodeCtlDeps {
  const GameHookCodeCtlDeps({
    required this.store,
    required this.available,
    required this.gamesEnabled,
  });

  final Future<LunaHookCodeProfileStore> Function() store;
  final bool Function() available;
  final bool Function() gamesEnabled;
}

/// 路由表本体。
List<CtlRoute> buildGameHookCodeCtlRoutesFor(GameHookCodeCtlDeps deps) {
  Future<LunaHookCodeProfileStore> requireStore() async {
    if (!deps.available()) {
      throw const CtlFailure.unsupported('Galgame Hook 只支持 Windows');
    }
    if (!deps.gamesEnabled()) {
      throw const CtlFailure.rejected('「游戏」模块已关闭（设置 › 功能模块）');
    }
    return deps.store();
  }

  String absolutePath(CtlCall call) {
    final String raw = call.requireString('path').trim();
    if (!p.isAbsolute(raw)) {
      throw CtlFailure.badRequest('path 必须是绝对路径：$raw');
    }
    return p.normalize(raw);
  }

  return <CtlRoute>[
    CtlRoute.get(kGameHookCodeCtlRoot, (CtlCall call) async {
      final LunaHookCodeProfileStore store = await requireStore();
      final List<LunaHookCodeProfile> profiles = await store.load();
      return <String, Object?>{
        'path': store.file.path,
        'profiles': <Object?>[
          for (final LunaHookCodeProfile profile in profiles)
            <String, Object?>{
              'executableSha256': profile.executableSha256,
              'module': profile.moduleName,
              'codepage': profile.codepage,
              'hookCode': profile.hookCode,
              if (profile.label.isNotEmpty) 'label': profile.label,
            },
        ],
      };
    }),
    CtlRoute.post('$kGameHookCodeCtlRoot/export', (CtlCall call) async {
      final LunaHookCodeProfileStore store = await requireStore();
      final String path = absolutePath(call);
      if (!Directory(p.dirname(path)).existsSync()) {
        throw CtlFailure.notFound('目录不存在：${p.dirname(path)}');
      }
      if (File(path).existsSync() && call.optBool('overwrite') != true) {
        throw CtlFailure.conflict('$path 已存在：确认覆盖后带 overwrite=true');
      }
      await store.exportTo(File(path));
      return <String, Object?>{
        'path': path,
        'profiles': (await store.load()).length,
      };
    }),
    CtlRoute.post('$kGameHookCodeCtlRoot/import', (CtlCall call) async {
      final LunaHookCodeProfileStore store = await requireStore();
      final String path = absolutePath(call);
      final File source = File(path);
      if (!source.existsSync()) throw CtlFailure.notFound('文件不存在：$path');
      try {
        // 与界面「导入」同一方法：整份替换（不合并），坏行整份拒绝。
        await store.replaceFrom(source);
      } on FormatException catch (e) {
        throw CtlFailure.rejected('不是有效的 Hook Code 配置：${e.message}');
      }
      return <String, Object?>{
        'path': path,
        'profiles': (await store.load()).length,
        // 撤销用：导入后的内容指纹（判断之后有没有被改过）。
        'revision': await hookCodeStoreRevision(store),
      };
    }),
  ];
}
