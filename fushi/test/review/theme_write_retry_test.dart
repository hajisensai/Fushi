import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

class _ThemeWriteFault extends QueryInterceptor {
  bool armed = false;
  int failures = 0;

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed &&
        statement.toLowerCase().contains('preferences') &&
        args.contains('app_theme_key')) {
      failures++;
      throw StateError('round8 injected theme transaction failure');
    }
    return executor.runInsert(statement, args);
  }
}

class _HeldThemeWrite extends QueryInterceptor {
  final Completer<void> entered = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool armed = false;
  bool failSecond = false;
  int themeWrites = 0;

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (armed &&
        statement.toLowerCase().contains('preferences') &&
        args.contains('app_theme_key')) {
      themeWrites++;
      if (themeWrites == 1) {
        entered.complete();
        await release.future;
      } else if (failSecond) {
        throw StateError('injected second theme transaction failure');
      }
    }
    return executor.runInsert(statement, args);
  }
}

Future<void> _settlePendingWrites(List<Future<void>> writes) async {
  // A failed assertion must still drain the released transaction before closing
  // Drift. The main test awaits/asserts errors; cleanup must not mask that error.
  await Future.wait(
    writes.map(
      (Future<void> write) =>
          write.then<void>((_) {}, onError: (Object _, StackTrace __) {}),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final bool failFirst in <bool>[false, true]) {
    test(
      failFirst
          ? 'retry after failed legacy theme save retains dark and black on disk reopen'
          : 'control: legacy dark and black survive a successful save and disk reopen',
      () async {
        final Directory scratch = Directory.systemTemp.createTempSync(
          'fushi-round8-theme-db-',
        );
        final File file = File(p.join(scratch.path, 'fixture.sqlite'));
        final _ThemeWriteFault fault = _ThemeWriteFault();
        final FushiDatabase first = FushiDatabase.forTesting(
          NativeDatabase(file).interceptWith(fault),
        );
        final ThemeNotifier theme = ThemeNotifier(
          first,
          () => const TextTheme(),
        );
        try {
          await first.setPrefTyped<String>('app_theme_key', 'black-theme');
          await theme.refreshFromDb();
          expect(theme.appThemeKey, 'm3-indigo');
          expect(theme.storedAppThemeKey, 'black-theme');
          expect(theme.brightnessMode, 'dark');
          expect(theme.pureBlackDark, isTrue);
          if (failFirst) {
            fault.armed = true;
            await expectLater(
              theme.setAppThemeKey('m3-teal'),
              throwsStateError,
            );
            expect(fault.failures, 1);
            // The real DB transaction rolled back all three preference rows.
            expect(
              await first.getPrefTyped<String>('app_theme_key', ''),
              'black-theme',
            );
            expect(await first.getPref('brightness_mode'), isNull);
            expect(await first.getPref('pure_black_dark'), isNull);
            expect(theme.appThemeKey, 'm3-indigo');
            expect(theme.storedAppThemeKey, 'black-theme');
            expect(theme.brightnessMode, 'dark');
            expect(theme.pureBlackDark, isTrue);
            fault.armed = false;
          }
          await theme.setAppThemeKey('m3-blue');
          debugPrint(
            'round8 theme failFirst=$failFirst inMemory='
            '${theme.appThemeKey}/${theme.brightnessMode}/${theme.pureBlackDark}',
          );
        } finally {
          theme.dispose();
          await first.close();
        }

        final FushiDatabase second = FushiDatabase.forTesting(
          NativeDatabase(file),
        );
        final ThemeNotifier reopened = ThemeNotifier(
          second,
          () => const TextTheme(),
        );
        late String key;
        late String brightness;
        late bool black;
        try {
          await reopened.refreshFromDb();
          key = reopened.appThemeKey;
          brightness = reopened.brightnessMode;
          black = reopened.pureBlackDark;
          debugPrint(
            'round8 theme failFirst=$failFirst reopened=$key/$brightness/$black',
          );
        } finally {
          reopened.dispose();
          await second.close();
          scratch.deleteSync(recursive: true);
        }
        expect(key, 'm3-blue');
        expect(brightness, 'dark');
        expect(black, isTrue);
      },
    );
  }

  for (final bool failSecond in <bool>[false, true]) {
    test(
      failSecond
          ? 'later failed theme preserves the earlier committed theme'
          : 'concurrent theme choices publish the latest committed key',
      () async {
        final _HeldThemeWrite held = _HeldThemeWrite()..failSecond = failSecond;
        final FushiDatabase db = FushiDatabase.forTesting(
          NativeDatabase.memory().interceptWith(held),
        );
        final ThemeNotifier theme = ThemeNotifier(db, () => const TextTheme());
        final List<Future<void>> pending = <Future<void>>[];
        try {
          await db.setPrefTyped<String>('app_theme_key', 'black-theme');
          await theme.refreshFromDb();
          expect(theme.appThemeKey, 'm3-indigo');
          held.armed = true;
          final Future<void> first = theme.setAppThemeKey('m3-teal');
          pending.add(first);
          await held.entered.future;
          final Future<void> second = theme.setAppThemeKey('m3-blue');
          final Future<void> secondResult = failSecond
              ? expectLater(second, throwsStateError)
              : second;
          pending.add(secondResult);
          expect(
            theme.appThemeKey,
            'm3-indigo',
            reason: 'an uncommitted theme must not be published',
          );
          expect(theme.storedAppThemeKey, 'black-theme');
          held.release.complete();
          await Future.wait(<Future<void>>[first, secondResult]);
          final String expected = failSecond ? 'm3-teal' : 'm3-blue';
          expect(held.themeWrites, 2);
          expect(theme.appThemeKey, expected);
          expect(await db.getPrefTyped<String>('app_theme_key', ''), expected);
          expect(theme.brightnessMode, 'dark');
          expect(theme.pureBlackDark, isTrue);
          debugPrint('theme concurrency secondFails=$failSecond key=$expected');
        } finally {
          if (!held.release.isCompleted) held.release.complete();
          await _settlePendingWrites(pending);
          theme.dispose();
          await db.close();
        }
      },
    );
  }

  test(
    'pending legacy theme cannot overwrite newer brightness and black choices',
    () async {
      final _HeldThemeWrite held = _HeldThemeWrite();
      final FushiDatabase db = FushiDatabase.forTesting(
        NativeDatabase.memory().interceptWith(held),
      );
      final ThemeNotifier theme = ThemeNotifier(db, () => const TextTheme());
      final List<Future<void>> pending = <Future<void>>[];
      try {
        await db.setPrefTyped<String>('app_theme_key', 'black-theme');
        await theme.refreshFromDb();
        held.armed = true;
        final Future<void> selecting = theme.setAppThemeKey('m3-teal');
        pending.add(selecting);
        await held.entered.future;
        final Future<void> brightness = theme.setBrightnessMode('light');
        final Future<void> black = theme.setPureBlackDark(false);
        pending.addAll(<Future<void>>[brightness, black]);
        expect(theme.brightnessMode, 'light');
        expect(theme.pureBlackDark, isFalse);
        held.release.complete();
        await Future.wait(<Future<void>>[selecting, brightness, black]);
        expect(theme.appThemeKey, 'm3-teal');
        expect(theme.brightnessMode, 'light');
        expect(theme.pureBlackDark, isFalse);
        expect(await db.getPrefTyped<String>('app_theme_key', ''), 'm3-teal');
        expect(await db.getPrefTyped<String>('brightness_mode', ''), 'light');
        expect(await db.getPrefTyped<bool>('pure_black_dark', true), isFalse);
        debugPrint(
          'theme concurrency latest light/false matches persisted values',
        );
      } finally {
        if (!held.release.isCompleted) held.release.complete();
        await _settlePendingWrites(pending);
        theme.dispose();
        await db.close();
      }
    },
  );
}
