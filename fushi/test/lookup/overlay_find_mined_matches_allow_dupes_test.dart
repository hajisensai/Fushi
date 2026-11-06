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

/// 反馈 E0sdqm4h-F / PR #2980 审查：app 外裸 WebView（剪贴板面板 / 瞬态查词窗）点已制卡 ✓
/// 走 popup.js 页内面板，数据桥是 `findMinedMatches`。此前它不读「允许重复」，与 app 内
/// `runAnkiMinedCardAction` 不一致（开着允许重复，app 内直接新增、app 外仍弹选择）。
/// 这里驱动**真实**桥（`maybeHandleOverlayDeferredBridge` → `_handleFindMinedMatchesBridge`）：
///   - 单击 + 允许重复 → 回 `{mineNew: true}`，不反查；
///   - 右键 / 长按（`openChooser: true`）+ 允许重复 → 照旧列命中卡；
///   - 不允许重复 → 照旧列命中卡。
class _Repo extends BaseAnkiRepository {
  _Repo({required this.allowDupes});

  final bool allowDupes;
  int findCalls = 0;

  @override
  Future<AnkiSettings> loadSettings() async =>
      AnkiSettings(allowDupes: allowDupes);

  @override
  Future<List<MinedNoteRef>> findMatchingNotes(
    String expression,
    String reading,
  ) async {
    findCalls++;
    return const <MinedNoteRef>[MinedNoteRef(noteId: 42, preview: '刀 A')];
  }

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => MineOutcome.failure('unused');

  @override
  Future<Map<String, String>?> noteFields(int noteId) async => null;
  @override
  Future<bool> openNoteInAnki(int noteId) async => false;
  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      const AnkiFetchResult.error('stub');
  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;
  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;
  @override
  Future<bool> createDeck(String name) async => false;
}

AppModel _desktopModel(_Repo repo) => AppModel(
  PlatformServices(
    directory: DesktopDirectoryService(),
    lifecycle: DesktopLifecycleService(),
    clipboard: DesktopClipboardService(),
    permission: DesktopPermissionService(),
    deviceInfo: DesktopDeviceInfoService(),
    createAnkiRepository: ({AnkiSettingsStore? settingsStore}) => repo,
  ),
);

Future<Object?> _ask(_Repo repo, {bool? openChooser}) async {
  Object? reply;
  bool replied = false;
  final bool handled = maybeHandleOverlayDeferredBridge(
    model: _desktopModel(repo),
    handler: 'findMinedMatches',
    message: <String, Object?>{
      '__bridgeId': 9,
      'args': <Object?>[
        <String, Object?>{
          'expression': '刀',
          'reading': 'かたな',
          if (openChooser != null) 'openChooser': openChooser,
        },
      ],
    },
    resolveBridge: (int id, Object? value) async {
      reply = value;
      replied = true;
    },
  );
  expect(handled, isTrue);
  for (int i = 0; i < 100 && !replied; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(replied, isTrue, reason: '桥必须回包，✓ 不能挂');
  return reply;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('允许重复 + 单击：回 {mineNew: true}，不反查命中卡', () async {
    final _Repo repo = _Repo(allowDupes: true);
    final Object? reply = await _ask(repo, openChooser: false);
    expect(reply, <String, Object?>{'mineNew': true});
    expect(repo.findCalls, 0);
  });

  test('允许重复 + 右键 / 长按（openChooser）：照旧列命中卡，覆写 / 查看入口还在', () async {
    final _Repo repo = _Repo(allowDupes: true);
    final Object? reply = await _ask(repo, openChooser: true);
    expect(reply, <Map<String, Object?>>[
      <String, Object?>{'noteId': 42, 'preview': '刀 A'},
    ]);
    expect(repo.findCalls, 1);
  });

  test('不允许重复：单击照旧列命中卡（弹选择）', () async {
    final _Repo repo = _Repo(allowDupes: false);
    final Object? reply = await _ask(repo);
    expect(reply, isA<List<Object?>>());
    expect((reply! as List<Object?>).length, 1);
    expect(repo.findCalls, 1);
  });
}
