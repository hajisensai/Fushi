import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../helpers/source_guard.dart';

/// galgame voice hook 的**进程间契约只能有一份真相源**：
/// `native/galgame_hook/include/voice_hook_ipc.h`。
///
/// 为什么要守卫：host 读侧曾经在 `hibiki/windows/runner/voice_hook_ipc.h` 放一份手抄副本，
/// 注释写着「真相源在独立仓库 hibiki-hook，须同步」。那个仓库后来合进本仓，人工同步这一步
/// 就退化成纯粹的漂移源——本体 `hibiki.exe` 编副本、随包内置的 helper 编真相源，两边的
/// 常量与**结构布局**各活各的。
///
/// 这不是假想风险，副本真的漂开过：它的 `HasReadyGameResourceAudio` 漏了
/// Tyrano / BGI / Artemis / CatSystem2 / Malie 五个引擎的 ready 位，这些引擎的资源音频
/// hook 装好了，host 仍判 `raw_voice_ready == false`，于是逐句语音被当成不可用、整段退回
/// 系统 loopback 整机混音——正是 BUG-1159 那条失败链的另一个入口。
///
/// 版本号漂开的后果更直接：读侧 `ProtocolMatches` 判不符 → `protocol_mismatch` →
/// 用户看到「捕获组件版本与 Hibiki 不一致，请更新或重新安装 galgame 捕获组件」，而 helper
/// 自 BUG-1196 起就是随主包内置、没有独立更新通道，这句处置指向一个不存在的动作。
///
/// 所以守的是结构而不是数值：**host 侧不得存在第二处契约定义**，且读侧必须直接 include
/// 真相源。数值一致由「同一个文件」保证，不需要也不应该靠人对齐。
void main() {
  /// 仓库根：`flutter test` 的 cwd 是 `hibiki/`，也允许从仓库根跑。
  Directory repoRoot() {
    for (final String candidate in <String>['..', '.']) {
      final Directory native =
          Directory(p.join(candidate, 'native', 'galgame_hook', 'include'));
      if (native.existsSync()) return Directory(p.normalize(candidate));
    }
    fail('定位不到仓库根（native/galgame_hook/include 不存在），别让空集假绿');
  }

  /// app 侧 Windows 原生树（runner + 插件桥），即「不得再有第二份契约」的范围。
  Directory hostWindowsTree(Directory root) {
    final Directory dir = Directory(p.join(root.path, 'hibiki', 'windows'));
    expect(dir.existsSync(), isTrue, reason: 'hibiki/windows 不存在，扫描范围是空的');
    return dir;
  }

  const String kVersionConstant = 'kSharedVersion';
  const String kHeaderStruct = 'SharedHeader';

  group('IPC 契约单一真相源守卫', () {
    test('native 真相源确实定义契约（守卫自身的锚点不能是空的）', () {
      final File truth = File(p.join(repoRoot().path, 'native', 'galgame_hook',
          'include', 'voice_hook_ipc.h'));
      expect(truth.existsSync(), isTrue,
          reason: '真相源 native/galgame_hook/include/voice_hook_ipc.h 不见了');
      final String masked = maskComments(truth.readAsStringSync());
      expect(
          masked, matches(RegExp('constexpr\\s+uint32_t\\s+$kVersionConstant')),
          reason: '真相源必须定义 $kVersionConstant，否则下面两条守卫在守一个空契约');
      expect(masked, matches(RegExp('struct\\s+$kHeaderStruct')),
          reason: '真相源必须定义 $kHeaderStruct 布局');
    });

    test('host 读侧 include 的必须是 native 真相源本身，不是任何本地副本', () {
      final Directory root = repoRoot();
      final File reader = File(p.join(
          root.path, 'hibiki', 'windows', 'runner', 'voice_hook_reader.cpp'));
      expect(reader.existsSync(), isTrue, reason: '读侧实现不见了，扫描范围是空的');
      // 注释里的 include 不算数（旧副本的注释里就写着这个路径）。
      final String masked = maskComments(reader.readAsStringSync());
      final RegExpMatch? include =
          RegExp(r'#include\s+"([^"]*voice_hook_ipc\.h)"').firstMatch(masked);
      expect(include, isNotNull,
          reason: '读侧必须 include 契约头，才谈得上「include 的是哪一份」');
      final String includePath = include!.group(1)!;
      final String resolved = p.normalize(
          p.join(root.path, 'hibiki', 'windows', 'runner', includePath));
      // 判据是**解析后的真实文件**落在真相源目录，不是「路径串长得像」：
      // 任何本地副本（含同名文件）都解析不到 native/galgame_hook/include 去。
      expect(
          p.equals(
              resolved,
              p.join(root.path, 'native', 'galgame_hook', 'include',
                  'voice_hook_ipc.h')),
          isTrue,
          reason: '读侧 include 解析到 $resolved，不是 native 真相源');
      expect(File(resolved).existsSync(), isTrue,
          reason: 'include 的路径不存在，这份改动根本编不过');
    });

    test('hibiki/windows 下不得有第二处契约定义（常量或结构）', () {
      final Directory tree = hostWindowsTree(repoRoot());
      final List<File> sources = tree
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((File f) => const <String>['.h', '.hpp', '.cc', '.cpp']
              .contains(p.extension(f.path).toLowerCase()))
          .toList();
      expect(sources, isNotEmpty, reason: '一个 C++ 源文件都没扫到，空集假绿');
      final List<String> offenders = <String>[];
      for (final File source in sources) {
        final String masked = maskComments(source.readAsStringSync());
        final bool definesConstant =
            RegExp('constexpr\\s+uint32_t\\s+$kVersionConstant')
                .hasMatch(masked);
        final bool definesLayout =
            RegExp('struct\\s+$kHeaderStruct\\s*\\{').hasMatch(masked);
        if (definesConstant || definesLayout) {
          offenders.add(p.relative(source.path, from: tree.path));
        }
      }
      expect(offenders, isEmpty,
          reason: 'host 侧重新定义了 IPC 契约：${offenders.join(', ')}。'
              '契约只能有 native/galgame_hook/include/voice_hook_ipc.h 一份；'
              '手抄副本会让本体和内置 helper 各编各的版本，漂开后用户看到的是'
              '「捕获组件版本不一致」这种指向不存在动作的处置。');
    });
  });

  group('契约不符的处置文案不得指向不存在的动作', () {
    /// 捕获组件自 BUG-1196 起随主包内置、零网络（守卫见
    /// `gal_helper_no_network_guard_test.dart`），用户手上**没有**「单独更新/重装捕获组件」
    /// 这个动作。文案里再写它，用户只会照做一遍然后发现毫无变化——处置必须是「更新本体」。
    String valueOf(String file, String key) {
      final File json =
          File(p.join(repoRoot().path, 'hibiki', 'lib', 'i18n', file));
      expect(json.existsSync(), isTrue, reason: '$file 不存在，扫描范围是空的');
      final RegExpMatch? match =
          RegExp('"$key"\\s*:\\s*"((?:[^"\\\\]|\\\\.)*)"')
              .firstMatch(json.readAsStringSync());
      expect(match, isNotNull, reason: '$file 里没有 $key');
      return match!.group(1)!;
    }

    test('zh-CN / en 的处置必须是真能做的动作，不提「重新安装捕获组件」', () {
      const String key = 'game_hook_reason_protocol_mismatch';
      final String zh = valueOf('strings_zh-CN.i18n.json', key);
      final String en = valueOf('strings.i18n.json', key);
      // ① 没有独立的组件安装包可重装（BUG-1196 起零网络、随主包内置）。
      expect(zh, isNot(contains('重新安装')), reason: '没有独立的捕获组件安装包可重装，这句处置是空头支票');
      expect(en.toLowerCase(), isNot(contains('reinstall')),
          reason: 'no standalone capture component exists to reinstall');
      // ② 也不能只让用户「更新本体」：本体已是最新时照样能撞上这条——游戏进程里还挂着
      //    上一次注入的旧组件。第一处置必须是重开游戏，这才是那个局面下唯一有效的动作。
      expect(zh, contains('重开'), reason: '本体最新也可能撞上：游戏进程里挂着旧组件，只能重开游戏清掉');
      expect(en.toLowerCase(), contains('launch it again'),
          reason: 'restarting the game is the only fix when the game process '
              'still holds the previous component');
      expect(zh, contains('Fushi'), reason: '要说清组件是内置的，用户没有单独装它这一步');
    });
  });
}
