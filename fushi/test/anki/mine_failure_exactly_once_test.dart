import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/mine_failure_notice.dart';
import 'package:fushi/src/lookup/overlay_bridge_handlers.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/platform/desktop/desktop_clipboard_service.dart';
import 'package:fushi/src/platform/desktop/desktop_device_info_service.dart';
import 'package:fushi/src/platform/desktop/desktop_directory_service.dart';
import 'package:fushi/src/platform/desktop/desktop_lifecycle_service.dart';
import 'package:fushi/src/platform/desktop/desktop_permission_service.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

import '../helpers/test_platform_services.dart';

// BUG-3652 续（PR #2438 审查遗留）：#2438 让弹窗发起的制卡失败只在弹窗里说一次、宿主
// 不再弹 toast。可回包回来时弹窗若已经不在（阅读器制卡排队 / AnkiConnect 慢，用户先关
// 了弹窗、弹窗被导航销毁或换了词），那句原因就无处可说——比改动前（至少有 toast）更糟。
//
// 修法的唯一落点是 [MineFailureNotice]：弹窗仍在且是那一次 → 原样交给弹窗；已不在 →
// 宿主 toast 一次、回包标 hostReported 让弹窗闭嘴；弹窗还在但按钮被换掉 → popup.js
// 回 mineFailureUnseen 由宿主 toast（JS 那半在 popup_asset_behavior_test.js）。
//
// toast 一律经 [MineFailureNotice.debugToastSink] 计数：widget 测试里 FushiToast 没有
// 全局 navigatorKey、永远进不了树，按 toast 文案 find 恒假 / findsNothing 恒真。

const String _reason = '没有选择卡组。';

typedef _Toast = ({String message, MineToastStatus status});

final List<_Toast> _toasts = <_Toast>[];

MinePopupResult _failure({bool duplicate = false}) => MinePopupResult.failed(
  MineOutcome(duplicate ? MineResult.duplicate : MineResult.error),
  message: _reason,
);

// ---------------------------------------------------------------------------
// app 内 WebView 弹窗（词典弹窗 mixin / 阅读器 / 漫画 / PDF / texthooker 共用
// DictionaryPopupWebView 的 mineEntry / updateEntry / minedCardAction 三根桥）。
// ---------------------------------------------------------------------------

class _AppModel extends AppModel {
  _AppModel() : super(testPlatformServices());

  @override
  int get maximumTerms => 10;
  @override
  double get popupMaxWidth => 360;
  @override
  double get popupMaxHeight => 360;
  @override
  bool get popupBottomDocked => false;
  @override
  double get appUiScale => 1.0;
  @override
  bool get lowMemoryMode => false;
  @override
  List<String> get enabledAudioSources => const <String>[];
  @override
  List<AudioSourceConfig> get audioSourceConfigs => const <AudioSourceConfig>[];
  @override
  double get dictionaryFontSize => 16;
  @override
  double get popupWheelSpeed => 1.0;
  @override
  bool get popupInstantScroll => false;
  @override
  double get popupInstantScrollWheelStep => 0.5;
  @override
  double get popupInstantScrollTouchStep => 0.25;
  @override
  bool get compactGlossaries => false;
  @override
  bool get dictionaryUnifiedStyle => true;
  @override
  int get popupDictionaryColumns => 1;
  @override
  int get popupAutoExpandDictionaries => 0;
  @override
  bool get deduplicatePitchAccents => false;
  @override
  bool get harmonicFrequency => false;
  @override
  bool get showExpressionTags => false;
  @override
  bool get collapseDictionaries => false;
  @override
  List<Dictionary> get dictionaries => const <Dictionary>[];
  @override
  Map<String, String> get customDictCSS => const <String, String>{};
  @override
  String get globalDictCSS => '';
}

final DictionarySearchResult _hit = DictionarySearchResult(
  searchTerm: '刀',
  entries: <DictionaryEntry>[
    DictionaryEntry(word: '刀', reading: 'かたな', meaning: 'sword'),
  ],
);

/// 与三个生产宿主（base_source_page / dictionary_page_mixin / popup_dictionary_page）
/// 同形：弹窗栈来自 [DictionaryPopupController]，每层经 [parkedPopupLayer] 停驻 /
/// 显示，`isSessionOnScreen` 绑到 `controller.isEntryOnScreen(entry)`。
Widget _host(DictionaryPopupController controller) {
  const Size screen = Size(800, 600);
  return ProviderScope(
    overrides: <Override>[appProvider.overrideWith((ref) => _AppModel())],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: controller,
            builder: (BuildContext context, Widget? _) => Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                for (final DictionaryPopupEntry entry in controller.entries)
                  parkedPopupLayer(
                    key: ObjectKey(entry),
                    pos: const Rect.fromLTWH(10, 10, 360, 360),
                    visible: entry.visible,
                    screen: screen,
                    child: DictionaryPopupLayer(
                      result: entry.result,
                      keepWebViewWarm: entry.isWarmSlot,
                      webViewKey: entry.webViewKey,
                      onDismiss: () {},
                      onTextSelected: (String _, Rect __, List<Object?> ___) {},
                      onLinkClick: (String _, Rect __) {},
                      onMineEntry: (Map<String, String> _) async =>
                          const MinePopupResult(),
                      isSessionOnScreen: () =>
                          controller.isEntryOnScreen(entry),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// 发起一次「制卡」：走 WebView 三根桥共用的 `_runMineBridge`（发起前记下弹窗身份、
/// 回包时核对）。返回 [complete]：交出宿主结果并把回包读回来。
({
  void Function(MinePopupResult) complete,
  Map<String, Object?>? Function() reply,
})
_startMine(DictionaryPopupWebViewState state) {
  final Completer<MinePopupResult> host = Completer<MinePopupResult>();
  Map<String, Object?>? reply;
  unawaited(
    state
        .debugRunMineBridge(() => host.future)
        .then((Map<String, Object?> r) => reply = r),
  );
  return (complete: host.complete, reply: () => reply);
}

// ---------------------------------------------------------------------------
// app 外覆盖窗（桌面查词 / gal 卡片 / 网页视频全局查词）走 overlay_bridge_handlers。
// ---------------------------------------------------------------------------

class _FailingAnkiRepo extends BaseAnkiRepository {
  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => MineOutcome.failure(
    'All fields are empty',
    errorCode: AnkiErrorCode.allFieldsEmpty,
  );

  @override
  Future<MineOutcome> updateMinedNote({
    required int noteId,
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async => MineOutcome.failure(
    'All fields are empty',
    errorCode: AnkiErrorCode.allFieldsEmpty,
  );

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

AppModel _desktopModel() => AppModel(
  PlatformServices(
    directory: DesktopDirectoryService(),
    lifecycle: DesktopLifecycleService(),
    clipboard: DesktopClipboardService(),
    permission: DesktopPermissionService(),
    deviceInfo: DesktopDeviceInfoService(),
    createAnkiRepository: _FailingAnkiRepo.new,
  ),
);

/// 把一条 popup.js 的 overlay 桥消息喂给生产 handler，等它经 resolveBridge 回包。
Future<Map<String, Object?>> _overlayRoundTrip(
  String handler,
  Map<String, Object?> args, {
  required bool Function() originOnScreen,
}) async {
  final Completer<Object?> replied = Completer<Object?>();
  final bool handled = maybeHandleOverlayDeferredBridge(
    model: _desktopModel(),
    handler: handler,
    message: <String, Object?>{
      '__bridgeId': 3,
      'args': <Object?>[args],
    },
    resolveBridge: (int id, Object? value) async => replied.complete(value),
    isOriginOnScreen: originOnScreen,
  );
  expect(handled, isTrue);
  final Object? value = await replied.future.timeout(
    const Duration(seconds: 10),
  );
  return (value! as Map<Object?, Object?>).cast<String, Object?>();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LocaleSettings.setLocaleRaw('zh-CN');
    _toasts.clear();
    MineFailureNotice.debugToastSink = (String message, MineToastStatus s) =>
        _toasts.add((message: message, status: s));
  });

  tearDown(() => MineFailureNotice.debugToastSink = null);

  group('MineFailureNotice：唯一落点', () {
    test('弹窗仍在：回包原样交给弹窗，宿主不 toast', () {
      final Map<String, Object?> reply = _failure().toJson();
      expect(
        MineFailureNotice.settle(reply, originOnScreen: true),
        same(reply),
      );
      expect(_toasts, isEmpty, reason: '弹窗会就地说，宿主再 toast 就是 #2438 修掉的双报');
    });

    test('弹窗已不在：宿主 toast 一次，回包去掉原因并标 hostReported', () {
      final Map<String, Object?> out = MineFailureNotice.settle(
        _failure().toJson(),
        originOnScreen: false,
      );
      expect(_toasts, hasLength(1));
      expect(_toasts.single.message, _reason);
      expect(_toasts.single.status, MineToastStatus.failed);
      expect(out.containsKey('message'), isFalse);
      expect(out[MineFailureNotice.hostReportedKey], isTrue);
      expect(out['ankiConnect'], isFalse, reason: '按钮态字段原样保留');
    });

    test('重复卡按 duplicate 状态 toast', () {
      MineFailureNotice.settle(
        _failure(duplicate: true).toJson(),
        originOnScreen: false,
      );
      expect(_toasts.single.status, MineToastStatus.duplicate);
    });

    test('被收下 / 没有原因 / 已报过的结果不 toast', () {
      for (final Map<String, Object?> reply in <Map<String, Object?>>[
        const MinePopupResult(ankiConnect: true, noteId: 1).toJson(),
        const MinePopupResult.queued().toJson(),
        // 已制卡操作单里用户取消：没有要说的话。
        const MinePopupResult().toJson(),
        <String, Object?>{'ankiConnect': false, 'hostReported': true},
      ]) {
        expect(
          MineFailureNotice.settle(reply, originOnScreen: false),
          same(reply),
        );
      }
      expect(_toasts, isEmpty);
    });

    test('mineFailureUnseen 回执 toast 一次；形状不对什么都不做', () {
      MineFailureNotice.reportUnseen(<String, Object?>{
        'message': _reason,
        'duplicate': false,
      });
      expect(_toasts, hasLength(1));
      expect(_toasts.single.message, _reason);
      MineFailureNotice.reportUnseen(null);
      MineFailureNotice.reportUnseen(<String, Object?>{'message': ''});
      MineFailureNotice.reportUnseen('x');
      expect(_toasts, hasLength(1));
    });
  });

  group('app 内 WebView 弹窗（mixin / 阅读器 / 漫画 / PDF / texthooker）', () {
    testWidgets('弹窗还在：原因随回包交给弹窗就地说，不 toast', (WidgetTester tester) async {
      final DictionaryPopupController controller = DictionaryPopupController(
        lowMemory: false,
      );
      addTearDown(controller.dispose);
      final DictionaryPopupEntry entry = controller.beginTop(
        term: '刀',
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true,
        initialResult: _hit,
      );
      await tester.pumpWidget(_host(controller));
      final mine = _startMine(entry.webViewKey.currentState!);

      mine.complete(_failure());
      await tester.pump();

      expect(mine.reply(), isNotNull);
      expect(mine.reply()!['message'], _reason);
      expect(
        mine.reply()!.containsKey(MineFailureNotice.hostReportedKey),
        isFalse,
      );
      expect(_toasts, isEmpty);
    });

    testWidgets('回包前弹窗被关（WebView 已销毁）：宿主 toast 一次', (
      WidgetTester tester,
    ) async {
      final DictionaryPopupController controller = DictionaryPopupController(
        lowMemory: false,
      );
      addTearDown(controller.dispose);
      final DictionaryPopupEntry entry = controller.beginTop(
        term: '刀',
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        reuseWarmSlot: false,
        replaceStack: true,
        visible: true,
        initialResult: _hit,
      );
      await tester.pumpWidget(_host(controller));
      final mine = _startMine(entry.webViewKey.currentState!);

      controller.clear();
      await tester.pump();
      expect(
        entry.webViewKey.currentState,
        isNull,
        reason: '前提：弹窗 WebView 已卸载',
      );

      mine.complete(_failure());
      await tester.pump();

      expect(_toasts, hasLength(1));
      expect(_toasts.single.message, _reason);
      expect(mine.reply()![MineFailureNotice.hostReportedKey], isTrue);
      expect(mine.reply()!.containsKey('message'), isFalse);
    });

    testWidgets('回包前弹窗收回热槽停驻（WebView 还活着）：仍算不在，toast 一次', (
      WidgetTester tester,
    ) async {
      final DictionaryPopupController controller = DictionaryPopupController(
        lowMemory: false,
      );
      addTearDown(controller.dispose);
      controller.seedWarmSlot();
      final DictionaryPopupEntry entry = controller.beginTop(
        term: '刀',
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        reuseWarmSlot: true,
        replaceStack: false,
        visible: true,
        initialResult: _hit,
      );
      expect(entry.isWarmSlot, isTrue, reason: '前提：复用的是常驻热槽');
      await tester.pumpWidget(_host(controller));
      final DictionaryPopupWebViewState state = entry.webViewKey.currentState!;
      final mine = _startMine(state);

      // 用户关掉弹窗：热槽不销毁，只是停驻到屏外等下一次查词。
      controller.pruneToWarmSlot();
      await tester.pump();
      expect(
        identical(entry.webViewKey.currentState, state),
        isTrue,
        reason: '前提：同一个 WebView 仍挂载——只看 mounted 会把它当成还在屏上',
      );

      mine.complete(_failure());
      await tester.pump();

      expect(_toasts, hasLength(1), reason: '停驻的热槽在屏外，交给它就等于没人看见');
      expect(
        mine.reply()![MineFailureNotice.hostReportedKey],
        isTrue,
        reason: '那份文档还活着：必须让 popup.js 闭嘴，否则下次翻出时重复',
      );
    });
  });

  group('app 外覆盖窗（桌面查词 / gal 卡片 / 网页视频全局查词）', () {
    test('卡还在：失败原因回给卡片就地说，不 toast', () async {
      final Map<String, Object?> reply = await _overlayRoundTrip(
        'mineEntry',
        <String, Object?>{'expression': '刀', 'dictionaryMedia': ''},
        originOnScreen: () => true,
      );
      expect(reply['message'], t.anki_error_all_fields_empty);
      expect(_toasts, isEmpty);
    });

    test('卡已关 / 已换成别的查词（route 作废）：宿主 toast 一次', () async {
      final Map<String, Object?> reply = await _overlayRoundTrip(
        'mineEntry',
        <String, Object?>{'expression': '刀', 'dictionaryMedia': ''},
        originOnScreen: () => false,
      );
      expect(_toasts, hasLength(1));
      expect(_toasts.single.message, t.anki_error_all_fields_empty);
      expect(reply[MineFailureNotice.hostReportedKey], isTrue);
      expect(reply.containsKey('message'), isFalse);
    });

    test('覆写同一套：卡已关时 toast 一次', () async {
      final Map<String, Object?> reply = await _overlayRoundTrip(
        'updateEntry',
        <String, Object?>{
          'noteId': 9,
          'fields': <String, Object?>{'expression': '刀', 'dictionaryMedia': ''},
        },
        originOnScreen: () => false,
      );
      expect(_toasts, hasLength(1));
      expect(reply[MineFailureNotice.hostReportedKey], isTrue);
    });

    test('mineFailureUnseen 回执经共享桥 toast 一次', () {
      final bool handled = maybeHandleOverlayDeferredBridge(
        model: null,
        handler: 'mineFailureUnseen',
        message: <String, Object?>{
          'args': <Object?>[
            <String, Object?>{'message': _reason, 'duplicate': true},
          ],
        },
        resolveBridge: (int id, Object? value) async {},
      );
      expect(handled, isTrue);
      expect(_toasts, hasLength(1));
      expect(_toasts.single.status, MineToastStatus.duplicate);
    });
  });

  group('接线（行为层够不到的那一行）', () {
    test('三个 app 内宿主都把 isSessionOnScreen 绑到弹窗栈模型', () {
      const Map<String, String> hosts = <String, String>{
        'lib/src/pages/base_source_page.dart':
            'isSessionOnScreen: () => _popup.isEntryOnScreen(item)',
        'lib/src/pages/implementations/dictionary_page_mixin.dart':
            'isSessionOnScreen: () => controller.isEntryOnScreen(entry)',
        'lib/src/pages/implementations/popup_dictionary_page.dart':
            'isSessionOnScreen: () => _popup.isEntryOnScreen(entry)',
      };
      for (final MapEntry<String, String> host in hosts.entries) {
        expect(
          File(host.key).readAsStringSync().contains(host.value),
          isTrue,
          reason:
              '${host.key} 没接 isSessionOnScreen：弹窗关了 / 停驻后失败原因会交给'
              '一个没人看的弹窗（BUG-3652 续）',
        );
      }
    });

    test('覆盖窗控制器按发起时的查词 route 判卡还在不在', () {
      final String src = File(
        'lib/src/lookup/global_lookup_controller.dart',
      ).readAsStringSync();
      expect(
        src.contains(
          'isOriginOnScreen: _mineOriginProbe(GlobalLookupChannel.currentRoute)',
        ),
        isTrue,
      );
      expect(
        src.contains(
          '() => origin == _activeRoute && GlobalLookupChannel.isRouteValid(origin)',
        ),
        isTrue,
      );
    });
  });
}
