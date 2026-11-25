import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Awaits [future] (a `provider.future`) while holding a subscription to it.
///
/// The companion services answer one-shot panel requests from a long-lived
/// provider [Ref]. A bare `ref.read(provider.future)` does not listen: when
/// the provider is invalidated while it is still loading (a watched stream
/// emits its first value, the AppModel notifies), Riverpod cancels the
/// in-flight build and, with no listener, never rebuilds it, so the future
/// read earlier never completes (seen on a device: the Library tab's Home
/// stayed on its loading state). Listening keeps the provider alive and
/// rebuilt, which completes the same future.
Future<T> readCompanionProviderFuture<T>(
  Ref ref,
  AlwaysAliveProviderListenable<Future<T>> future,
) async {
  final ProviderSubscription<Future<T>> subscription = ref.listen<Future<T>>(
    future,
    (Future<T>? previous, Future<T> next) {},
  );
  try {
    return await subscription.read();
  } finally {
    subscription.close();
  }
}
