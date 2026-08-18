import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/galgame_hook_runtime_stage.dart';
import 'package:path/path.dart' as p;

/// BUG-1708：注入运行时必须从**安装目录之外的副本**启动。
///
/// 注入进宿主的 hook DLL 由宿主持有到宿主退出（我们不卸载它——还原 detour 失败会让用户
/// 正在玩的游戏当场崩溃）。宿主一旦是常驻程序（实测是微信，连开三天），安装目录里那几个
/// 文件就永久不可替换，于是每次应用内更新都在 Inno 的 PrepareToInstall 中止、整包回滚，
/// 而 app 已经为更新退出了 —— 用户看到「Fushi 自己关了再没打开」。
void main() {
  group('GalgameHookRuntimeStage', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('gal_stage_test_');
    });

    tearDown(() {
      try {
        root.deleteSync(recursive: true);
      } catch (_) {
        // Windows 上偶发句柄延迟，测试目录留给系统清理即可。
      }
    });

    Directory sourceDirFor(String arch, {int payload = 1}) {
      final Directory source = Directory(p.join(root.path, 'install', arch))
        ..createSync(recursive: true);
      for (final String name
          in GalgameHookRuntimeStage.stagedFilesForArch(arch)) {
        File(p.join(source.path, name))
          ..createSync(recursive: true)
          ..writeAsBytesSync(List<int>.filled(payload, payload % 256));
      }
      // 安装目录里真实存在、但**不该**被搬走的大件（140 MB 的提取运行时）。
      Directory(p.join(source.path, 'unity_audio_runtime'))
          .createSync(recursive: true);
      File(p.join(source.path, 'unity_audio_runtime',
              'fushi_unity_audio_extract.exe'))
          .writeAsStringSync('extractor');
      return source;
    }

    GalgameHookRuntimeStage stageFor(Directory Function(String) source) =>
        GalgameHookRuntimeStage(
          sourceDirectoryOverride: source,
          stageRootOverride: () async =>
              Directory(p.join(root.path, 'support', 'voice_hook_runtime')),
        );

    test('暂存后返回的 injector 不在安装目录里', () async {
      final Directory source = sourceDirFor('x64');
      final GalgameHookRuntimeStage stage = stageFor((_) => source);

      final String? injector = await stage.ensureStaged(arch: 'x64');

      expect(injector, isNotNull, reason: '源文件齐全时必须暂存成功');
      expect(
        p.isWithin(source.path, injector!),
        isFalse,
        reason: '从安装目录启动 injector 就是 BUG-1708 的根因，绝不能回退到那里',
      );
      expect(p.basename(injector), 'fushi_voice_injector.exe');
      expect(File(injector).existsSync(), isTrue);
    });

    test('副本目录的父目录名仍是架构名', () async {
      // galHookHelperArchTag 从 injector 路径的**父目录名**认架构；父目录一旦不叫
      // x86/x64，架构标签会静默变成空串，诊断与 helper 校验一起失真。
      final Directory source = sourceDirFor('x64');
      final String? injector =
          await stageFor((_) => source).ensureStaged(arch: 'x64');

      expect(p.basename(p.dirname(injector!)), 'x64');
    });

    test('暂存清单包含全部会被宿主长期持有的组件', () {
      expect(
        GalgameHookRuntimeStage.stagedFilesForArch('x64'),
        containsAll(<String>[
          'fushi_voice_hook.dll', // 注入进宿主
          'LunaHook64.dll', // 由 LunaHost 注入进宿主
          'LunaHost64.dll', // injector 进程加载
          'fushi_voice_injector.exe', // 必须与上面三者同目录
        ]),
      );
      expect(
        GalgameHookRuntimeStage.stagedFilesForArch('x86'),
        containsAll(<String>[
          'fushi_voice_hook.dll',
          'LunaHook32.dll',
          'LunaHost32.dll',
          'fushi_voice_injector.exe',
          'LoaderDll.dll', // 转区路径同目录依赖
          'LocaleEmulator.dll',
        ]),
      );
    });

    test('暂存清单是分发清单的子集', () {
      // 搬出一个缺依赖的半套运行时（比如漏了 LunaHost）会让文本 hook 静默变哑。
      expect(stagedFilesAreSubsetOfDistribution('x64'), isTrue);
      expect(stagedFilesAreSubsetOfDistribution('x86'), isTrue);
    });

    test('不搬 140 MB 的 unity 提取运行时', () async {
      final Directory source = sourceDirFor('x64');
      final String? injector =
          await stageFor((_) => source).ensureStaged(arch: 'x64');

      expect(
        Directory(p.join(p.dirname(injector!), 'unity_audio_runtime'))
            .existsSync(),
        isFalse,
        reason: '提取运行时只被短命子进程用，且安装器能杀掉它，没有理由复制 140 MB',
      );
      expect(
        GalgameHookRuntimeStage.stagedFilesForArch('x64')
            .any((String name) => name.contains('unity')),
        isFalse,
      );
    });

    test('组件内容变了要换一个新的副本目录', () async {
      // 应用内更新是 Inno 直接覆盖文件、不重写 installed.sha256，所以分版必须看内容。
      // 共用目录会让被旧宿主锁住的旧副本永远挡着新版落地。
      final Directory first = sourceDirFor('x64', payload: 1);
      final String? before =
          await stageFor((_) => first).ensureStaged(arch: 'x64');

      final Directory second = sourceDirFor('x64', payload: 7);
      final String? after =
          await stageFor((_) => second).ensureStaged(arch: 'x64');

      expect(before, isNotNull);
      expect(after, isNotNull);
      expect(p.dirname(after!), isNot(p.dirname(before!)));
    });

    test('源目录缺文件时返回 null，而不是退回安装目录', () async {
      final Directory source = sourceDirFor('x64');
      File(p.join(source.path, 'LunaHost64.dll')).deleteSync();

      expect(await stageFor((_) => source).ensureStaged(arch: 'x64'), isNull);
    });

    test('并发请求同一架构只暂存一次', () async {
      final Directory source = sourceDirFor('x64');
      final GalgameHookRuntimeStage stage = stageFor((_) => source);

      final List<String?> results =
          await Future.wait<String?>(<Future<String?>>[
        stage.ensureStaged(arch: 'x64'),
        stage.ensureStaged(arch: 'x64'),
        stage.ensureStaged(arch: 'x64'),
      ]);

      expect(results.toSet().length, 1);
      expect(results.first, isNotNull);
    });

    test('unity 运行时位置仍指向安装目录', () async {
      final Directory source = sourceDirFor('x64');
      final String? unity =
          stageFor((_) => source).unityRuntimeDirectory(arch: 'x64');

      expect(unity, isNotNull);
      expect(p.isWithin(source.path, unity!), isTrue);
    });
  }, skip: !Platform.isWindows);
}
