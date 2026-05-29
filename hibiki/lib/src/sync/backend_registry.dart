import 'package:hibiki/src/sync/sync_backend.dart';

typedef SyncBackendFactory = SyncBackend Function();

class SyncBackendRegistry {
  final Map<SyncBackendType, SyncBackendFactory> _factories = {};

  void register(SyncBackendType type, SyncBackendFactory factory) {
    _factories[type] = factory;
  }

  SyncBackend resolve(SyncBackendType type) {
    final factory = _factories[type];
    if (factory == null) {
      throw StateError('No backend registered for $type');
    }
    return factory();
  }

  bool hasBackend(SyncBackendType type) => _factories.containsKey(type);

  Iterable<SyncBackendType> get registeredTypes => _factories.keys;
}
