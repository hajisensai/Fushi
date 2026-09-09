import 'package:fushi/src/platform/platform_services.dart';
import 'fake_platform_services.dart';

/// Returns a [PlatformServices] suitable for unit tests.
///
/// All services are recording fakes with inert defaults (no I/O, no platform
/// channels). For tests that need to assert platform interactions, build the
/// fakes directly via [fakePlatformServices] and inspect them afterwards.
/// [isWindows] / [isDesktop] 传非空值即可声明「这条用例讲的是那个平台」，用于
/// 平台独有模块（galgame 只做 Windows 端）的用例——不传就跟随真实平台。
PlatformServices testPlatformServices({bool? isWindows, bool? isDesktop}) =>
    fakePlatformServices(isWindows: isWindows, isDesktop: isDesktop);
