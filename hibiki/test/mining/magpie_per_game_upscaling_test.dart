// BUG-1191：窗口超分从「一刀切的全局设置项」改成「每个游戏各自一档 + 游戏卡右键菜单」。
//
// 这组测试钉住那个改动的行为契约：
// 1. 每一条「读不到档位」的路径都必须落到**关闭** —— 老用户升级上来一个游戏都不该
//    被莫名其妙打开超分（这是本轮最硬的一条）；
// 2. 档位是**每局重新读**的，不是构造服务时读一次 —— 否则换个游戏还是上一局的档；
// 3. 选择对话框把用户选的档原样交回调用方，取消返回 null（不写任何东西）。
//
// 与 `magpie_upscaling_test.dart` 分开：那边测的是「档位定了之后怎么干活」，
// 这边测的是「档位怎么来的」。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/magpie_upscaling.dart';
import 'package:hibiki/src/mining/magpie_upscaling_prompt.dart';
import 'package:hibiki/src/mining/magpie_upscaling_service.dart';
import 'package:hibiki/utils.dart';

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  group('磁盘值 → 档位', () {
    test('没设过（null / 空串）读作关闭', () {
      expect(magpieUpscalingModeFromKey(null), MagpieUpscalingMode.off);
      expect(magpieUpscalingModeFromKey(''), MagpieUpscalingMode.off);
    });

    test('两个「会干活」的值原样反解', () {
      expect(magpieUpscalingModeFromKey('auto'), MagpieUpscalingMode.auto);
      expect(
        magpieUpscalingModeFromKey('installed_only'),
        MagpieUpscalingMode.installedOnly,
      );
    });

    test('认不出的值（旧版本写坏 / 手改 DB）落到关闭，不是 auto', () {
      expect(magpieUpscalingModeFromKey('garbage'), MagpieUpscalingMode.off);
      expect(magpieUpscalingModeFromKey('AUTO'), MagpieUpscalingMode.off);
    });

    test('三档往返稳定（存的是字符串不是 index）', () {
      for (final MagpieUpscalingMode mode in MagpieUpscalingMode.values) {
        expect(
          magpieUpscalingModeFromKey(magpieUpscalingModeToKey(mode)),
          mode,
        );
      }
    });
  });

  group('本局档位裁决（纯函数）', () {
    test('库里那一行说 auto → auto', () {
      expect(
        resolveSessionUpscalingMode(
          launchExe: r'D:\Games\Foo\foo.exe',
          storedModeKey: 'auto',
        ),
        MagpieUpscalingMode.auto,
      );
    });

    test('游戏不在库里（storedModeKey = null）→ 关闭', () {
      expect(
        resolveSessionUpscalingMode(
          launchExe: r'D:\Games\Foo\foo.exe',
          storedModeKey: null,
        ),
        MagpieUpscalingMode.off,
      );
    });

    test('窗口附着捕获（没有启动 exe）→ 关闭，哪怕手里有个 auto 串', () {
      // 附着路径没有稳定游戏身份，不猜。这条是「不猜身份」的守门员：
      // 若实现改成「exe 为空就随便用手上的串」，本条立刻转红。
      expect(
        resolveSessionUpscalingMode(launchExe: null, storedModeKey: 'auto'),
        MagpieUpscalingMode.off,
      );
      expect(
        resolveSessionUpscalingMode(launchExe: '', storedModeKey: 'auto'),
        MagpieUpscalingMode.off,
      );
    });
  });

  group('服务按每局读档', () {
    /// 走 **Windows 分支**（`isWindowsOverride: true`）：非 Windows 下任何档位都被平台
    /// 判据压成 `disabled`，那样「读到 off」和「读到 auto」就分不开，断言等于没断言。
    /// Windows 分支里 off → disabled、auto → failed + bundleMissing（测试宿主没有随包
    /// 归档，且绝不联网补取 —— BUG-1246 之后缺随包是**交付错误**而不是「暂时不可用」），
    /// 两者可分。
    MagpieUpscalingService build(MagpieUpscalingMode Function() modeReader) =>
        MagpieUpscalingService(
          modeReader: modeReader,
          bridge: _NotRunningBridge(),
          isWindowsOverride: true,
          configPathOverride: '${Directory.systemTemp.path}'
              '${Platform.pathSeparator}hibiki_magpie_absent_config.json',
          processLauncher: (String exe, List<String> args) async {
            throw StateError('档位没生效才会走到这');
          },
        );

    test('读到 auto → failed/bundleMissing（证明这套替身分得清 auto 和 off）', () async {
      final MagpieUpscalingService service =
          build(() => MagpieUpscalingMode.auto);
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.failed);
      expect(service.report.failureReason,
          MagpieUpscalingFailureReason.bundleMissing);
    });

    test('读到 off → disabled，一次都不碰安装器/进程', () async {
      final MagpieUpscalingService service =
          build(() => MagpieUpscalingMode.off);
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.disabled);
    });

    test('每次 ready 都重新读档，不是构造时读一次', () async {
      // 换个游戏 = 同一个 app 级服务读到另一档。若实现把档位缓存进字段，
      // 第二次不会再调 modeReader，本条转红。
      int reads = 0;
      final MagpieUpscalingService service = build(() {
        reads++;
        return MagpieUpscalingMode.off;
      });
      await service.onGameWindowReady(hwnd: 1);
      await service.onSessionEnded();
      await service.onGameWindowReady(hwnd: 2);
      expect(reads, 2);
    });

    test('读档抛异常（DB 未就绪 / 库里没这行）→ 关闭，绝不兜底成 auto', () async {
      // 这是本轮最硬的一条：兜底成 auto 等于替用户默默打开一个吃 GPU 的东西。
      // 兜底若改成 auto，状态会变成 unavailable（走了下载分支），本条立刻转红。
      final MagpieUpscalingService service =
          build(() => throw StateError('database not ready'));
      await service.onGameWindowReady(hwnd: 1234);
      expect(service.report.status, MagpieUpscalingStatus.disabled);
    });
  });

  group('每游戏选择对话框', () {
    Future<MagpieUpscalingMode?> pump(
      WidgetTester tester, {
      required MagpieUpscalingMode current,
      String? tapLabel,
    }) async {
      MagpieUpscalingMode? result;
      bool returned = false;
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  result = await pickMagpieUpscalingMode(
                    context,
                    current: current,
                    gameName: 'テストゲーム',
                  );
                  returned = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(MagpieUpscalingModeDialog), findsOneWidget);
      if (tapLabel == null) {
        // 点遮罩取消。
        Navigator.of(tester.element(find.byType(MagpieUpscalingModeDialog)))
            .pop();
      } else {
        await tester.tap(find.text(tapLabel));
      }
      await tester.pumpAndSettle();
      expect(returned, isTrue, reason: '对话框关闭后调用方必须拿到结果');
      return result;
    }

    testWidgets('选「自动」→ 原样交回 auto', (WidgetTester tester) async {
      final MagpieUpscalingMode? picked = await pump(
        tester,
        current: MagpieUpscalingMode.off,
        tapLabel: t.game_upscaling_auto,
      );
      expect(picked, MagpieUpscalingMode.auto);
    });

    testWidgets('选「仅用已装」→ 原样交回 installedOnly', (WidgetTester tester) async {
      final MagpieUpscalingMode? picked = await pump(
        tester,
        current: MagpieUpscalingMode.auto,
        tapLabel: t.game_upscaling_installed_only,
      );
      expect(picked, MagpieUpscalingMode.installedOnly);
    });

    testWidgets('取消 → null（调用方据此一个字节都不写）', (WidgetTester tester) async {
      final MagpieUpscalingMode? picked =
          await pump(tester, current: MagpieUpscalingMode.auto);
      expect(picked, isNull);
    });

    testWidgets('当前档在单选里被选中', (WidgetTester tester) async {
      await tester.pumpWidget(
        TranslationProvider(
          child: const MaterialApp(
            home: MagpieUpscalingModeDialog(
              current: MagpieUpscalingMode.installedOnly,
              gameName: 'テストゲーム',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(t.game_upscaling_pick_title(name: 'テストゲーム')),
          findsOneWidget);
      final RadioListTile<MagpieUpscalingMode> selected =
          tester.widget<RadioListTile<MagpieUpscalingMode>>(
        find.byKey(const ValueKey<String>(
          'magpie-upscaling-mode-installed_only',
        )),
      );
      expect(selected.groupValue, MagpieUpscalingMode.installedOnly);
      expect(selected.value, MagpieUpscalingMode.installedOnly);
    });
  });

  group('源码守卫', () {
    test('超分不得再出现在设置 schema 里', () async {
      // 全局设置项是本 bug 的病灶：超分该不该开完全取决于**这个游戏**的原生分辨率，
      // 一个全局开关只能两边都不对。有人加回来时这条会红。
      final String schema = await File(
        'lib/src/settings/settings_schema_lookup.dart',
      ).readAsString();
      expect(
        schema.contains('lookup.galgame_upscaling'),
        isFalse,
        reason: '窗口超分改为每游戏一档 + 游戏卡右键菜单，不再有全局设置项',
      );
    });

    test('不得再有全局超分偏好读写或 UI/AppModel 入口', () async {
      const String obsoleteKey = 'galgame_magpie_upscaling_mode';
      final String prefs = await File(
        'lib/src/models/preferences_repository.dart',
      ).readAsString();
      expect(
        prefs.contains("getPref('$obsoleteKey'"),
        isFalse,
        reason: '档位已落 galgames.upscaling_mode，全局偏好必须没有读取点',
      );
      expect(
        prefs.contains("setPref('$obsoleteKey'"),
        isFalse,
        reason: '旧全局偏好也不得留下写入点',
      );

      final String appModel =
          await File('lib/src/models/app_model.dart').readAsString();
      expect(appModel.contains(obsoleteKey), isFalse,
          reason: 'AppModel 不得重新暴露旧全局超分状态');

      final Iterable<File> settingsFiles = Directory('lib/src/settings')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File file) => file.path.endsWith('.dart'));
      for (final File file in settingsFiles) {
        expect(
          (await file.readAsString()).contains(obsoleteKey),
          isFalse,
          reason: 'settings schema 不得重新出现旧全局超分 key：${file.path}',
        );
      }
    });

    test('helper 随包归档必须由 CMake install 拷进 bundle（开发构建也要有）', () async {
      // BUG-1196：helper 的网络下载与后台自更新已删除，随包 zip 是**唯一**来源。
      // 在此之前 galgame_helper/ 只由 CI 的独立 YAML 步骤拷贝，于是 `flutter run`
      // 出来的 exe 旁边永远没有它，galgame hook 在开发模式下完全用不了。
      final String cmake = await File('windows/CMakeLists.txt').readAsString();
      expect(
        cmake.contains(r'native/galgame_hook/dist'),
        isTrue,
        reason: 'CMake 必须从 build_distribution.ps1 的产出目录取 helper zip',
      );
      expect(
        cmake.contains(r'/galgame_helper'),
        isTrue,
        reason: '目标目录必须与运行期 _bundledDirectory() 的约定一致',
      );
    });
  });
}

/// 最小 Win32 替身：机器上没有 Magpie 在跑，身份查不到。
/// 真实桥在非 Windows 上会去 `DynamicLibrary.open('user32.dll')`，测试里不碰它。
class _NotRunningBridge implements MagpieWin32Bridge {
  @override
  MagpieWindowIdentity? identityForWindow(int hwnd) => null;

  @override
  bool isMagpieRunning() => false;

  @override
  bool broadcastQuit() => false;
}
