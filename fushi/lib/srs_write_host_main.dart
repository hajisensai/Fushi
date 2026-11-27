import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi/src/diagnostics/fushi_binding.dart'
    show FushiSecondaryWidgetsFlutterBinding;
import 'package:fushi/src/engine_bindings.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/srs/srs_providers.dart' show srsProfileStoresProvider;
import 'package:fushi/src/srs/srs_write_relay.dart';
import 'package:fushi/src/srs/srs_write_relay_channel.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// Android 主进程里的无界面复习写入执行引擎（BUG-5542，拍板 D10「弹窗里的制卡转交主进程」）。
///
/// 辅助进程（`:popup` 查词窗 / `:second_screen` 面板）只读打开复习库，写入经 `SrsWriteRelayService` 转交主进程。
/// 主界面的引擎在时由它执行（main.dart）；主界面不在（进程刚被这次绑定拉起、或主界面已被系统 / 用户关掉）时，原生
/// `SrsWriteRelay` 起本引擎：按 Primary 打开复习库、执行请求，空闲一阵或主界面的引擎要开主库（`claimPrimary`）时
/// 收到 `release`——做完手上的请求、关库，由原生销毁。同一进程里同一时刻只有一个 Primary。
@pragma('vm:entry-point')
void srsWriteHostMain() {
  runZonedGuarded<Future<void>>(
    () async {
      FushiSecondaryWidgetsFlutterBinding.ensureInitialized();
      // 本引擎不跑 main()：引擎数据根 / 日志等装配点自己装（同 popupMain，BUG-4940）。
      installEntryPointHostBindings();
      final ProviderContainer container = ProviderContainer(
        overrides: [
          platformServicesProvider.overrideWithValue(
            PlatformServices.forCurrentPlatform(),
          ),
        ],
      );
      final AppModel app = container.read(appProvider);
      app.srsProfileStoresReader = () =>
          container.read(srsProfileStoresProvider);
      final Future<void> initialised = app.initialiseForSrsWriteHost();
      final SrsWriteRelayHost host = SrsWriteRelayHost(
        resolveMiner: app.srsRelayMiner,
      );
      bool released = false;
      await SrsWriteRelayHostChannel.install(
        execute: (Map<String, Object?> request) async {
          if (released) {
            return <String, Object?>{
              SrsWriteRelayWire.error: 'srs write host released',
            };
          }
          await initialised;
          return host.handle(request);
        },
        release: () async {
          released = true;
          await initialised;
          await host.drain();
          try {
            await container.read(srsProfileStoresProvider).releaseAll();
          } catch (e, stack) {
            ErrorLogService.instance.log('srsWriteHost.releaseAll', e, stack);
          }
          await app.closeForSrsWriteHost();
          container.dispose();
        },
      );
    },
    (Object e, StackTrace stack) {
      ErrorLogService.instance.log('srsWriteHostMain', e, stack);
    },
  );
}
