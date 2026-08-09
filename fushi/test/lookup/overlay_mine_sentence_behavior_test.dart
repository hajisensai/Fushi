import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/platform/desktop/desktop_clipboard_service.dart';
import 'package:fushi/src/platform/desktop/desktop_device_info_service.dart';
import 'package:fushi/src/platform/desktop/desktop_directory_service.dart';
import 'package:fushi/src/platform/desktop/desktop_lifecycle_service.dart';
import 'package:fushi/src/platform/desktop/desktop_permission_service.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// BUG-730 — BEHAVIOURAL test (not source-scan): drives the REAL app-external
/// mine bridge (`maybeHandleOverlayDeferredBridge` → `_handleMineBridge` →
/// `_mineEntry` → `resolveMineSentence` → `repo.mineEntry`) and asserts the
/// captured sentence that reaches `AnkiMiningContext.sentence` is the surface's
/// clipboard/UIA sentence. Needs no dictionary, no overlay window, and no live
/// Anki backend: a real [AppModel] is constructed with desktop services and a
/// capturing repo, then the exact JS `mineEntry` message is fed through the
/// production handler. This is the runtime proof that the fix moves the
/// clipboard text onto the mined card's {sentence} field (the one thing that was
/// broken); the full visible-window + real-Anki gate stays manual.
class _CapturingAnkiRepo extends BaseAnkiRepository {
  AnkiMiningContext? captured;
  String? capturedPayloadJson;

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    captured = context;
    capturedPayloadJson = rawPayloadJson;
    // result != success → `_mineEntry` skips `_recordMinedStats` (no DB touch).
    return MineOutcome.failure('capture');
  }

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => null;
  @override
  Future<bool> openNoteInAnki(int noteId) async => false;
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('stub');
  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

AppModel _desktopModel(_CapturingAnkiRepo repo) => AppModel(
      PlatformServices(
        directory: DesktopDirectoryService(),
        lifecycle: DesktopLifecycleService(),
        clipboard: DesktopClipboardService(),
        permission: DesktopPermissionService(),
        deviceInfo: DesktopDeviceInfoService(),
        createAnkiRepository: () => repo,
      ),
    );

Map<String, Object?> _mineMessage(
  Map<String, Object?> fields, {
  int bridgeId = 7,
}) =>
    <String, Object?>{
      '__bridgeId': bridgeId,
      'args': <Object?>[fields],
    };

Future<void> _pumpUntil(bool Function() done) async {
  for (int i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('clipboard sentence context reaches AnkiMiningContext.sentence',
      () async {
    final _CapturingAnkiRepo repo = _CapturingAnkiRepo();
    const String clipboard = '今日は真剣勝負だ、負けられない。';
    int? repliedId;

    final bool handled = maybeHandleOverlayDeferredBridge(
      model: _desktopModel(repo),
      handler: 'mineEntry',
      message: _mineMessage(<String, Object?>{
        'expression': '勝負',
        'reading': 'しょうぶ',
        'matched': '勝負',
        'dictionaryMedia': '',
        // JS never sends `sentence` for these surfaces (the bug): omitted here.
      }),
      resolveBridge: (int id, Object? value) async => repliedId = id,
      sentenceContext: clipboard,
    );

    expect(handled, isTrue, reason: 'mineEntry 必须被共享桥接管');
    await _pumpUntil(() => repo.captured != null);

    expect(repo.captured, isNotNull, reason: '制卡桥必须真的调到 repo.mineEntry');
    expect(repo.captured!.sentence, clipboard,
        reason: 'BUG-730：剪贴板整句必须落到卡片 {sentence}（过去恒空）');
    expect(repo.captured!.source, AnkiMiningSource.book);
    expect(repliedId, 7, reason: '制卡结果必须经 resolveBridge 回传（➕ 不挂）');
  });

  test('a JS-provided sentence still wins over the surface context', () async {
    final _CapturingAnkiRepo repo = _CapturingAnkiRepo();

    maybeHandleOverlayDeferredBridge(
      model: _desktopModel(repo),
      handler: 'mineEntry',
      message: _mineMessage(<String, Object?>{
        'expression': '勝負',
        'sentence': 'JS が明示的に送った文',
        'dictionaryMedia': '',
      }),
      resolveBridge: (int id, Object? value) async {},
      sentenceContext: 'クリップボードの文（使われないはず）',
    );

    await _pumpUntil(() => repo.captured != null);
    expect(repo.captured!.sentence, 'JS が明示的に送った文',
        reason: 'JS 非空 sentence 优先，context 只是兜底（future-proof）');
  });

  test('empty context + no JS sentence -> empty (never crashes)', () async {
    final _CapturingAnkiRepo repo = _CapturingAnkiRepo();

    maybeHandleOverlayDeferredBridge(
      model: _desktopModel(repo),
      handler: 'mineEntry',
      message: _mineMessage(<String, Object?>{
        'expression': '勝負',
        'dictionaryMedia': '',
      }),
      resolveBridge: (int id, Object? value) async {},
      sentenceContext: '',
    );

    await _pumpUntil(() => repo.captured != null);
    expect(repo.captured!.sentence, '');
  });

  test('Hook mining delegate receives the current lookup payload', () async {
    final _CapturingAnkiRepo repo = _CapturingAnkiRepo();
    Map<String, String>? delegatedFields;
    Object? reply;

    final bool handled = maybeHandleOverlayDeferredBridge(
      model: _desktopModel(repo),
      handler: 'mineEntry',
      message: _mineMessage(<String, Object?>{
        'expression': '化け物',
        'reading': 'ばけもの',
        'dictionaryMedia': '',
      }),
      resolveBridge: (int id, Object? value) async => reply = value,
      sentenceContext: '浮窗中的完整台词',
      miningHandler: ({
        required Map<String, String> fields,
        int? updateNoteId,
      }) async {
        delegatedFields = fields;
        expect(updateNoteId, isNull);
        return const <String, Object?>{
          'ankiConnect': false,
          'noteId': null,
        };
      },
    );

    expect(handled, isTrue);
    await _pumpUntil(() => delegatedFields != null && reply != null);
    expect(delegatedFields?['expression'], '化け物');
    expect(repo.captured, isNull,
        reason: 'the generic clipboard mining path must be bypassed');
    expect(reply, isA<Map<String, Object?>>());
  });

  test('Hook mining delegate receives update note id', () async {
    final _CapturingAnkiRepo repo = _CapturingAnkiRepo();
    int? delegatedNoteId;
    bool replied = false;

    maybeHandleOverlayDeferredBridge(
      model: _desktopModel(repo),
      handler: 'updateEntry',
      message: <String, Object?>{
        '__bridgeId': 8,
        'args': <Object?>[
          <String, Object?>{
            'noteId': 731,
            'fields': <String, Object?>{
              'expression': '怪物',
              'dictionaryMedia': '',
            },
          },
        ],
      },
      resolveBridge: (int id, Object? value) async => replied = true,
      miningHandler: ({
        required Map<String, String> fields,
        int? updateNoteId,
      }) async {
        delegatedNoteId = updateNoteId;
        return const <String, Object?>{
          'ankiConnect': false,
          'noteId': null,
        };
      },
    );

    await _pumpUntil(() => delegatedNoteId != null && replied);
    expect(delegatedNoteId, 731);
    expect(repo.captured, isNull);
  });
}
