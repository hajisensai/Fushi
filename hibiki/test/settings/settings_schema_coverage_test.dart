import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:hibiki/models.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/models/theme_notifier.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/settings/material_settings_renderer.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

import '../../integration_test/helpers/effect_probes.dart';
import '../../integration_test/helpers/focus_driver.dart';
import '../../integration_test/helpers/schema_settings_verifier.dart';
import '../helpers/test_platform_services.dart';

/// 这些设置在 widget/unit 覆盖 harness 里观测不到「真生效」（消费点在真实
/// WebView popup.js / 原生通知 / Android-only 更新路径 / 音量键回调 / 单例
/// 不进 settings DB），但各自有专项测试或登记为设备集成 backlog。映射到证据，
/// 让覆盖测试不对「别处已覆盖」的项裸喊 UNVERIFIED/FAIL，且强制每个 changed
/// 但未 effect-verified 的设置都必须有去处（no silent caps）。
const Map<String, String> kCoveredElsewhere = <String, String>{
  // 专项 unit/widget 生效探针（docs/specs/2026-06-03-t4-effect-probes-plan.md T1–T9）
  'reading/Text Orientation': 'test/reader/reader_content_styles_test.dart',
  'reading/Font Kerning (Vertical)':
      'test/reader/reader_content_styles_test.dart',
  'reading/VPAL (Vertical Alt)': 'test/reader/reader_content_styles_test.dart',
  'appearance/Design System': 'test/models/theme_notifier_test.dart',
  'appearance/UI size': 'test/models/theme_notifier_test.dart',
  'reading/Spread Mode': 'test/epub/epub_spread_map_test.dart',
  'lookup/Popup max width': 'test/pages/dictionary_popup_layer_test.dart',
  'lookup/Popup max height': 'test/pages/dictionary_popup_layer_test.dart',
  'lookup/Instant popup scroll': 'test/reader/reader_caret_scripts_test.dart',
  // TODO-108: 底部固定弹窗开关——生效点在纯函数 dockedPopupRect 与 base_source_page/dictionary_page_mixin 的路由分流（非 reader CSS / 主题树），
  // 无 reader/appearance 探针；由专项纯函数 + widget 测试覆盖。
  'lookup/Bottom-docked popup':
      'test/pages/dictionary_popup_layer_test.dart + test/settings/popup_bottom_docked_switch_test.dart',
  'cardCreation/Auto-add book title to tags':
      'test/creator/tags_field_auto_add_book_test.dart',
  // TODO-135: 默认标签区现无条件显示（hibiki/分类两开关移出 isConfigured 门控），
  // focus-driven 现能驱动到它们；但它们写的是 AnkiSettings（经 SharedPreferences，
  // 非本测试的内存 DB），故 changed=false。标签拼装行为本体由 hibiki_anki 真制卡
  // 测试咬住（tagIncludeHibiki/tagIncludeCategory 开/关各分支）。
  'cardCreation/Add "hibiki" tag':
      'packages/hibiki_anki/test/mining_tag_and_parallel_test.dart',
  'cardCreation/Add source category tag':
      'packages/hibiki_anki/test/mining_tag_and_parallel_test.dart',
  'system/Low Memory Mode': 'test/models/app_model_low_memory_mode_test.dart',
  'system/Keyboard & gamepad focus navigation':
      'test/shortcuts/global_space_no_activate_test.dart + main.dart 门控安装 HibikiFocusRoot/Ring',
  'lookup/Swipe dismiss sensitivity':
      'test/widgets/swipe_dismiss_wrapper_test.dart',
  'reading/Reverse keyboard left/right page-turn direction':
      'test/reader/reader_space_pause_test.dart + test/shortcuts/global_navigation_test.dart',
  // TODO-436/407②：查词弹窗"滑动关闭"开关。归「查词」分组（destId=lookup）。生效点
  // 在 DictionaryPopupLayer 的 swipe 边界（仅顶栏可滑）+ 平台默认纯函数
  // ReaderSettings.defaultSwipeToClose，由专项 widget 行为 + 纯函数真值表测试覆盖
  // （非 reader CSS / 主题树）。
  'lookup/Swipe to close popup':
      'test/pages/dictionary_popup_swipe_close_test.dart',
  'system/Enable debug log': 'test/utils/misc/debug_log_service_test.dart',
  'syncBackup/Auto Sync': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync Statistics': 'test/sync/sync_gating_test.dart',
  'syncBackup/Upload book files': 'test/sync/sync_gating_test.dart',
  'syncBackup/Sync dictionaries': 'test/sync/sync_gating_test.dart',
  'syncBackup/Upload audiobook files': 'test/sync/sync_orchestrator_test.dart',
  'syncBackup/Sync local audio': 'test/sync/sync_orchestrator_test.dart',
  // TODO-212: video destination items are behavior-heavy; schema coverage proves
  // focus/change/persist/restore here, while these narrower probes guard their
  // runtime consumption or the desktop/device seam.
  'video/Immersive mode':
      'test/pages/video_immersive_mode_levels_guard_test.dart + test/pages/video_statusbar_immersive_guard_test.dart',
  'video/Picture scaling':
      'test/pages/video_fit_mode_test.dart + test/pages/video_window_aspect_lock_static_test.dart',
  'video/Double-tap seek':
      'test/pages/video_double_tap_seek_guard_test.dart + test/pages/video_immersive_mode_levels_guard_test.dart',
  'video/Lock window to video aspect':
      'test/pages/video_window_aspect_lock_static_test.dart',
  'video/Blur subtitles (immersion)':
      'test/media/video/video_subtitle_overlay_test.dart + test/shortcuts/video_shortcut_registry_test.dart',
  // TODO-286: pref-only video settings surfaced in home settings for parity with
  // the in-player sheet. Schema coverage here proves focus/change/persist/restore
  // through the DB; the runtime effect of each underlying config is guarded by the
  // model round-trip / apply tests below (they all flow into the controller on the
  // next play via applyMpvConfigToPlayer / VideoSubtitleOverlay / asb config).
  'video/Long-press speed':
      'test/media/video/video_asbplayer_config_test.dart + test/pages/video_settings_schema_guard_test.dart',
  'video/Seek seconds':
      'test/media/video/video_asbplayer_config_test.dart + test/media/video/video_seek_relative_test.dart',
  'video/Subtitle Pause Playback Mode':
      'test/media/video/video_asbplayer_config_test.dart',
  'video/Quality enhancement':
      'test/media/video/video_mpv_config_test.dart + test/media/video/video_shader_manager_test.dart',
  'video/Hardware decoding': 'test/media/video/video_mpv_config_test.dart',
  'video/Debanding': 'test/media/video/video_mpv_config_test.dart',
  'video/Loop file': 'test/media/video/video_mpv_config_test.dart',
  'video/Font size':
      'test/media/video/video_subtitle_style_test.dart + test/media/video/video_subtitle_overlay_test.dart',
  'video/Font weight':
      'test/media/video/video_subtitle_style_test.dart + test/media/video/video_subtitle_font_consistency_test.dart',
  'video/Shadow': 'test/media/video/video_subtitle_style_test.dart',
  'video/Background opacity': 'test/media/video/video_subtitle_style_test.dart',
  'video/No background':
      'test/pages/video_quick_settings_sheet_test.dart + test/pages/video_settings_schema_guard_test.dart',
  'video/Vertical position':
      'test/media/video/video_subtitle_style_test.dart + test/pages/video_subtitle_push_up_guard_test.dart',
  'video/Show danmaku':
      'test/media/video/video_danmaku_settings_test.dart + test/pages/video_danmaku_wiring_guard_test.dart',
  'video/Online Dandanplay match':
      'test/media/video/video_danmaku_settings_test.dart + test/pages/video_danmaku_wiring_guard_test.dart',
  'video/Active danmaku limit':
      'test/media/video/video_danmaku_settings_test.dart + test/media/video/video_danmaku_layout_test.dart',
  // 设备/集成 backlog（消费点真机/WebView/Android-only，widget 测不到）
  'reading/Spread Direction': 'DEVICE: spread page order in WebView',
  'reading/Highlight text on tap': 'DEVICE: WebView onTap lookup',
  'reading/Tap empty area to hide controls':
      'DEVICE: WebView onTapEmpty chrome',
  'reading/Invert swipe page turn direction': 'DEVICE: WebView swipe direction',
  // TODO-120: 反转键盘方向键翻页方向——生效点在 reader 键盘处理器（纯函数
  // resolveReaderArrowPageTurn 的 reverse 参数），由专项纯函数测试覆盖。
  'reading/Reverse arrow-key page turn direction':
      'test/reader/reader_space_pause_test.dart',
  'reading/Volume key page turning speed': 'DEVICE: native volume-key throttle',
  'reading/Mouse wheel page-turn interval':
      'DEVICE: WebView wheel page-turn throttle',
  'reading/Swipe page-turn sensitivity':
      'test/reader/swipe_page_turn_sensitivity_test.dart',
  'reading/Keep screen awake': 'DEVICE: WakelockPlus channel',
  'reading/Volume button page turning': 'DEVICE: native VolumeKeyChannel',
  'reading/Invert volume buttons': 'DEVICE: native volume-key direction',
  'lookup/Pause on Lookup': 'DEVICE: audiobook pause on selection',
  'lookup/Aggregate word frequencies': 'DEVICE: popup.js frequency aggregation',
  'lookup/Auto search': 'WIDGET-TODO: HomeDictionaryPage debounce gate',
  'lookup/Remote dictionary lookup': 'INTEGRATION: remote host lookup',
  'lookup/Yomitan API server':
      'INTEGRATION: yomitan-api server lifecycle (test/sync/yomitan_api_server_manager_test.dart)',
  'lookup/Texthooker (receive text)':
      'INTEGRATION: texthooker WS client lifecycle (test/sync/texthooker_ws_client_host_test.dart)',
  'lookup/Desktop clipboard lookup':
      'DEVICE: clipboard watcher + hotkey lifecycle (test/sync/desktop_lookup_service_test.dart)',
  'lookup/Auto read word on lookup': 'DEVICE: TTS auto-read',
  'lookup/Lookup audio volume':
      'test/reader/lookup_audio_volume_settings_test.dart + test/utils/misc/lookup_audio_volume_wiring_static_test.dart + test/settings/settings_renderer_test.dart',
  'lookup/Collapse dictionaries': 'DEVICE: popup.js collapse',
  'lookup/Show expression tags': 'DEVICE: popup.js expression tags',
  'lookup/Deduplicate pitch accents': 'DEVICE: popup.js pitch dedup',
  'listening/Show media notification':
      'DEVICE: native AudioHandler notification',
  // TODO-038: now visible on Windows desktop too (no longer Android-only). The
  // strip is a runner-owned Win32 window, so the real overlay needs a desktop;
  // covered by source guards + device backlog.
  'listening/Floating lyric overlay':
      'test/media/audiobook/floating_lyric_click_through_guard_test.dart + test/settings/floating_lyric_settings_visibility_guard_test.dart + DEVICE: native always-on-top strip',
  'listening/Floating subtitle font size':
      'test/media/audiobook/desktop_floating_lyric_test.dart + DEVICE: native strip font size',
  // TODO-370: 文字 / 按钮底色透明度作用于 ARGB alpha 通道，效果由 scaleAlpha 纯函数测试
  // 覆盖；落到原生悬浮窗的实际像素需真机。
  'listening/Floating subtitle text opacity':
      'test/media/audiobook/floating_lyric_opacity_test.dart (scaleAlpha) + DEVICE: native strip text alpha',
  'listening/Floating subtitle button background opacity':
      'test/media/audiobook/floating_lyric_opacity_test.dart (scaleAlpha) + DEVICE: native strip button alpha',
  // TODO-576: 条背景透明度（默认 70=更不挡视野）作用于条背景 ARGB alpha；缩放由
  // scaleAlpha 纯函数测试覆盖，落到原生悬浮窗的实际像素需真机。
  'listening/Floating subtitle background opacity':
      'test/media/audiobook/floating_lyric_opacity_test.dart (scaleAlpha) + test/settings/floating_lyric_bg_opacity_test.dart + DEVICE: native strip bg alpha',
  'listening/Tap floating subtitle to look up':
      'test/media/audiobook/floating_lyric_click_through_guard_test.dart + DEVICE: native strip tap lookup',
  'listening/Volume Key Sentence Navigation':
      'DEVICE: native volume-key cue nav',
  'system/Update Channel': 'DEVICE: Android-only UpdateChecker (beta/stable)',
  "system/Don't remind me about updates": 'DEVICE: Android-only UpdateChecker',
  'system/Auto-install updates': 'DEVICE: Android-only UpdateChecker install',
  'appearance/Reverse navigation bar': 'WIDGET-TODO: HomePage nav order',
  'appearance/Open lookup on startup': 'test/pages/home_page_tabs_test.dart',
  'reading/Reverse reader bottom bar':
      'DEVICE: reader bottom-bar layout order (like reverse nav bar)',
};

/// 焦点驱动的 settings schema **全分组**覆盖测试（Phase 1 Task 4）。
///
/// 用仓库验证过的 settings_renderer harness（测试 AppModel + 内存 DB + 真实
/// schema + 真实 MaterialSettingsRenderer）逐个渲染**每个** destination 的明细
/// 页，再用 [FocusDriver] 以 Tab 焦点遍历整页：每个可聚焦节点若落在某个
/// `AdaptiveSettings*Row` 上就驱动它（Switch 用 Space 激活；Slider / Stepper /
/// Segmented 都是 _GamepadAdjustableValue 单一焦点停靠点，用 Left/Right 方向键
/// 原地调值），验证「改值 → 写穿 DB → 真生效 → 全局可还原」。
///
/// 生效探针按 destination 分派：reading → T1（`ReaderContentStyles.css` 渲染
/// 输入）；appearance → T2（`themeNotifier.theme` 渲染输入）；其余分组多为行为/
/// 持久类，暂无适用探针 → 按设计 §5 显式记为 UNVERIFIED 缺口（待 T4 行为探针），
/// 不静默放水也不误判失败。
///
/// 比 flutter drive 跑 app.main 更确定、更快、无 live-app 后台噪音；逐设置校验
/// 平台无关。整 app 流程的真机/桌面验证由 app_smoke 等承担（Phase 2-4）。
void main() {
  test('reverse arrow setting keeps schema title wired to i18n', () {
    // TODO-586：reverse_arrow 项随 reading destination 搬到 reading 领域文件。
    final String source = File('lib/src/settings/settings_schema_reading.dart')
        .readAsStringSync();

    expect(
      source,
      contains("id: 'reading_controls.reverse_arrow_page_turn'"),
    );
    expect(source, contains('title: t.reverse_arrow_page_turn'));
  });

  testWidgets(
      'all settings destinations: focus-driven, change persists and takes effect',
      (WidgetTester tester) async {
    // cardCreation 详情页现在内联渲染 AnkiSettingsBody（扁平化后不再藏在子路由
    // 后），它经 ankiViewModelProvider → BaseAnkiRepository 调
    // SharedPreferences.getInstance()；host 无插件实现会抛 MissingPluginException。
    // mock 空初值让其确定性成功，不依赖异步异常逃逸 takeException 窗口。
    SharedPreferences.setMockInitialValues(<String, Object>{});

    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    final ReaderSettings? prevReaderSettings =
        ReaderHibikiSource.readerSettings;
    final ReaderSettings readerSettings = ReaderSettings(db);
    await readerSettings.refreshFromDb();
    ReaderHibikiSource.readerSettings = readerSettings;
    addTearDown(() => ReaderHibikiSource.readerSettings = prevReaderSettings);

    final ThemeNotifier themeNotifier =
        ThemeNotifier(db, () => const TextTheme())
          ..loadFromPrefsSnapshot(<String, String>{
            'design_system': PrefCodec.encode('material'),
            'app_theme_key': PrefCodec.encode('system-theme'),
            'brightness_mode': PrefCodec.encode('system'),
            'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
          });
    addTearDown(themeNotifier.dispose);
    // 用现成公开 seam 把 schema 渲染需要的子系统全部 wire 到同一内存 DB（不改
    // app_model.dart，避开并发 agent 冲突）：wireDatabaseForTesting 设 database；
    // wireLocalAudioForTesting 设 prefsRepo(+localAudioManager) —— prefsRepo 是
    // appearance/lookup/cardCreation/listening/system 绝大多数 blocker 的根源。
    final Directory tmpDir =
        Directory.systemTemp.createTempSync('hibiki_settings_cov_');
    addTearDown(() {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {}
    });
    final PreferencesRepository prefsRepo = PreferencesRepository(db);
    await prefsRepo.loadFromDb();
    final AppModel appModel = _CoverageAppModel()
      ..themeNotifier = themeNotifier
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(
          prefsRepo: prefsRepo, databaseDirectory: tmpDir)
      // 语言选择器读 locales late-Map；populateLanguages/Locales 是公开纯 Dart
      // 静态注册（startup 也调它们），填好 system 分组的语言项才能渲染。
      ..populateLanguages()
      ..populateLocales();

    // 探针：reading→T1 reader CSS；appearance→T2 themeNotifier.theme 渲染输入。
    final ReaderCssEffectProbe readerProbe =
        ReaderCssEffectProbe(() => readerSettings);
    final RenderInputProbe themeProbe = RenderInputProbe(
      () => '${themeNotifier.theme.colorScheme}|'
          '${themeNotifier.darkTheme.colorScheme}|'
          '${themeNotifier.brightnessMode}|${themeNotifier.appThemeKey}',
      tier: EffectTier.t2WidgetTree,
    );
    EffectProbe? probeFor(SettingsDestinationId id) => switch (id) {
          SettingsDestinationId.reading => readerProbe,
          SettingsDestinationId.appearance => themeProbe,
          _ => null,
        };

    final ValueNotifier<SettingsDestination?> destNotifier =
        ValueNotifier<SettingsDestination?>(null);
    addTearDown(destNotifier.dispose);
    List<SettingsDestination> destinations = const <SettingsDestination>[];

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => appModel)],
      child: MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          platform: TargetPlatform.android,
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
          extensions: <ThemeExtension<dynamic>>[
            HibikiDesignSystemTheme(themeNotifier.designSystemTheme),
          ],
        ),
        home: Consumer(
          builder: (BuildContext ctx, WidgetRef ref, Widget? _) {
            final SettingsContext sctx = SettingsContext(
              context: ctx,
              appModel: ref.read(appProvider),
              ref: ref,
              readerSource: ReaderHibikiSource.instance,
              refresh: () {},
            );
            final List<SettingsDestination> all = buildSettingsSchema(sctx);
            destinations = all;
            return ValueListenableBuilder<SettingsDestination?>(
              valueListenable: destNotifier,
              builder: (_, SettingsDestination? dest, __) {
                return MaterialSettingsRenderer().buildDetailPage(
                  settingsContext: sctx,
                  destination: dest ?? all.first,
                );
              },
            );
          },
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 200));

    final Map<String, String> initial =
        Map<String, String>.from(await db.getAllPrefs());

    final FocusDriver driver = FocusDriver(tester);
    final List<ItemVerdict> verdicts = <ItemVerdict>[];
    final List<String> destFindings = <String>[];

    for (final SettingsDestination dest in destinations) {
      destNotifier.value = dest;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // 渲染该分组时可能抛多个异常（最小 harness 缺真实 AppModel 子系统状态）；
      // 全部 drain，记下第一条当发现，跳过该分组（不让残留异常判挂整测）。
      Object? renderEx;
      Object? e;
      while ((e = tester.takeException()) != null) {
        renderEx ??= e;
      }
      if (renderEx != null) {
        destFindings.add('${dest.id.name}: render threw $renderEx');
        debugPrint(
            '[schema-coverage] DEST ${dest.id.name} render FAILED: $renderEx');
        continue;
      }
      final EffectProbe? probe = probeFor(dest.id);
      final Set<FocusNode> seen = <FocusNode>{};
      final Set<String> driven = <String>{};
      int stale = 0;
      for (int step = 0; step < 400; step++) {
        final FocusNode? node = FocusManager.instance.primaryFocus;
        if (node != null && !seen.contains(node)) {
          seen.add(node);
          final _FocusedRow? row = _focusedSettingsRow();
          if (row != null && driven.add(row.title)) {
            verdicts.add(await _verifyFocusedNode(
              tester: tester,
              driver: driver,
              db: db,
              readerSettings: readerSettings,
              probe: probe,
              destId: dest.id.name,
              row: row,
            ));
          }
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump(const Duration(milliseconds: 16));
        final FocusNode? now = FocusManager.instance.primaryFocus;
        if (now == null || seen.contains(now)) {
          if (++stale > 8) break;
        } else {
          stale = 0;
        }
      }
    }

    // 全局还原：改过的 key 写回初值，测试新增的 key 删除，再校验快照一致。
    final Map<String, String> afterAll =
        Map<String, String>.from(await db.getAllPrefs());
    for (final MapEntry<String, String> e in initial.entries) {
      if (afterAll[e.key] != e.value) {
        await db.setPref(e.key, e.value);
      }
    }
    for (final String k in afterAll.keys) {
      if (!initial.containsKey(k)) {
        await db.deletePref(k);
      }
    }
    await readerSettings.refreshFromDb();
    final bool globallyRestored =
        _mapsEqual(initial, Map<String, String>.from(await db.getAllPrefs()));

    // 「Yomitan API server」开关被焦点遍历真切到 ON 时会 shelf_io.serve 绑定一个
    // 真实 HttpServer，它带一个 2 分钟 idleTimeout 周期 Timer。全局还原只写回 DB
    // pref，不会停服 → 该 Timer 残留，触发测试结束的「A Timer is still pending」
    // 断言（原 develop 基线红）。必须在**测试 body 内**（FakeAsync 区、pending-
    // timer 校验之前）停服；放 addTearDown 太晚（teardown 在 timer 校验之后跑）。
    // stopYomitanApiServer() 是 async，但调用它会**同步**求值到 HttpServer.close()
    // ——close() 在第一个 await 挂起前就同步取消了 idleTimeout Timer。故只需触发调
    // 用、不能 await 它（await 真 socket-close 的 I/O Future 在 FakeAsync 区会死锁；
    // 用 tester.runAsync 又会冲掉无关的 image-cache 真异步引出 path_provider
    // MissingPluginException）。socket 真关闭随后在真实事件循环兑现，与本断言无关。
    // 仅 Yomitan 留 Timer（texthooker/clipboard 切 ON 不留 fake Timer），故只停它。
    unawaited(appModel.stopYomitanApiServer());

    for (final ItemVerdict v in verdicts) {
      debugPrint('[schema-coverage] ${_describe(v)}');
    }
    final int changed = verdicts.where((ItemVerdict v) => v.changed).length;
    final int effect =
        verdicts.where((ItemVerdict v) => v.effectVerified).length;
    final int unverified = verdicts
        .where((ItemVerdict v) => v.changed && !v.effectVerified)
        .length;
    debugPrint('[schema-coverage] ALL destinations: rows=${verdicts.length} '
        'changed=$changed effectVerified=$effect '
        'unverified(待 T4)=$unverified globallyRestored=$globallyRestored '
        'destFindings=${destFindings.length}');
    for (final String f in destFindings) {
      debugPrint('[schema-coverage] DEST-FINDING: $f');
    }

    // 账目：每个 changed 但未 effect-verified 的设置，要么有专项探针、要么登记
    // 设备 backlog（kCoveredElsewhere），不允许静默缺口。
    final List<ItemVerdict> stillUnaccounted = verdicts
        .where((ItemVerdict v) =>
            !v.effectVerified && !kCoveredElsewhere.containsKey(v.id))
        .toList();
    for (final ItemVerdict v in stillUnaccounted) {
      debugPrint('[schema-coverage] STILL-UNACCOUNTED: ${v.id} '
          '(${v.controlType}) — 既无探针也未登记 backlog');
    }
    debugPrint('[schema-coverage] coverage accounting: '
        'effectVerified=$effect '
        'coveredElsewhere=${verdicts.where((ItemVerdict v) => !v.effectVerified && kCoveredElsewhere.containsKey(v.id)).length} '
        'stillUnaccounted=${stillUnaccounted.length}');

    expect(stillUnaccounted, isEmpty,
        reason: '每个 changed 但未 effect-verified 的设置都必须登记到 '
            'kCoveredElsewhere（专项测试或设备 backlog），不允许静默缺口。'
            '未登记: ${stillUnaccounted.map((ItemVerdict v) => v.id).join(", ")}');

    expect(destFindings, isEmpty,
        reason: '全部 8 个 destination 都应能渲染（根本性修复：测试侧 wire 全部'
            '子系统）。渲染失败: ${destFindings.join("; ")}');
    expect(verdicts.length, greaterThan(40),
        reason: '应遍历到跨全部 8 个分组的大量可操作控件（焦点可达）');
    final List<ItemVerdict> notPersisted =
        verdicts.where((ItemVerdict v) => v.changed && !v.persisted).toList();
    expect(notPersisted, isEmpty,
        reason: '改了却没写穿 DB 的控件: '
            '${notPersisted.map((ItemVerdict v) => v.id).join(", ")}');
    expect(verdicts.where((ItemVerdict v) => v.effectVerified).length,
        greaterThanOrEqualTo(8),
        reason: 'reading(T1)+appearance(T2) 应有多项被探针确认真生效');
    expect(globallyRestored, isTrue, reason: '全部设置必须能还原到初始快照');
  });
}

String _describe(ItemVerdict v) {
  final String status = v.isPass
      ? 'PASS'
      : (v.changed && !v.effectVerified ? 'UNVERIFIED' : 'FAIL');
  return '[${v.controlType}] ${v.id} reached=${v.reached} '
      'changed=${v.changed} persisted=${v.persisted} '
      'effect=${v.effectVerified} restored=${v.restored} $status'
      '${v.note.isEmpty ? "" : " — ${v.note}"}';
}

_FocusedRow? _focusedSettingsRow() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  if (ctx == null) return null;
  _FocusedRow? found;
  ctx.visitAncestorElements((Element el) {
    final Widget w = el.widget;
    if (w is AdaptiveSettingsSwitchRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.switchRow);
      return false;
    }
    if (w is AdaptiveSettingsSliderRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.slider);
      return false;
    }
    if (w is AdaptiveSettingsStepperRow) {
      found = _FocusedRow(title: w.title, kind: _RowKind.stepper);
      return false;
    }
    if (w is AdaptiveSettingsSegmentedRow) {
      found = _FocusedRow(
          title: (w as dynamic).title as String, kind: _RowKind.segmented);
      return false;
    }
    return true;
  });
  return found;
}

Future<ItemVerdict> _verifyFocusedNode({
  required WidgetTester tester,
  required FocusDriver driver,
  required HibikiDatabase db,
  required ReaderSettings readerSettings,
  required EffectProbe? probe,
  required String destId,
  required _FocusedRow row,
}) async {
  await readerSettings.refreshFromDb();
  final EffectSnapshot? effBefore = probe?.capture();
  final Map<String, String> before =
      Map<String, String>.from(await db.getAllPrefs());

  if (row.kind == _RowKind.switchRow) {
    await driver.activate();
    await tester.pump(const Duration(milliseconds: 50));
  } else {
    await driver.adjust(steps: 4);
    await tester.pump(const Duration(milliseconds: 50));
    if (_mapsEqual(before, await db.getAllPrefs())) {
      await driver.adjust(steps: -4);
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
  final Object? thrown = tester.takeException();

  final Map<String, String> after =
      Map<String, String>.from(await db.getAllPrefs());
  await readerSettings.refreshFromDb();
  final bool persisted = !_mapsEqual(before, after);
  final bool changed = persisted;

  bool effectVerified = false;
  String note = '';
  if (probe != null && effBefore != null && changed) {
    effectVerified = probe.compare(effBefore, probe.capture()).changed;
    if (!effectVerified) {
      note = 'EFFECT UNVERIFIED: ${probe.kind.name} 渲染输入无变化（多为行为类设置，待 T4）';
    }
  } else if (!changed) {
    note = 'no change observed（驱动键不对 / 控件被门控 disabled）';
  } else {
    note = 'EFFECT UNVERIFIED: 该分组暂无适用探针（待 T4 行为探针）';
  }
  if (thrown != null) {
    note = '${note.isEmpty ? "" : "$note; "}THREW: $thrown';
  }

  return ItemVerdict(
    id: '$destId/${row.title}',
    controlType: row.kind.name,
    reached: true,
    changed: changed,
    persisted: persisted,
    effectVerified: effectVerified,
    restored: true,
    note: note,
  );
}

bool _mapsEqual(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry<String, String> e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

enum _RowKind { switchRow, slider, stepper, segmented }

class _FocusedRow {
  const _FocusedRow({required this.title, required this.kind});
  final String title;
  final _RowKind kind;
}

class _CoverageAppModel extends AppModel {
  _CoverageAppModel() : super(testPlatformServices());

  final PackageInfo _packageInfo = PackageInfo(
    appName: 'Hibiki',
    packageName: 'jp.hibiki.test',
    version: '9.8.7',
    buildNumber: '654',
  );

  @override
  PackageInfo get packageInfo => _packageInfo;
}
