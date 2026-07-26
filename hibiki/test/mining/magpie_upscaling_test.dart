// 内置 Magpie 窗口超分（阶段二）的单测。
//
// 分三组：
// 1. 三态开关 → 后端的裁决（纯函数，含非 Windows 边界）
// 2. profile 增量改写的 best-effort 退化（每一条 skip 原因都要有用例）
// 3. 生命周期收束（用假 Win32 桥 + 假进程启动器，在任意平台可跑）
//
// 外加一组**源码守卫**，钉住三个读源码挖出来的硬约束，防止后人「顺手优化」掉。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/magpie_upscaling.dart';
import 'package:hibiki/src/mining/magpie_upscaling_service.dart';
import 'package:path/path.dart' as p;

/// 一份「Magpie 已经跑过一次、配置完整」的最小 config。
Map<String, dynamic> baseConfig({
  int defaultScalingMode = 2,
  int scalingModeCount = 7,
  List<Map<String, dynamic>> extraProfiles = const <Map<String, dynamic>>[],
}) =>
    <String, dynamic>{
      'theme': 2,
      'scalingModes': List<Map<String, dynamic>>.generate(
        scalingModeCount,
        (int i) => <String, dynamic>{'name': 'mode$i'},
      ),
      'profiles': <Map<String, dynamic>>[
        <String, dynamic>{'scalingMode': defaultScalingMode},
        ...extraProfiles,
      ],
    };

const MagpieWindowIdentity kGame = MagpieWindowIdentity(
  executablePath: r'D:\Games\Sakura\sakura.exe',
  windowClassName: 'KiriKiriClass',
);

const String kHibikiExe = r'C:\Program Files\Hibiki\Hibiki.exe';

/// 假 Win32 桥：完全不碰 FFI，任意平台可跑。
class FakeBridge implements MagpieWin32Bridge {
  FakeBridge({
    this.identity = kGame,
    this.running = false,
  });

  MagpieWindowIdentity? identity;
  bool running;
  int quitBroadcasts = 0;

  @override
  MagpieWindowIdentity? identityForWindow(int hwnd) => identity;

  @override
  bool isMagpieRunning() => running;

  @override
  bool broadcastQuit() {
    quitBroadcasts++;
    return true;
  }
}

void main() {
  group('三态开关 → 后端裁决', () {
    test('off 一律 off，与是否装了无关', () {
      for (final bool installed in <bool>[true, false]) {
        expect(
          resolveMagpieBackend(
            mode: MagpieUpscalingMode.off,
            isWindows: true,
            installedAvailable: installed,
          ),
          MagpieBackend.off,
        );
      }
    });

    test('非 Windows 一律 off —— galgame 只做 Windows', () {
      for (final MagpieUpscalingMode mode in MagpieUpscalingMode.values) {
        expect(
          resolveMagpieBackend(
            mode: mode,
            isWindows: false,
            installedAvailable: true,
          ),
          MagpieBackend.off,
          reason: 'mode=$mode 在非 Windows 上必须 off',
        );
      }
    });

    test('installedOnly 没装 → unavailable（绝不联网）', () {
      expect(
        resolveMagpieBackend(
          mode: MagpieUpscalingMode.installedOnly,
          isWindows: true,
          installedAvailable: false,
        ),
        MagpieBackend.unavailable,
      );
    });

    test('installedOnly 装了 → installed', () {
      expect(
        resolveMagpieBackend(
          mode: MagpieUpscalingMode.installedOnly,
          isWindows: true,
          installedAvailable: true,
        ),
        MagpieBackend.installed,
      );
    });

    test('auto 装了 → installed（不为用自家产物重复下载）', () {
      expect(
        resolveMagpieBackend(
          mode: MagpieUpscalingMode.auto,
          isWindows: true,
          installedAvailable: true,
        ),
        MagpieBackend.installed,
      );
    });

    test('auto 没装 → needsDownload', () {
      expect(
        resolveMagpieBackend(
          mode: MagpieUpscalingMode.auto,
          isWindows: true,
          installedAvailable: false,
        ),
        MagpieBackend.needsDownload,
      );
    });
  });

  group('偏好键编解码', () {
    test('往返稳定', () {
      for (final MagpieUpscalingMode mode in MagpieUpscalingMode.values) {
        expect(
          magpieUpscalingModeFromKey(magpieUpscalingModeToKey(mode)),
          mode,
        );
      }
    });

    test('未知 / null 回落到默认（off）', () {
      expect(magpieUpscalingModeFromKey(null), kMagpieDefaultUpscalingMode);
      expect(magpieUpscalingModeFromKey(''), kMagpieDefaultUpscalingMode);
      expect(magpieUpscalingModeFromKey('nonsense'), MagpieUpscalingMode.off);
    });

    test('持久化串是稳定字面量，不是 enum.name / index', () {
      expect(magpieUpscalingModeToKey(MagpieUpscalingMode.installedOnly),
          'installed_only');
      expect(magpieUpscalingModeToKey(MagpieUpscalingMode.auto), 'auto');
      expect(magpieUpscalingModeToKey(MagpieUpscalingMode.off), 'off');
    });
  });

  group('🔴 硬禁令：绝不给 Hibiki 自己建 autoScale profile', () {
    test('目标就是 Hibiki 自己 → 拒绝（大小写不敏感）', () {
      expect(
        magpieProfileTargetAllowed(
          targetExecutablePath: kHibikiExe.toUpperCase(),
          hibikiExecutablePath: kHibikiExe,
        ),
        isFalse,
      );
    });

    test('空目标路径 → 拒绝', () {
      expect(
        magpieProfileTargetAllowed(
          targetExecutablePath: '   ',
          hibikiExecutablePath: kHibikiExe,
        ),
        isFalse,
      );
    });

    test('正常游戏 exe → 放行', () {
      expect(
        magpieProfileTargetAllowed(
          targetExecutablePath: kGame.executablePath,
          hibikiExecutablePath: kHibikiExe,
        ),
        isTrue,
      );
    });

    test('写 profile 时该禁令是硬门，不是建议', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(),
        identity: MagpieWindowIdentity(
          executablePath: kHibikiExe,
          windowClassName: 'FLUTTER_RUNNER_WIN32_WINDOW',
        ),
        profileName: 'Hibiki',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.applied, isFalse);
      expect(result.skipReason, MagpieProfileSkipReason.forbiddenTarget);
    });
  });

  group('profile 增量改写：成功路径', () {
    test('追加一条完整的 autoScale profile', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(defaultScalingMode: 3),
        identity: kGame,
        profileName: 'Hibiki: sakura.exe',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.applied, isTrue);
      final List<Object?> profiles =
          result.config!['profiles']! as List<Object?>;
      expect(profiles.length, 2);
      final Map<Object?, Object?> added = profiles[1]! as Map<Object?, Object?>;

      // `_LoadProfile` 里 name/packaged/pathRule/classNameRule 缺一不可，缺了整条被丢弃。
      expect(added['name'], 'Hibiki: sakura.exe');
      expect(added['packaged'], isFalse);
      expect(added['pathRule'], kGame.executablePath);
      expect(added['classNameRule'], kGame.windowClassName);
      // autoScale 是 uint 枚举不是 bool。
      expect(added['autoScale'], 1);
      expect(added['autoScale'], isA<int>());
      // scalingMode 沿用默认 profile 的选择，且必须 >= 0（-1 会报 InvalidScalingMode）。
      expect(added['scalingMode'], 3);
      // 我们不猜任何私有字段：没有 scalingFlags 这个 key。
      expect(added.containsKey('scalingFlags'), isFalse);
    });

    test('默认 profile 的 scalingMode 越界 / 为 -1 时回落 0', () {
      for (final int bad in <int>[-1, 99]) {
        final MagpieProfileWriteResult result =
            magpieConfigWithAutoScaleProfile(
          config: baseConfig(defaultScalingMode: bad),
          identity: kGame,
          profileName: 'x',
          hibikiExecutablePath: kHibikiExe,
        );
        final List<Object?> profiles =
            result.config!['profiles']! as List<Object?>;
        expect((profiles[1]! as Map<Object?, Object?>)['scalingMode'], 0);
      }
    });

    test('已有同身份 profile → 只翻 autoScale，用户其余设置一律不动', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(extraProfiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': '用户自己建的',
            'packaged': false,
            'pathRule': kGame.executablePath,
            'classNameRule': kGame.windowClassName,
            'autoScale': 0,
            'scalingMode': 5,
            'cursorScaling': 4,
            '3DGameMode': true,
          },
        ]),
        identity: kGame,
        profileName: 'Hibiki: sakura.exe',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.applied, isTrue);
      final Map<Object?, Object?> entry = (result.config!['profiles']!
          as List<Object?>)[1]! as Map<Object?, Object?>;
      expect(entry['autoScale'], 1);
      // 名字没被改成我们的、其余字段原样保留。
      expect(entry['name'], '用户自己建的');
      expect(entry['scalingMode'], 5);
      expect(entry['cursorScaling'], 4);
      expect(entry['3DGameMode'], isTrue);
      // 没有多出一条重复 profile。
      expect((result.config!['profiles']! as List<Object?>).length, 2);
    });

    test('配置其余顶层键原样保留', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(),
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.config!['theme'], 2);
      expect((result.config!['scalingModes']! as List<Object?>).length, 7);
    });
  });

  group('profile 增量改写：best-effort 退化（每条都必须降级而不是抛）', () {
    test('scalingModes 为空 → noScalingModes（写了必踩 -1 钳位陷阱）', () {
      final Map<String, dynamic> config = baseConfig();
      config['scalingModes'] = <Object?>[];
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: config,
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.applied, isFalse);
      expect(result.skipReason, MagpieProfileSkipReason.noScalingModes);
    });

    test('scalingModes 缺失 → noScalingModes', () {
      final Map<String, dynamic> config = baseConfig()..remove('scalingModes');
      expect(
        magpieConfigWithAutoScaleProfile(
          config: config,
          identity: kGame,
          profileName: 'x',
          hibikiExecutablePath: kHibikiExe,
        ).skipReason,
        MagpieProfileSkipReason.noScalingModes,
      );
    });

    test('profiles 缺失 / 为空 / 第 0 项不是对象 → schemaMismatch', () {
      for (final Object? bad in <Object?>[
        null,
        <Object?>[],
        <Object?>['x']
      ]) {
        final Map<String, dynamic> config = baseConfig();
        if (bad == null) {
          config.remove('profiles');
        } else {
          config['profiles'] = bad;
        }
        expect(
          magpieConfigWithAutoScaleProfile(
            config: config,
            identity: kGame,
            profileName: 'x',
            hibikiExecutablePath: kHibikiExe,
          ).skipReason,
          MagpieProfileSkipReason.schemaMismatch,
          reason: 'profiles=$bad',
        );
      }
    });

    test(
        '窗口身份不全 → missingWindowIdentity（空 pathRule/classNameRule 会让'
        ' Magpie 整条丢弃）', () {
      const List<MagpieWindowIdentity> broken = <MagpieWindowIdentity>[
        MagpieWindowIdentity(executablePath: '', windowClassName: 'A'),
        MagpieWindowIdentity(executablePath: r'C:\a.exe', windowClassName: ''),
        MagpieWindowIdentity(executablePath: '  ', windowClassName: '  '),
      ];
      for (final MagpieWindowIdentity id in broken) {
        expect(
          magpieConfigWithAutoScaleProfile(
            config: baseConfig(),
            identity: id,
            profileName: 'x',
            hibikiExecutablePath: kHibikiExe,
          ).skipReason,
          MagpieProfileSkipReason.missingWindowIdentity,
          reason: '$id',
        );
      }
    });

    test('profileName 为空 → missingWindowIdentity（name 空会被整条丢弃）', () {
      expect(
        magpieConfigWithAutoScaleProfile(
          config: baseConfig(),
          identity: kGame,
          profileName: '   ',
          hibikiExecutablePath: kHibikiExe,
        ).skipReason,
        MagpieProfileSkipReason.missingWindowIdentity,
      );
    });

    test('已有等价且已启用的 profile → alreadySatisfied，不重复追加', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(extraProfiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'x',
            'packaged': false,
            'pathRule': kGame.executablePath,
            'classNameRule': kGame.windowClassName,
            'autoScale': 1,
          },
        ]),
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.applied, isFalse);
      expect(result.skipReason, MagpieProfileSkipReason.alreadySatisfied);
    });
  });

  group('🔴 身份匹配必须与 Magpie 逐字节一致', () {
    test('类名不同 → 视作不同 profile（Magpie 先比 classNameRule 再比 pathRule）', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(extraProfiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'other',
            'packaged': false,
            'pathRule': kGame.executablePath,
            'classNameRule': '另一个类名',
            'autoScale': 1,
          },
        ]),
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      );
      // 类名不同 → 不算同一条 → 应该新追加而不是复用。
      expect(result.applied, isTrue);
      expect((result.config!['profiles']! as List<Object?>).length, 3);
    });

    test('路径大小写不同 → 视作不同 profile（Magpie 用裸 wstring==，无 _wcsicmp）', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(extraProfiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'other',
            'packaged': false,
            'pathRule': kGame.executablePath.toUpperCase(),
            'classNameRule': kGame.windowClassName,
            'autoScale': 1,
          },
        ]),
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.applied, isTrue);
      expect((result.config!['profiles']! as List<Object?>).length, 3);
    });

    test('packaged 为 true 的条目永远不匹配（那是 AUMID 不是路径）', () {
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: baseConfig(extraProfiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'uwp',
            'packaged': true,
            'pathRule': kGame.executablePath,
            'classNameRule': kGame.windowClassName,
            'autoScale': 1,
          },
        ]),
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      );
      expect(result.applied, isTrue);
      expect((result.config!['profiles']! as List<Object?>).length, 3);
    });

    test('第 0 项（默认 profile）永远不被当成匹配目标', () {
      // 构造一个「默认 profile 恰好带了同样身份字段」的病态配置。
      final Map<String, dynamic> config = baseConfig();
      (config['profiles']! as List<Object?>)[0] = <String, dynamic>{
        'scalingMode': 0,
        'packaged': false,
        'pathRule': kGame.executablePath,
        'classNameRule': kGame.windowClassName,
        'autoScale': 1,
      };
      final MagpieProfileWriteResult result = magpieConfigWithAutoScaleProfile(
        config: config,
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      );
      // 必须追加新条目，而不是去动默认 profile。
      expect(result.applied, isTrue);
      expect((result.config!['profiles']! as List<Object?>).length, 2);
    });
  });

  group('收尾：把 autoScale 关回去', () {
    test('关掉我们加的那条', () {
      final Map<String, dynamic> withProfile = magpieConfigWithAutoScaleProfile(
        config: baseConfig(),
        identity: kGame,
        profileName: 'x',
        hibikiExecutablePath: kHibikiExe,
      ).config!;
      final MagpieProfileWriteResult off = magpieConfigWithAutoScaleDisabled(
        config: withProfile,
        identity: kGame,
      );
      expect(off.applied, isTrue);
      final Map<Object?, Object?> entry = (off.config!['profiles']!
          as List<Object?>)[1]! as Map<Object?, Object?>;
      expect(entry['autoScale'], 0);
      // profile 本身保留（用户下次还能看见 / 手动改），只是不再自动缩放。
      expect(entry['pathRule'], kGame.executablePath);
    });

    test('配置里没有我们的 profile → alreadySatisfied，不报错', () {
      expect(
        magpieConfigWithAutoScaleDisabled(
          config: baseConfig(),
          identity: kGame,
        ).skipReason,
        MagpieProfileSkipReason.alreadySatisfied,
      );
    });

    test('profiles 结构坏掉 → schemaMismatch，不抛', () {
      final Map<String, dynamic> config = baseConfig()..remove('profiles');
      expect(
        magpieConfigWithAutoScaleDisabled(config: config, identity: kGame)
            .skipReason,
        MagpieProfileSkipReason.schemaMismatch,
      );
    });
  });

  group('生命周期编排（假 Win32 桥 + 假进程）', () {
    late Directory tmp;
    late String configPath;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('magpie_upscaling_test_');
      configPath = p.join(tmp.path, 'config', 'config.json');
    });

    tearDown(() {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    void writeConfig(Map<String, dynamic> config) {
      final File file = File(configPath);
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(jsonEncode(config));
    }

    MagpieUpscalingService build({
      required MagpieUpscalingMode mode,
      FakeBridge? bridge,
      List<String>? launched,
      bool isWindows = true,
    }) =>
        MagpieUpscalingService(
          modeReader: () => mode,
          bridge: bridge ?? FakeBridge(),
          configPathOverride: configPath,
          hibikiExecutablePath: kHibikiExe,
          isWindowsOverride: isWindows,
          processLauncher: (String exe, List<String> args) async {
            launched?.add('$exe ${args.join(' ')}');
            throw const ProcessException('magpie', <String>[], 'fake', 0);
          },
        );

    test('off → disabled，什么都不碰（不读配置、不起进程）', () async {
      final List<String> launched = <String>[];
      final MagpieUpscalingService service = build(
        mode: MagpieUpscalingMode.off,
        launched: launched,
      );
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.disabled);
      expect(launched, isEmpty);
    });

    test('非 Windows → disabled', () async {
      final MagpieUpscalingService service = build(
        mode: MagpieUpscalingMode.auto,
        isWindows: false,
      );
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.disabled);
    });

    test('已有别人的 Magpie 在跑 → hotkeyOnly，绝不动它的配置也不起第二个', () async {
      writeConfig(baseConfig());
      final List<String> launched = <String>[];
      final MagpieUpscalingService service = build(
        mode: MagpieUpscalingMode.installedOnly,
        bridge: FakeBridge(running: true),
        launched: launched,
      );
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.hotkeyOnly);
      expect(launched, isEmpty, reason: '不许起第二个实例');
      // 配置一个字节都不该动。
      expect(
        jsonDecode(File(configPath).readAsStringSync()),
        jsonDecode(jsonEncode(baseConfig())),
      );
    });

    test('installedOnly 且没装 → unavailable，零网络', () async {
      // 安装目录不存在（真实 MagpieInstaller.isInstalled() 在测试环境必为 false）。
      final MagpieUpscalingService service = build(
        mode: MagpieUpscalingMode.installedOnly,
      );
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.unavailable);
    });

    test('auto 但没提供确认回调 → unavailable，绝不静默下载', () async {
      final MagpieUpscalingService service = MagpieUpscalingService(
        modeReader: () => MagpieUpscalingMode.auto,
        bridge: FakeBridge(),
        configPathOverride: configPath,
        hibikiExecutablePath: kHibikiExe,
        isWindowsOverride: true,
        // confirmDownload 故意不传
        processLauncher: (String exe, List<String> args) async =>
            throw StateError('不该走到这'),
      );
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.unavailable);
    });

    test('会话结束是幂等的空操作（从没启动过超分时）', () async {
      final FakeBridge bridge = FakeBridge();
      final MagpieUpscalingService service = build(
        mode: MagpieUpscalingMode.off,
        bridge: bridge,
      );
      await service.onSessionEnded();
      await service.onSessionEnded();
      expect(service.report.status, MagpieUpscalingStatus.idle);
      // 没起过进程就不该广播 QUIT —— 那会误杀用户自己开的 Magpie。
      expect(bridge.quitBroadcasts, 0);
    });

    test('🔴 从没启动过 Magpie 时绝不广播 QUIT（否则会关掉用户自己开的那个）', () async {
      writeConfig(baseConfig());
      final FakeBridge bridge = FakeBridge(running: true);
      final MagpieUpscalingService service = build(
        mode: MagpieUpscalingMode.installedOnly,
        bridge: bridge,
      );
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.hotkeyOnly);
      await service.onSessionEnded();
      expect(bridge.quitBroadcasts, 0);
    });
  });

  group('源码守卫：钉住三个读源码挖出来的硬约束', () {
    late String pureSource;
    late String serviceSource;
    late String sessionSource;

    setUpAll(() {
      String read(String relative) {
        final File file = File(p.join(Directory.current.path, relative));
        expect(file.existsSync(), isTrue, reason: '找不到 ${file.path}');
        return file.readAsStringSync();
      }

      pureSource = read('lib/src/mining/magpie_upscaling.dart');
      serviceSource = read('lib/src/mining/magpie_upscaling_service.dart');
      sessionSource = read('lib/src/mining/gal_hook_session_controller.dart');
    });

    test('陷阱 2：便携标记必须是 0 字节，不能是 {}', () {
      final File installer = File(
        p.join(Directory.current.path, 'lib/src/mining/magpie_installer.dart'),
      );
      final String source = installer.readAsStringSync();
      // 函数体必须原样返回空串。写 '{}' 会让 scalingModes 为空 → scalingMode 钳到 -1
      // → 缩放报 InvalidScalingMode。
      expect(
        source.contains("String magpiePortableConfigContent() => '';"),
        isTrue,
        reason: 'magpiePortableConfigContent 必须返回空字符串（0 字节文件）',
      );
    });

    test('陷阱 1：autoScale 常量是 uint 枚举值 1，不是 bool', () {
      expect(
        pureSource.contains('const int kMagpieAutoScaleFullscreen = 1;'),
        isTrue,
      );
      expect(
        pureSource.contains('const int kMagpieAutoScaleDisabled = 0;'),
        isTrue,
      );
    });

    test('陷阱 3 相关：只用全屏，绝不用窗口化（窗口模式会抢焦点）', () {
      // 代码里不该出现 Windowed(2) 这个自动缩放取值。
      expect(pureSource.contains('kMagpieAutoScaleWindowed'), isFalse);
      expect(serviceSource.contains('AutoScaleWindowed'), isFalse);
    });

    test('配置必须在拉起 Magpie 之前写（Magpie 只在启动时读一次，无文件监视）', () {
      final int applyIndex =
          serviceSource.indexOf('_applyAutoScaleProfile(hwnd)');
      final int launchIndex = serviceSource.indexOf('_processLauncher(exe');
      expect(applyIndex, greaterThan(0));
      expect(launchIndex, greaterThan(0));
      expect(
        applyIndex,
        lessThan(launchIndex),
        reason: '写配置必须在 launch 之前，否则 Magpie 读不到我们的 profile',
      );
    });

    test('QUIT 之后必须有 kill 兜底（Magpie 没给 QUIT 放行 UIPI）', () {
      expect(serviceSource.contains('broadcastQuit()'), isTrue);
      expect(serviceSource.contains('process.kill('), isTrue);
    });

    test('只 kill 我们自己起的进程，绝不按进程名扫', () {
      for (final String forbidden in <String>[
        'taskkill',
        'Magpie.exe"',
        'killAll',
      ]) {
        expect(
          serviceSource.contains(forbidden),
          isFalse,
          reason: '不许出现按名杀进程的痕迹：$forbidden',
        );
      }
    });

    test('会话挂钩是 fire-and-forget，绝不阻塞 _setState', () {
      expect(
        sessionSource.contains('unawaited(_notifyMagpieWindowReady('),
        isTrue,
        reason: '窗口就绪挂钩必须 unawaited，否则会拖慢每一次状态更新',
      );
    });

    test('会话收尾挂钩排在 _stopSources 之前（此时 boundWindow 还在）', () {
      final int notifyIndex =
          sessionSource.indexOf('await _notifyMagpieSessionEnded();');
      expect(notifyIndex, greaterThan(0));
      final int stopIndex =
          sessionSource.indexOf('await _stopSources();', notifyIndex);
      expect(stopIndex, greaterThan(notifyIndex));
    });

    test('BUG-1076 契约：确认回调之前不 await 体积探测', () {
      final File installer = File(
        p.join(Directory.current.path, 'lib/src/mining/magpie_installer.dart'),
      );
      final String source = installer.readAsStringSync();
      expect(source.contains('await _probeSize('), isFalse,
          reason: '体积探测绝不能在确认框之前被 await');
    });
  });
}
