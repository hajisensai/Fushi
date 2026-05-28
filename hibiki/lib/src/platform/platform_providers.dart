import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:hibiki/src/platform/platform_services.dart';

/// Global provider for the [PlatformServices] bundle.
///
/// Must be overridden in the root [ProviderScope] (see `main.dart`).
/// Widget-layer code can read platform services via
/// `ref.read(platformServicesProvider)`.
final platformServicesProvider = Provider<PlatformServices>(
  (ref) => throw UnimplementedError(
    'platformServicesProvider must be overridden in ProviderScope',
  ),
);
