import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/second_screen/companion/companion_provider_read.dart';

/// The companion services read `provider.future` from a long-lived [Ref].
/// When the provider is invalidated while it is still loading (here: the
/// stream it watches emits its first value, like `srtBooksProvider` watching
/// `_srtBookUidsProvider`), the read must still complete. A bare
/// `ref.read(provider.future)` hung in this case on a device (Library tab
/// Home stuck on its loading state).
void main() {
  test('completes when the provider is invalidated while loading', () async {
    final StreamController<int> uids = StreamController<int>();
    addTearDown(uids.close);
    final Completer<void> gate = Completer<void>();
    int builds = 0;

    final StreamProvider<int> uidsProvider = StreamProvider<int>(
      (Ref ref) => uids.stream,
    );
    final FutureProvider<int> booksProvider = FutureProvider<int>((
      Ref ref,
    ) async {
      builds++;
      ref.watch(uidsProvider);
      await gate.future;
      return 42;
    });
    final Provider<Ref> refProvider = Provider<Ref>((Ref ref) => ref);

    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);
    final Ref ref = container.read(refProvider);

    final Future<int> read = readCompanionProviderFuture(
      ref,
      booksProvider.future,
    );
    await pumpEventQueue();
    expect(builds, 1);

    // The watched stream emits while the first build is still loading.
    uids.add(1);
    await pumpEventQueue();
    gate.complete();

    expect(await read.timeout(const Duration(seconds: 5)), 42);
    expect(builds, greaterThanOrEqualTo(2));
  });

  test('passes errors through and releases the provider', () async {
    final FutureProvider<int> failing = FutureProvider<int>(
      (Ref ref) async => throw StateError('boom'),
    );
    final Provider<Ref> refProvider = Provider<Ref>((Ref ref) => ref);
    final ProviderContainer container = ProviderContainer();
    addTearDown(container.dispose);

    await expectLater(
      readCompanionProviderFuture(container.read(refProvider), failing.future),
      throwsA(isA<StateError>()),
    );
  });
}
