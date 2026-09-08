import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/startup/android_view_lifecycle.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi_core/fushi_core.dart';

void main() {
  late FushiDatabase db;
  late AndroidViewLifecycle lifecycle;
  final ExitFlushRegistry registry = ExitFlushRegistry.instance;

  setUp(() async {
    registry.clear();
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.setPref('position', '0');
    lifecycle = AndroidViewLifecycle(registry: registry);
  });

  tearDown(() async {
    registry.clear();
    await db.close();
  });

  test(
    'BUG-2280 detach and reattach retain DB and later page flushes',
    () async {
      int position = 12;
      registry.register(() => db.setPref('position', position.toString()));

      await lifecycle.handleState(AppLifecycleState.detached);
      expect(await db.getPref('position'), '12');
      await lifecycle.handleState(AppLifecycleState.resumed);
      await db.setPref('service-write', 'still-running');
      expect(await db.getPref('service-write'), 'still-running');

      position = 24;
      await lifecycle.handleState(AppLifecycleState.detached);
      expect(await db.getPref('position'), '24');
      expect(registry.callbackCount, 1);
    },
  );

  test(
    'reattach during pending flush never schedules a later DB shutdown',
    () async {
      final Completer<void> release = Completer<void>();
      int calls = 0;
      int active = 0;
      int maxActive = 0;
      registry.register(() async {
        calls++;
        active++;
        if (active > maxActive) maxActive = active;
        await release.future;
        await db.setPref('position', calls.toString());
        active--;
      });

      final Future<void> paused = lifecycle.handleState(
        AppLifecycleState.paused,
      );
      await lifecycle.handleState(AppLifecycleState.resumed);
      await db.setPref('foreground-write', 'during-flush');
      registry.defer(() => db.setPref('newly-disposed-page', 'saved'));
      final Future<void> detached = lifecycle.handleState(
        AppLifecycleState.detached,
      );
      expect(identical(paused, detached), isTrue);
      release.complete();
      await detached;
      expect(calls, 2);
      expect(maxActive, 1, reason: 'queued flushes must run serially');
      expect(await db.getPref('newly-disposed-page'), 'saved');
      expect(registry.deferredCount, 0);
      expect(await db.getPref('foreground-write'), 'during-flush');

      await db.setPref('foreground-write', 'after-flush');
      await lifecycle.handleState(AppLifecycleState.detached);
      expect(await db.getPref('position'), '3');
      expect(await db.getPref('foreground-write'), 'after-flush');
    },
  );

  test(
    'background states persist pages and consume disposed-page writes once',
    () async {
      int writes = 0;
      int deferred = 0;
      registry.register(() async {
        await db.setPref('position', (++writes).toString());
      });
      registry.defer(() async {
        deferred++;
        await db.setPref('disposed-page', '42');
      });
      for (final AppLifecycleState state in <AppLifecycleState>[
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        await lifecycle.handleState(state);
      }
      expect(await db.getPref('position'), '4');
      expect(await db.getPref('disposed-page'), '42');
      expect(deferred, 1);
      await lifecycle.handleState(AppLifecycleState.resumed);
      expect(writes, 4);
    },
  );
}
