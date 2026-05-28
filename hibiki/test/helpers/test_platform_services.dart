import 'package:hibiki/src/platform/platform_services.dart';
import 'fake_platform_services.dart';

/// Returns a [PlatformServices] suitable for unit tests.
///
/// All services are recording fakes with inert defaults (no I/O, no platform
/// channels). For tests that need to assert platform interactions, build the
/// fakes directly via [fakePlatformServices] and inspect them afterwards.
PlatformServices testPlatformServices() => fakePlatformServices();
