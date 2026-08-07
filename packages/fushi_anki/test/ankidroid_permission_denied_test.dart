import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

// BUG-824：AnkiDroid 权限（READ_WRITE_DATABASE）未授予时制卡失败没有明显提醒。
//
// 根因：native `AnkiChannelHandler.addNote` 是唯一漏了 `requirePermission` 守卫的
// provider 访问分支。权限缺失时它不校验直接跑，AddContentApi 内部查 `/decks` 抛出
// 原始 SecurityException（"Permission not granted for: CardContentProvider.query
// /decks"），冒泡成 PlatformException 后被拼进一闪而过、技术味十足的 toast，用户既
// 看不懂也没被引导去授权。
//
// 修复两层：
//  ① native：给 addNote / addFileToMedia 补 `requirePermission` 守卫——权限缺失时
//     干净返回 `PERMISSION_DENIED` 码并弹出系统授权对话框（源码扫描守卫在下方）。
//  ② Dart：mineEntry / updateMinedNote 把 `PERMISSION_DENIED` 码（或极少数漏守卫时
//     provider 直接抛出的英文 "permission not granted" 原文）分类成
//     `AnkiErrorCode.permissionDenied`，供主 app 映射本地化、可操作的提醒文案。

const MethodChannel _channel = MethodChannel('app.fushi.reader/anki');

class _ConfiguredAnkiRepository extends AnkiRepository {
  _ConfiguredAnkiRepository(this.settings);

  final AnkiSettings settings;

  @override
  Future<AnkiSettings> loadSettings() async => settings;
}

AnkiSettings _settings() => const AnkiSettings(
      selectedDeckId: 1,
      selectedNoteTypeId: 2,
      availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
      availableNoteTypes: <AnkiNoteType>[
        AnkiNoteType(
          id: 2,
          name: 'Hibiki',
          fields: <String>['Expression', 'Reading'],
        ),
      ],
      fieldMappings: <String, String>{
        'Expression': '{expression}',
        'Reading': '{reading}',
      },
      allowDupes: true,
    );

const String _payload = '{"expression":"勉強","reading":"べんきょう"}';

void _mockChannel(Future<Object?> Function(MethodCall call) responder) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, responder);
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BUG-824: mineEntry classifies AnkiDroid permission failures', () {
    test('PERMISSION_DENIED code → MineOutcome.errorCode = permissionDenied',
        () async {
      _mockChannel((call) async {
        if (call.method == 'checkForDuplicates') return false;
        if (call.method == 'addNote') {
          // native `requirePermission` guard rejects with this exact code.
          throw PlatformException(
            code: 'PERMISSION_DENIED',
            message:
                'AnkiDroid permission not granted. Please grant and retry.',
          );
        }
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.permissionDenied);
    });

    test(
        'raw "Permission not granted" provider message → permissionDenied '
        '(belt-and-suspenders when a guard is ever missed)', () async {
      _mockChannel((call) async {
        if (call.method == 'checkForDuplicates') return false;
        if (call.method == 'addNote') {
          // The raw SecurityException text the provider throws pre-fix — mapped
          // by message even without the stable code, so it never leaks to toast.
          throw PlatformException(
            code: 'ANKI_PROVIDER_ERROR',
            message: 'Permission not granted for: '
                'CardContentProvider.query /decks (app.fushi.reader)',
          );
        }
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.permissionDenied);
    });

    test('an unrelated PlatformException stays unclassified (errorCode null)',
        () async {
      _mockChannel((call) async {
        if (call.method == 'checkForDuplicates') return false;
        if (call.method == 'addNote') {
          throw PlatformException(code: 'ADD_NOTE_FAILED', message: 'boom');
        }
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.mineEntry(
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, isNull);
      expect(outcome.errorDetail, contains('boom'));
    });

    test('updateMinedNote also classifies PERMISSION_DENIED', () async {
      _mockChannel((call) async {
        if (call.method == 'updateNoteFields') {
          throw PlatformException(
            code: 'PERMISSION_DENIED',
            message:
                'AnkiDroid permission not granted. Please grant and retry.',
          );
        }
        fail('unexpected channel call: ${call.method}');
      });

      final repo = _ConfiguredAnkiRepository(_settings());
      final outcome = await repo.updateMinedNote(
        noteId: 42,
        rawPayloadJson: _payload,
        context: const AnkiMiningContext(sentence: 's'),
      );

      expect(outcome.result, MineResult.error);
      expect(outcome.errorCode, AnkiErrorCode.permissionDenied);
    });
  });

  group('BUG-824: native provider writes are guarded by requirePermission', () {
    // Source-scan guard: host has no real AnkiDroid, so we cannot exercise the
    // Java guard at runtime. Instead we assert every provider-mutating channel
    // case still routes through `requirePermission` — regressing this (dropping
    // the guard on addNote again) is exactly what produced the raw-toast bug.
    final File handler = File(
      '../../hibiki/android/app/src/main/java/app/fushi/reader/'
      'AnkiChannelHandler.java',
    );

    test('AnkiChannelHandler.java is present at the expected path', () {
      expect(handler.existsSync(), isTrue,
          reason: 'guard cannot run — path drifted: ${handler.path}');
    });

    // Slice a `case "<name>":` body up to the next `case "` label (robust to
    // early `break;`s inside the case, e.g. addFileToMedia's MISSING_ARG guard).
    String caseBody(String src, String label) {
      final int idx = src.indexOf('case "$label":');
      expect(idx, greaterThanOrEqualTo(0), reason: '$label case not found');
      final int next = src.indexOf('case "', idx + label.length + 8);
      return src.substring(idx, next < 0 ? src.length : next);
    }

    test('addNote case guards with requirePermission before touching provider',
        () {
      final String body = caseBody(handler.readAsStringSync(), 'addNote');
      expect(
        body.contains('requirePermission(result)'),
        isTrue,
        reason: 'BUG-824: addNote must call requirePermission before addNote() '
            'so an ungranted permission returns PERMISSION_DENIED + pops the '
            'system dialog instead of throwing a raw SecurityException',
      );
    });

    test('addFileToMedia case guards with requirePermission', () {
      final String body =
          caseBody(handler.readAsStringSync(), 'addFileToMedia');
      expect(body.contains('requirePermission(result)'), isTrue,
          reason: 'BUG-824: media insert also needs READ_WRITE_DATABASE');
    });
  });
}
