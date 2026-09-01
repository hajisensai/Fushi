import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:fushi/pages.dart';
import 'package:fushi/src/anki/anki_config_controls.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankiconnect_addon_installer.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart';
import 'package:fushi/src/settings/settings_actions.dart'
    show buildLanguageSelector, buildBrightnessSelector;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart'
    show showAudioSourcesManagerDialog;
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart'
    show
        buildSyncBackupDestination,
        buildInterconnectDestination,
        runBackupImportFlowForFile;
import 'package:fushi/utils.dart';
import 'package:fushi_anki/fushi_anki.dart'
    show AnkiDeck, AnkiNoteType, AnkiSettings;
import 'package:fushi_audio/fushi_audio.dart'
    show AudiobookRepository, SrtBookRepository;
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Anki 生态外链（Anki 步骤「先把 Anki 装起来」的出口；AnkiConnect 插件不走
/// 外链——内置包一键解压进 `addons21/`，见 [installAnkiConnectAddon]）。
const String kAnkiDesktopDownloadUrl = 'https://apps.ankiweb.net/';
const String kAnkiDroidDownloadUrl =
    'https://play.google.com/store/apps/details?id=com.ichi2.anki';

/// 新手引导向导：首次启动（`onboarding_completed == false`）由 [HomePage] 首帧
/// 弹出，之后可从「设置 → 系统」重新打开。
///
/// 步骤序列由纯函数 [onboardingStepSequence] 生成：欢迎（界面语言/主题）→ 功能
/// 选择（库页模块显隐 + 要配置的能力）→ 资源准备（推荐包 / 手动补充可独立多选）→
/// 按勾选出现的配置步骤 → 字体 → 功能操作教程（点击查词 + 平台支持时的全局查词
/// + Anki 真正就绪后的第一张卡片）→ 完成。
/// 配置步骤只做说明 + 跳转到**既有**配置入口（推荐包走备份导入共享编排
/// [runBackupImportFlowForFile]；Anki/备份/互联推各自设置详情页），不复制配置
/// UI——配置能力的单一真相源仍在各自页面。向导的持久化副作用只有两个：离开功能
/// 选择步骤时写 `module_*_enabled` 显隐偏好；完成/跳过时把 `onboarding_completed`
/// 置回 true。
class OnboardingWizardPage extends BasePage {
  const OnboardingWizardPage({super.key});

  @override
  BasePageState<OnboardingWizardPage> createState() =>
      _OnboardingWizardPageState();
}

class _OnboardingWizardPageState extends BasePageState<OnboardingWizardPage>
    with SettingsContextHost<OnboardingWizardPage> {
  /// 已勾选的功能。模块项在 initState 从当前偏好播种（重开向导时反映现状）；
  /// 能力项默认勾推荐包 + Anki 制卡（查词→制卡是本应用的最大公约数，备份/
  /// 互联按需自选）。
  final Set<OnboardingFeature> _selected = <OnboardingFeature>{
    OnboardingFeature.recommendedPack,
    OnboardingFeature.anki,
  };

  int _stepIndex = 0;

  // ── 推荐包下载状态 ────────────────────────────────────────────────
  late final Directory _packDir = Directory(
    p.join(appModelNoUpdate.appDirectory.path, 'recommended_pack'),
  );

  /// 稳定清单解析出的下载器。**来源不给用户选**：清单里同时挂着 GitHub Release 的
  /// 分片、官网 CF 的同名分片，以及 Drive 整包镜像（每片按 Range 取），分片下载器
  /// 按实测吞吐在这几家之间派活——哪家快，哪家多下（见 `SourceSpeedLedger`）。
  ///
  /// 让用户在「Cloudflare / Google Drive」里二选一是个错误的问题：一次下载本来就
  /// 该同时用上所有能用的来源，而哪家当下更快，只有跑起来才知道，用户猜不出。
  RecommendedPackDownloader? _manifestDownloader;

  /// 清单彻底拉不到（官网和 GitHub 两个候选都不可达）时的兜底：内置的 Drive 整包
  /// 直链，单流下载。没有清单就没有分片表，混源无从谈起，只能退到这一条。
  late final RecommendedPackDownloader _fallbackDownloader =
      RecommendedPackDownloader(
    packDir: _packDir,
    url: kRecommendedPackGoogleDriveDirectUrl,
  );

  RecommendedPackDownloader get _activeDownloader =>
      _manifestDownloader ?? _fallbackDownloader;

  final ValueNotifier<double> _packProgress = ValueNotifier<double>(0);
  final ValueNotifier<int> _packBytes = ValueNotifier<int>(0);
  CancelToken? _packCancelToken;
  bool _packDownloading = false;
  String? _packError;

  bool get _browserExtensionAvailable => DesktopLookupService.isDesktop;

  /// 当前真正有应用外查词入口的平台。Windows 用系统级热键；Android 用系统文本
  /// 选择菜单 / 分享入口。其它平台不能因为都叫 desktop/mobile 就展示错误教程。
  bool get _globalLookupAvailable => Platform.isWindows || Platform.isAndroid;

  /// 「连接成功」与「能创建第一张卡」不是一回事：还必须从本次拉回的真实列表中
  /// 选中了仍存在的牌组和笔记类型。旧持久化 id 即使非 null，也可能已在 Anki 中
  /// 被删除，不能据此放行教程。
  bool get _ankiReadyForFirstCard {
    final AnkiUiState anki = ref.read(ankiViewModelProvider);
    return onboardingAnkiSelectionReady(
      connectionVerified: _ankiConnectionVerified,
      selectedDeckId: anki.settings.selectedDeckId,
      selectedNoteTypeId: anki.settings.selectedNoteTypeId,
      availableDeckIds: anki.availableDecks.map((AnkiDeck deck) => deck.id),
      availableNoteTypeIds:
          anki.availableNoteTypes.map((AnkiNoteType noteType) => noteType.id),
    );
  }

  List<OnboardingStepId> get _steps => onboardingStepSequence(
        selected: _selected,
        browserExtensionAvailable: _browserExtensionAvailable,
        globalLookupAvailable: _globalLookupAvailable,
        ankiReady: _ankiReadyForFirstCard,
      );

  @override
  void initState() {
    super.initState();
    if (appModelNoUpdate.moduleBooksEnabled) {
      _selected.add(OnboardingFeature.books);
    }
    if (appModelNoUpdate.moduleMangaEnabled) {
      _selected.add(OnboardingFeature.manga);
    }
    if (appModelNoUpdate.moduleVideoEnabled) {
      _selected.add(OnboardingFeature.video);
    }
    if (Platform.isWindows && appModelNoUpdate.moduleGamesEnabled) {
      _selected.add(OnboardingFeature.games);
    }
    if (_browserExtensionAvailable &&
        appModelNoUpdate.moduleBrowserExtensionEnabled) {
      _selected.add(OnboardingFeature.browserExtension);
    }
    // 上一轮推荐包导入成功后进程已重启：把落盘的 9.5 GB zip 删掉（flag 判定，
    // 未导入过 / 半截下载不受影响）。
    unawaited(RecommendedPackDownloader.cleanupIfImported(_packDir));
    // 落盘名从「URL 尾段推导」改成恒定名之前下的半截包叫 `download*`，搬过来，
    // 别让升级把已下的 9.5 GB 作废。
    RecommendedPackDownloader.migrateLegacyArtifacts(_packDir);
  }

  @override
  void dispose() {
    _packCancelToken?.cancel();
    _packProgress.dispose();
    _packBytes.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    await appModel.setOnboardingCompleted(value: true);
    if (!mounted) return;
    await Navigator.of(context).maybePop();
  }

  /// 离开功能选择步骤时，把模块勾选写进 tab 显隐偏好（只写有变化的；平台上
  /// 没提供勾选的模块不写，保留用户意愿）。
  Future<void> _applyModuleSelection() async {
    final bool books = _selected.contains(OnboardingFeature.books);
    final bool manga = _selected.contains(OnboardingFeature.manga);
    final bool video = _selected.contains(OnboardingFeature.video);
    final bool games = _selected.contains(OnboardingFeature.games);
    final bool extension = _selected.contains(
      OnboardingFeature.browserExtension,
    );
    if (appModel.moduleBooksEnabled != books) {
      await appModel.setModuleBooksEnabled(books);
    }
    if (appModel.moduleMangaEnabled != manga) {
      await appModel.setModuleMangaEnabled(manga);
    }
    if (appModel.moduleVideoEnabled != video) {
      await appModel.setModuleVideoEnabled(video);
    }
    if (Platform.isWindows && appModel.moduleGamesEnabled != games) {
      await appModel.setModuleGamesEnabled(games);
    }
    if (_browserExtensionAvailable &&
        appModel.moduleBrowserExtensionEnabled != extension) {
      await appModel.setModuleBrowserExtensionEnabled(extension);
    }
  }

  void _goNext() {
    final List<OnboardingStepId> steps = _steps;
    if (steps[_stepIndex] == OnboardingStepId.features) {
      unawaited(_applyModuleSelection());
    }
    if (_stepIndex >= steps.length - 1) {
      unawaited(_complete());
      return;
    }
    setState(() => _stepIndex += 1);
  }

  void _goBack() {
    if (_stepIndex == 0) return;
    setState(() => _stepIndex -= 1);
  }

  void _toggleFeature(OnboardingFeature feature) {
    setState(() {
      if (!_selected.remove(feature)) _selected.add(feature);
      // 勾选变化会改变步骤序列；功能选择步骤位于序列首段（index ≤ 1），后续
      // 步骤此刻尚未进入，不会越界。
    });
  }

  Future<void> _pushPage(WidgetBuilder builder) async {
    await Navigator.of(
      context,
    ).push(adaptivePageRoute<void>(context: context, builder: builder));
  }

  Future<void> _showBookAndAudiobookImport() async {
    await showAppDialog<bool>(
      context: context,
      builder: (_) => BookImportDialog(
        repo: SrtBookRepository(appModel.database),
        audiobookRepo: AudiobookRepository(appModel.database),
        db: appModel.database,
      ),
    );
  }

  void _openStandaloneLookup() {
    unawaited(
      _pushPage(
        (_) => Scaffold(
          body: SafeArea(
            child: HomeDictionaryPage(showBackButton: true),
          ),
        ),
      ),
    );
  }

  // ── 推荐包 ────────────────────────────────────────────────────────

  Future<void> _downloadPackAndImport() async {
    if (_packDownloading) return;
    setState(() {
      _packDownloading = true;
      _packError = null;
    });
    _packCancelToken = CancelToken();
    try {
      // 先拉稳定清单拿分片表与来源表（换包零发版）。只解析一次并缓存——同一会话
      // 内 URL 抖动会打断续传。拉不到就走 _fallbackDownloader 的整包直链。
      if (_manifestDownloader == null) {
        final RecommendedPackManifest? manifest =
            await fetchRecommendedPackManifest();
        if (manifest != null) {
          _manifestDownloader = RecommendedPackDownloader.fromManifest(
            packDir: _packDir,
            manifest: manifest,
          );
        }
      }
      if (!mounted) return;
      // 钉住本次下载用的下载器：导入确认回调也要落在同一实例上。
      final RecommendedPackDownloader downloader = _activeDownloader;
      final File file = await downloader.download(
        progress: _packProgress,
        receivedBytes: _packBytes,
        cancelToken: _packCancelToken,
      );
      if (!mounted) return;
      await _importPackFile(file.path, deleteAfterImport: true);
    } on DioError catch (e) {
      // 用户取消：半截文件保留，下次续传；非取消才示错。
      // （仓库钉 dio 5.1，类型名还是 `DioError`，与其余下载路径一致。）
      if (e.type != DioErrorType.cancel) {
        _packError = e.message ?? e.toString();
      }
    } catch (e) {
      _packError = e.toString();
    } finally {
      _packCancelToken = null;
      if (mounted) setState(() => _packDownloading = false);
    }
  }

  Future<void> _pickPackFileAndImport() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['zip'],
    );
    final String? path = result?.files.single.path;
    if (path == null || !mounted) return;
    // 用户自备的文件不归下载器管，导入后不删。
    await _importPackFile(path, deleteAfterImport: false);
  }

  /// 走备份导入共享编排。导入真正开始（用户已确认）后进程会重启；
  /// [deleteAfterImport] 时在确认点落 flag，重启回来由 initState 删包。
  Future<void> _importPackFile(
    String path, {
    required bool deleteAfterImport,
  }) async {
    await runBackupImportFlowForFile(
      appModel: appModel,
      filePath: path,
      // 打标是包目录级操作（写 `<包目录>/imported.flag`），与走哪条线路无关。
      onImportConfirmed: deleteAfterImport
          ? () => RecommendedPackDownloader.markImportStarted(_packDir)
          : null,
    );
  }

  // ── Anki ──────────────────────────────────────────────────────────

  /// 是否点过「测试连接」。成功/失败反馈只在测试后显示，进入步骤不抢答。
  bool _ankiTestAttempted = false;

  /// 本次向导是否真实拉取过 Anki 的牌组和笔记类型。只在 fetch 成功且两份列表
  /// 都非空时置 true；之后用户在本页选好二者，才由 [_ankiReadyForFirstCard] 放行
  /// 「第一张卡」教程。重开向导不会拿旧缓存冒充本次连接成功。
  bool _ankiConnectionVerified = false;

  /// 移动端「本机改用 AnkiConnect」次级说明的展开态（默认收起）。
  bool _mobileAnkiConnectExpanded = false;

  /// 「一键安装插件」的结果提示（装好/没找到 Anki/失败），显示在按钮区上方。
  String? _ankiAddonNotice;

  /// 把内置 AnkiConnect 插件包解压进 Anki 的 addons21（仅桌面按钮可达）。
  Future<void> _installAnkiConnectAddonFromAsset() async {
    try {
      final ByteData data = await rootBundle.load(kAnkiConnectAddonAsset);
      final AnkiConnectAddonInstallResult result =
          await installAnkiConnectAddon(
        addonZipBytes: data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        ),
      );
      if (!mounted) return;
      setState(() {
        _ankiAddonNotice = switch (result.status) {
          AnkiConnectAddonInstallStatus.installed =>
            t.onboarding_anki_addon_installed,
          AnkiConnectAddonInstallStatus.ankiDataDirNotFound =>
            t.onboarding_anki_addon_no_anki,
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(
        () => _ankiAddonNotice = t.onboarding_anki_addon_failed(message: '$e'),
      );
    }
  }

  Future<void> _testAnkiConnection() async {
    setState(() {
      _ankiTestAttempted = true;
      _ankiConnectionVerified = false;
    });
    // 与制卡设置的「刷新牌组与笔记类型」同一条路径：拉到牌组即连接成功，
    // 失败信息也复用设置页同一套本地化。
    await ref.read(ankiViewModelProvider.notifier).fetchConfiguration();
    if (!mounted) return;
    final AnkiUiState anki = ref.read(ankiViewModelProvider);
    setState(() {
      _ankiConnectionVerified = !anki.isFetching &&
          anki.errorMessage == null &&
          anki.availableDecks.isNotEmpty &&
          anki.availableNoteTypes.isNotEmpty;
    });
  }

  /// 当前 Anki 后端的展示名（与 platform_services 的编译期选择一致：桌面
  /// AnkiConnect；安卓 AnkiDroid / iOS AnkiMobile，移动端可显式改用 AnkiConnect）。
  String _ankiBackendLabel(AnkiSettings settings) {
    final bool mobile = Platform.isAndroid || Platform.isIOS;
    if (!mobile || settings.ankiConnectUsableOnMobile) {
      return 'AnkiConnect'
          '（${settings.ankiConnectHost}:${settings.ankiConnectPort}）';
    }
    return Platform.isAndroid ? 'AnkiDroid' : 'AnkiMobile';
  }

  Widget _ankiConfigRow(String label, String value) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(
            '$label：',
            style: textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: textTheme.bodyMedium,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Anki 步骤的动作表。
  ///
  /// 每条都必须回答「点了会发生什么、要不要点」——这一步的按钮最多，也最容易让人
  /// 对着一排图标发呆。必要性跟着连接状态走：没连上时「测试连接」和「装 Anki」
  /// 是必做，连上之后它降级成「刷新牌组」这种可选动作。
  List<OnboardingAction> _ankiActions({
    required AnkiUiState anki,
    required bool connected,
    required bool mobile,
  }) {
    final bool noDecks = anki.settings.availableDecks.isEmpty;
    return <OnboardingAction>[
      OnboardingAction(
        icon: noDecks ? Icons.link_outlined : Icons.sync_outlined,
        // BUG-1902：拉到牌组之后这颗按钮的实际作用就是「刷新牌组与笔记类型」
        // （调的一直是 fetchConfiguration）。继续叫「测试连接」会让用户在 Anki
        // 里新建了牌组后找不到刷新入口。
        label: noDecks ? t.onboarding_anki_test_action : t.anki_fetch,
        description: noDecks
            ? t.onboarding_anki_action_test_desc
            : t.onboarding_anki_action_refresh_desc,
        necessity: noDecks
            ? OnboardingActionNecessity.mustDo
            : OnboardingActionNecessity.optional,
        trailing: anki.isFetching
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : null,
        onPressed:
            anki.isFetching ? null : () => unawaited(_testAnkiConnection()),
      ),
      // 还没连上：给「先把 Anki 装起来」的出口（连上即收起；iOS 的 AnkiMobile 是
      // 付费 App，说明文字带过，不放商店外链）。
      if (!connected && Platform.isAndroid)
        OnboardingAction(
          icon: Icons.open_in_new_outlined,
          label: t.onboarding_anki_get_ankidroid_action,
          description: t.onboarding_anki_action_get_ankidroid_desc,
          necessity: OnboardingActionNecessity.mustDo,
          onPressed: () => launchUrl(
            Uri.parse(kAnkiDroidDownloadUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
      if (!connected && !mobile) ...<OnboardingAction>[
        OnboardingAction(
          icon: Icons.open_in_new_outlined,
          label: t.onboarding_anki_get_anki_action,
          description: t.onboarding_anki_action_get_anki_desc,
          necessity: OnboardingActionNecessity.mustDo,
          onPressed: () => launchUrl(
            Uri.parse(kAnkiDesktopDownloadUrl),
            mode: LaunchMode.externalApplication,
          ),
        ),
        // 内置插件包直接解压进 Anki 的 addons21，免去「获取插件填码」；手动路径
        // （填码 2055492159）保留在上方说明文字里作后备。
        OnboardingAction(
          icon: Icons.extension_outlined,
          label: t.onboarding_anki_install_addon_action,
          description: t.onboarding_anki_action_install_addon_desc,
          necessity: OnboardingActionNecessity.mustDo,
          onPressed: () => unawaited(_installAnkiConnectAddonFromAsset()),
        ),
      ],
      OnboardingAction(
        icon: Icons.tune_outlined,
        label: t.onboarding_step_anki_action,
        description: t.onboarding_step_anki_action_desc,
        necessity: OnboardingActionNecessity.optional,
        onPressed: () => _pushPage(
          (_) =>
              SettingsDetailPage(destination: buildCardCreationDestination()),
        ),
      ),
    ];
  }

  Widget _buildAnkiStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AnkiUiState anki = ref.watch(ankiViewModelProvider);
    final bool mobile = Platform.isAndroid || Platform.isIOS;
    final bool connected = _ankiTestAttempted &&
        !anki.isFetching &&
        anki.errorMessage == null &&
        anki.availableDecks.isNotEmpty;
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        SizedBox(height: tokens.spacing.card),
        Icon(Icons.style_outlined, size: 56, color: theme.colorScheme.primary),
        SizedBox(height: tokens.spacing.card),
        Text(
          t.onboarding_step_anki_title,
          style: textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(t.onboarding_anki_intro_body, style: textTheme.bodyMedium),
        SizedBox(height: tokens.spacing.gap),
        Text(
          Platform.isAndroid
              ? t.onboarding_anki_setup_android_hint
              : Platform.isIOS
                  ? t.onboarding_anki_setup_ios_hint
                  : t.onboarding_anki_setup_desktop_hint,
          style: textTheme.bodyMedium,
        ),
        SizedBox(height: tokens.spacing.card),
        // 当前默认配置（与制卡设置同一份 AnkiSettings 真值）。
        _ankiConfigRow(
          t.onboarding_anki_backend_label,
          _ankiBackendLabel(anki.settings),
        ),
        // BUG-1902：连上 Anki 之后就地给出「创建 Lapis 卡组 / 选牌组 / 选笔记类型」，
        // 不再只显示三行「—」逼用户跳去设置页再回来。
        //
        // 用的是与制卡设置页**同一份**共享组件（anki/anki_config_controls.dart），
        // 不是复制一份：两处显示同一份 AnkiSettings 真值、同一种行为。
        //
        // 「一键创建 Lapis 卡组」是新手最该点的那一下——它一次性把 deck + note type +
        // 字段映射三者对齐，正好消除 BUG-1900 那类「换了笔记类型但映射没跟着换 →
        // cannot create note because it is empty」的状态。
        if (anki.settings.availableDecks.isEmpty)
          // 还没拉到牌组：保持只读摘要，先引导用户点下面的「测试连接」。
          _ankiConfigRow(t.anki_deck, anki.settings.selectedDeckName ?? '—')
        else ...<Widget>[
          AnkiCreateLapisRow(
            viewModel: ref.read(ankiViewModelProvider.notifier),
            isFetching: anki.isFetching,
          ),
          AnkiDeckPickerRow(
            settings: anki.settings,
            viewModel: ref.read(ankiViewModelProvider.notifier),
          ),
          AnkiNoteTypePickerRow(
            settings: anki.settings,
            viewModel: ref.read(ankiViewModelProvider.notifier),
          ),
        ],
        if (anki.settings.availableDecks.isEmpty)
          _ankiConfigRow(
            t.anki_note_type,
            anki.settings.selectedNoteTypeName ?? '—',
          ),
        SizedBox(height: tokens.spacing.card),
        if (_ankiTestAttempted && !anki.isFetching) ...<Widget>[
          if (connected)
            Text(
              t.onboarding_anki_test_success(count: anki.availableDecks.length),
              style: textTheme.bodyMedium!.copyWith(
                color: theme.colorScheme.primary,
              ),
              textAlign: TextAlign.center,
            )
          else if (anki.errorMessage != null)
            Text(
              anki.errorMessage!,
              style: textTheme.bodySmall!.copyWith(
                color: theme.colorScheme.error,
              ),
              textAlign: TextAlign.center,
            ),
          SizedBox(height: tokens.spacing.gap),
        ],
        if (_ankiAddonNotice != null) ...<Widget>[
          Text(
            _ankiAddonNotice!,
            style: textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        for (final OnboardingAction action in _ankiActions(
          anki: anki,
          connected: connected,
          mobile: mobile,
        ))
          OnboardingActionTile(action: action),
        // 移动端次级入口：本机改用 AnkiConnect 连电脑（默认收起，配置真值仍在
        // 制卡设置，不在向导里复制表单）。
        if (mobile) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          FushiListItem(
            leading: const Icon(Icons.lan_outlined),
            title: Text(t.onboarding_anki_mobile_ankiconnect_title),
            trailing: Icon(
              _mobileAnkiConnectExpanded
                  ? Icons.expand_less
                  : Icons.expand_more,
            ),
            onTap: () => setState(
              () => _mobileAnkiConnectExpanded = !_mobileAnkiConnectExpanded,
            ),
          ),
          if (_mobileAnkiConnectExpanded)
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.card,
                vertical: tokens.spacing.gap,
              ),
              child: Text(
                t.onboarding_anki_mobile_ankiconnect_hint,
                style: textTheme.bodySmall,
              ),
            ),
        ],
      ],
    );
  }

  // ── build ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<OnboardingStepId> steps = _steps;
    final OnboardingStepId step = steps[_stepIndex];
    final bool isLast = _stepIndex == steps.length - 1;

    // 单行页头：返回按钮和标题同一行。
    //
    // 手动返回按钮与标题共用 [FushiPageHeader]；关闭自动推导，避免将来本页在可返回
    // route 中嵌套时重复插入第二个返回按钮。脚手架的 PrimaryScrollController /
    // PageScrollRegistry（手柄 LB/RB 翻页）照旧保留。
    return FushiPageScaffold(
      automaticallyImplyLeading: false,
      headerCompact: true,
      leading: BackButton(
        key: const ValueKey<String>('onboarding_back'),
        onPressed: () => Navigator.of(context).maybePop(),
      ),
      title: t.onboarding_title,
      body: Column(
        children: <Widget>[
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: _buildStep(step),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.all(tokens.spacing.card),
              child: Row(
                children: <Widget>[
                  if (!isLast)
                    TextButton(
                      onPressed: () => unawaited(_complete()),
                      child: Text(t.onboarding_action_skip),
                    ),
                  const Spacer(),
                  Text(
                    '${_stepIndex + 1} / ${steps.length}',
                    style: textTheme.labelMedium,
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  if (_stepIndex > 0)
                    OutlinedButton(onPressed: _goBack, child: Text(t.back)),
                  if (_stepIndex > 0) SizedBox(width: tokens.spacing.gap),
                  FilledButton(
                    onPressed: _goNext,
                    child: Text(
                      isLast
                          ? t.onboarding_action_finish
                          : t.onboarding_action_next,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(OnboardingStepId step) {
    switch (step) {
      case OnboardingStepId.welcome:
        return _buildWelcomeStep();
      case OnboardingStepId.features:
        return _buildFeaturesStep();
      case OnboardingStepId.recommendedPack:
        return _buildPackStep();
      case OnboardingStepId.manualResources:
        return _buildManualResourcesStep();
      case OnboardingStepId.anki:
        return _buildAnkiStep();
      case OnboardingStepId.backup:
        return OnboardingStepView(
          icon: Icons.cloud_sync_outlined,
          title: t.onboarding_step_backup_title,
          body: t.onboarding_step_backup_body,
          actions: <OnboardingAction>[
            OnboardingAction(
              icon: Icons.settings_backup_restore_outlined,
              label: t.onboarding_step_backup_action,
              description: t.onboarding_step_backup_action_desc,
              necessity: OnboardingActionNecessity.optional,
              onPressed: () => _pushPage(
                (_) => SettingsDetailPage(
                  destination: buildSyncBackupDestination(),
                ),
              ),
            ),
          ],
        );
      case OnboardingStepId.interconnect:
        return OnboardingStepView(
          icon: Icons.devices_other_outlined,
          title: t.onboarding_step_interconnect_title,
          body: t.onboarding_step_interconnect_body,
          actions: <OnboardingAction>[
            OnboardingAction(
              icon: Icons.hub_outlined,
              label: t.onboarding_step_interconnect_action,
              description: t.onboarding_step_interconnect_action_desc,
              necessity: OnboardingActionNecessity.optional,
              onPressed: () => _pushPage(
                (_) => SettingsDetailPage(
                  destination: buildInterconnectDestination(),
                ),
              ),
            ),
          ],
        );
      case OnboardingStepId.browserExtension:
        return OnboardingStepView(
          icon: Icons.extension_outlined,
          title: t.onboarding_step_extension_title,
          body: t.onboarding_step_extension_body,
          actions: <OnboardingAction>[
            OnboardingAction(
              icon: Icons.open_in_new_outlined,
              label: t.onboarding_step_extension_action,
              description: t.onboarding_step_extension_action_desc,
              necessity: OnboardingActionNecessity.recommended,
              onPressed: () => _pushPage((_) => const BrowserExtensionPage()),
            ),
          ],
        );
      case OnboardingStepId.fonts:
        return OnboardingStepView(
          icon: Icons.font_download_outlined,
          title: t.onboarding_step_fonts_title,
          body: t.onboarding_step_fonts_body,
          actions: <OnboardingAction>[
            OnboardingAction(
              icon: Icons.font_download_outlined,
              label: t.custom_fonts_catalog_title,
              description: t.onboarding_step_fonts_action_desc,
              necessity: OnboardingActionNecessity.optional,
              onPressed: () => _pushPage((_) => const CustomFontsPage()),
            ),
          ],
        );
      case OnboardingStepId.clickLookup:
        return OnboardingOperationTutorialView(
          icon: Icons.touch_app_outlined,
          title: t.onboarding_step_click_lookup_title,
          body: t.onboarding_step_click_lookup_body,
          items: <OnboardingTutorialItem>[
            OnboardingTutorialItem(
              icon: Icons.ads_click_outlined,
              title: t.onboarding_click_lookup_tap_title,
              description: t.onboarding_click_lookup_tap_body,
            ),
            OnboardingTutorialItem(
              icon: Icons.account_tree_outlined,
              title: t.onboarding_click_lookup_nested_title,
              description: t.onboarding_click_lookup_nested_body,
            ),
            OnboardingTutorialItem(
              icon: Icons.add_card_outlined,
              title: t.onboarding_click_lookup_mine_title,
              description: t.onboarding_click_lookup_mine_body,
            ),
          ],
          actions: <OnboardingAction>[
            OnboardingAction(
              icon: Icons.manage_search_outlined,
              label: t.onboarding_lookup_verify_action,
              description: t.onboarding_lookup_verify_action_desc,
              necessity: OnboardingActionNecessity.mustDo,
              onPressed: _openStandaloneLookup,
            ),
          ],
        );
      case OnboardingStepId.globalLookup:
        return _buildGlobalLookupTutorial();
      case OnboardingStepId.firstAnkiCard:
        return _buildFirstAnkiCardTutorial();
      case OnboardingStepId.finish:
        return OnboardingStepView(
          icon: Icons.check_circle_outline,
          title: t.onboarding_finish_title,
          body: t.onboarding_finish_body,
        );
    }
  }

  Widget _buildManualResourcesStep() {
    return OnboardingStepView(
      icon: Icons.build_circle_outlined,
      title: t.onboarding_step_manual_resources_title,
      body: t.onboarding_step_manual_resources_body,
      actions: <OnboardingAction>[
        OnboardingAction(
          icon: Icons.menu_book_outlined,
          label: t.onboarding_manual_dictionary_action,
          description: t.onboarding_manual_dictionary_action_desc,
          necessity: OnboardingActionNecessity.mustDo,
          onPressed: () => _pushPage((_) => const DictionaryDialogPage()),
        ),
        OnboardingAction(
          icon: Icons.headphones_outlined,
          label: t.onboarding_manual_audiobook_action,
          description: t.onboarding_manual_audiobook_action_desc,
          necessity: OnboardingActionNecessity.optional,
          onPressed: () => unawaited(_showBookAndAudiobookImport()),
        ),
        OnboardingAction(
          icon: Icons.record_voice_over_outlined,
          label: t.onboarding_manual_pronunciation_action,
          description: t.onboarding_manual_pronunciation_action_desc,
          necessity: OnboardingActionNecessity.optional,
          onPressed: () => showAudioSourcesManagerDialog(
            context: context,
            appModel: appModel,
          ),
        ),
      ],
    );
  }

  Widget _buildFirstAnkiCardTutorial() {
    return OnboardingOperationTutorialView(
      icon: Icons.add_card_outlined,
      title: t.onboarding_step_first_anki_card_title,
      body: t.onboarding_step_first_anki_card_body,
      items: <OnboardingTutorialItem>[
        OnboardingTutorialItem(
          icon: Icons.fact_check_outlined,
          title: t.onboarding_first_anki_lookup_title,
          description: t.onboarding_first_anki_lookup_body,
        ),
        OnboardingTutorialItem(
          icon: Icons.add_circle_outline,
          title: t.onboarding_first_anki_plus_title,
          description: t.onboarding_first_anki_plus_body,
        ),
        OnboardingTutorialItem(
          icon: Icons.save_outlined,
          title: t.onboarding_first_anki_save_title,
          description: t.onboarding_first_anki_save_body,
        ),
      ],
      actions: <OnboardingAction>[
        OnboardingAction(
          icon: Icons.manage_search_outlined,
          label: t.onboarding_first_anki_action,
          description: t.onboarding_first_anki_action_desc,
          necessity: OnboardingActionNecessity.mustDo,
          onPressed: _openStandaloneLookup,
        ),
      ],
    );
  }

  /// 应用外查词不是「移动端 / 桌面端各换一个快捷键」：两边由不同的系统能力
  /// 触发。Windows 注册系统级热键并抓取当前选区；Android 由 PROCESS_TEXT / SEND
  /// intent 把选中文字交给独立查词页。教程必须分别描述真实入口。
  Widget _buildGlobalLookupTutorial() {
    if (Platform.isAndroid) {
      return OnboardingOperationTutorialView(
        icon: Icons.phone_android_outlined,
        title: t.onboarding_step_global_lookup_title,
        body: t.onboarding_global_lookup_android_body,
        items: <OnboardingTutorialItem>[
          OnboardingTutorialItem(
            icon: Icons.text_fields_outlined,
            title: t.onboarding_global_lookup_android_select_title,
            description: t.onboarding_global_lookup_android_select_body,
          ),
          OnboardingTutorialItem(
            icon: Icons.open_in_new_outlined,
            title: t.onboarding_global_lookup_android_open_title,
            description: t.onboarding_global_lookup_android_open_body,
          ),
          OnboardingTutorialItem(
            icon: Icons.touch_app_outlined,
            title: t.onboarding_global_lookup_android_continue_title,
            description: t.onboarding_global_lookup_android_continue_body,
          ),
        ],
      );
    }

    return OnboardingOperationTutorialView(
      icon: Icons.keyboard_command_key_outlined,
      title: t.onboarding_step_global_lookup_title,
      body: t.onboarding_global_lookup_windows_body,
      items: <OnboardingTutorialItem>[
        OnboardingTutorialItem(
          icon: Icons.text_fields_outlined,
          title: t.onboarding_global_lookup_windows_select_title,
          description: t.onboarding_global_lookup_windows_select_body,
        ),
        OnboardingTutorialItem(
          icon: Icons.keyboard_outlined,
          title: t.onboarding_global_lookup_windows_shortcut_title,
          description: t.onboarding_global_lookup_windows_shortcut_body,
        ),
        OnboardingTutorialItem(
          icon: Icons.tune_outlined,
          title: t.onboarding_global_lookup_windows_customize_title,
          description: t.onboarding_global_lookup_windows_customize_body,
        ),
      ],
      actions: <OnboardingAction>[
        OnboardingAction(
          icon: Icons.keyboard_outlined,
          label: t.onboarding_global_lookup_windows_action,
          description: t.onboarding_global_lookup_windows_action_desc,
          necessity: OnboardingActionNecessity.optional,
          onPressed: () => _pushPage((_) => const ShortcutSettingsPage()),
        ),
      ],
    );
  }

  Widget _buildWelcomeStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SettingsContext settingsContext = createSettingsContext(
      appModel: appModel,
      ref: ref,
    );
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        SizedBox(height: tokens.spacing.gap),
        Text(t.onboarding_welcome_headline, style: textTheme.headlineSmall),
        SizedBox(height: tokens.spacing.gap),
        Text(t.onboarding_welcome_body, style: textTheme.bodyMedium),
        SizedBox(height: tokens.spacing.card),
        // 复用外观设置的行选择器（同一真相源），语言/明暗改动立即生效。
        buildLanguageSelector(settingsContext),
        SizedBox(height: tokens.spacing.gap),
        buildBrightnessSelector(settingsContext),
      ],
    );
  }

  Widget _buildFeaturesStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        SizedBox(height: tokens.spacing.gap),
        Text(t.onboarding_features_title, style: textTheme.headlineSmall),
        SizedBox(height: tokens.spacing.card),
        Text(t.onboarding_features_modules_label, style: textTheme.labelLarge),
        SizedBox(height: tokens.spacing.gap),
        for (final OnboardingFeature feature in OnboardingFeature.values)
          if (kOnboardingModuleFeatures.contains(feature) &&
              (feature != OnboardingFeature.games || Platform.isWindows) &&
              (feature != OnboardingFeature.browserExtension ||
                  _browserExtensionAvailable))
            OnboardingFeatureTile(
              icon: _featureIcon(feature),
              title: _featureTitle(feature),
              subtitle: _featureHint(feature),
              selected: _selected.contains(feature),
              onToggle: () => _toggleFeature(feature),
            ),
        SizedBox(height: tokens.spacing.card),
        Text(t.onboarding_features_setup_label, style: textTheme.labelLarge),
        SizedBox(height: tokens.spacing.gap),
        for (final OnboardingFeature feature in OnboardingFeature.values)
          if (!kOnboardingModuleFeatures.contains(feature))
            OnboardingFeatureTile(
              icon: _featureIcon(feature),
              title: _featureTitle(feature),
              subtitle: _featureHint(feature),
              selected: _selected.contains(feature),
              onToggle: () => _toggleFeature(feature),
            ),
      ],
    );
  }

  /// 推荐包步骤的动作表。
  ///
  /// 这一步同屏五个入口，光看标签分不出「必须点哪个、点了会发生什么」——所以每条
  /// 都带一句说明和一个必要性徽标。只有第一条是主线，其余四条都是「不想下整包」
  /// 或「学别的语言」时的替代路径。
  List<OnboardingAction> _packActions(bool hasDownloaded) {
    return <OnboardingAction>[
      OnboardingAction(
        icon: Icons.download_outlined,
        label: hasDownloaded
            ? t.onboarding_step_pack_import_existing_action
            : '${t.onboarding_step_pack_download_action}'
                ' ($kRecommendedPackSizeLabel)',
        description: hasDownloaded
            ? t.onboarding_pack_action_import_existing_desc
            : t.onboarding_pack_action_download_desc,
        necessity: OnboardingActionNecessity.recommended,
        onPressed: () => unawaited(_downloadPackAndImport()),
      ),
      OnboardingAction(
        icon: Icons.folder_open_outlined,
        label: t.onboarding_step_pack_pick_action,
        description: t.onboarding_pack_action_pick_desc,
        necessity: OnboardingActionNecessity.optional,
        onPressed: () => unawaited(_pickPackFileAndImport()),
      ),
      // 浏览器下载不再直接甩一条 9.5 GB 的裸直链：官网下载页上有分片直链
      // （IDM / aria2 能用）、整包镜像和「导入方式选合并」的说明，比一条直链
      // 更能让人下完之后知道下一步干什么。
      OnboardingAction(
        icon: Icons.open_in_new_outlined,
        label: t.onboarding_pack_action_website,
        description: t.onboarding_pack_action_website_desc,
        necessity: OnboardingActionNecessity.optional,
        onPressed: () => unawaited(openOfficialDownloadPage()),
      ),
      // 学其他语言 / 不想用推荐包：既有词典管理页（推荐词典目录 + 文件导入）
      // 与音频来源对话框仍是完整入口。
      OnboardingAction(
        icon: Icons.menu_book_outlined,
        label: t.onboarding_step_dictionary_action,
        description: t.onboarding_pack_action_dictionary_desc,
        necessity: OnboardingActionNecessity.optional,
        onPressed: () => _pushPage((_) => const DictionaryDialogPage()),
      ),
      OnboardingAction(
        icon: Icons.record_voice_over_outlined,
        label: t.manage_audio_sources,
        description: t.onboarding_pack_action_audio_desc,
        necessity: OnboardingActionNecessity.optional,
        onPressed: () =>
            showAudioSourcesManagerDialog(context: context, appModel: appModel),
      ),
    ];
  }

  Widget _buildPackStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 「下好了没」是包目录的属性，不是某条线路的属性：两条线路落同一个文件名。
    final bool hasDownloaded = RecommendedPackDownloader.hasCompletedFileIn(
      _packDir,
    );
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        SizedBox(height: tokens.spacing.card),
        Icon(
          Icons.auto_stories_outlined,
          size: 56,
          color: theme.colorScheme.primary,
        ),
        SizedBox(height: tokens.spacing.card),
        Text(
          t.onboarding_step_pack_title,
          style: textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(
          t.onboarding_step_pack_body,
          style: textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: tokens.spacing.card),
        if (_packError != null) ...<Widget>[
          Text(
            t.onboarding_pack_download_failed(message: _packError!),
            style: textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.error,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        if (_packDownloading) ...<Widget>[
          ValueListenableBuilder<double>(
            valueListenable: _packProgress,
            builder: (_, double value, __) =>
                LinearProgressIndicator(value: value > 0 ? value : null),
          ),
          SizedBox(height: tokens.spacing.gap),
          ValueListenableBuilder<int>(
            valueListenable: _packBytes,
            builder: (_, int bytes, __) => Text(
              '${t.onboarding_pack_downloading} · '
              '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB',
              style: textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          Center(
            child: OutlinedButton(
              onPressed: () => _packCancelToken?.cancel(),
              child: Text(t.dialog_cancel),
            ),
          ),
        ] else ...<Widget>[
          // 来源不给用户选：清单里挂着 GitHub 分片、官网 CF 分片和备用整包镜像，
          // 下载器按实测吞吐自己派活。用户猜不出哪家当下更快，也不该被要求去猜。
          Text(
            t.onboarding_pack_sources_hint,
            style: textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          SizedBox(height: tokens.spacing.card),
          for (final OnboardingAction action in _packActions(hasDownloaded))
            OnboardingActionTile(action: action),
        ],
      ],
    );
  }

  IconData _featureIcon(OnboardingFeature feature) {
    switch (feature) {
      case OnboardingFeature.books:
        return Icons.menu_book_outlined;
      case OnboardingFeature.browserExtension:
        return Icons.extension_outlined;
      case OnboardingFeature.manga:
        return Icons.photo_library_outlined;
      case OnboardingFeature.video:
        return Icons.smart_display_outlined;
      case OnboardingFeature.games:
        return Icons.videogame_asset_outlined;
      case OnboardingFeature.recommendedPack:
        return Icons.auto_stories_outlined;
      case OnboardingFeature.manualResources:
        return Icons.build_circle_outlined;
      case OnboardingFeature.anki:
        return Icons.style_outlined;
      case OnboardingFeature.backup:
        return Icons.cloud_sync_outlined;
      case OnboardingFeature.interconnect:
        return Icons.devices_other_outlined;
    }
  }

  String _featureTitle(OnboardingFeature feature) {
    switch (feature) {
      case OnboardingFeature.books:
        return t.onboarding_feature_books;
      case OnboardingFeature.browserExtension:
        return t.module_extension_label;
      case OnboardingFeature.manga:
        return t.onboarding_feature_manga;
      case OnboardingFeature.video:
        return t.onboarding_feature_video;
      case OnboardingFeature.games:
        return t.onboarding_feature_games;
      case OnboardingFeature.recommendedPack:
        return t.onboarding_feature_pack;
      case OnboardingFeature.manualResources:
        return t.onboarding_feature_manual_resources;
      case OnboardingFeature.anki:
        return t.onboarding_feature_anki;
      case OnboardingFeature.backup:
        return t.onboarding_feature_backup;
      case OnboardingFeature.interconnect:
        return t.onboarding_feature_interconnect;
    }
  }

  String _featureHint(OnboardingFeature feature) {
    switch (feature) {
      case OnboardingFeature.books:
        return t.onboarding_feature_books_hint;
      case OnboardingFeature.browserExtension:
        return t.onboarding_feature_extension_hint;
      case OnboardingFeature.manga:
        return t.onboarding_feature_manga_hint;
      case OnboardingFeature.video:
        return t.onboarding_feature_video_hint;
      case OnboardingFeature.games:
        return t.onboarding_feature_games_hint;
      case OnboardingFeature.recommendedPack:
        return t.onboarding_feature_pack_hint;
      case OnboardingFeature.manualResources:
        return t.onboarding_feature_manual_resources_hint;
      case OnboardingFeature.anki:
        return t.onboarding_feature_anki_hint;
      case OnboardingFeature.backup:
        return t.onboarding_feature_backup_hint;
      case OnboardingFeature.interconnect:
        return t.onboarding_feature_interconnect_hint;
    }
  }
}

/// 功能选择步骤里的勾选行：共享 MD3 列表组件 + 明确的勾选态图标。
/// 独立成公开 widget 便于脱离 [AppModel] 做 widget 测试。
class OnboardingFeatureTile extends StatelessWidget {
  const OnboardingFeatureTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onToggle,
    super.key,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiListItem(
      leading: Icon(icon),
      // FushiListItem 的通用 selected 样式会把标题 / 副标题分别加粗到 700 / 600。
      // 部分中文字体的不同字重有不同垂直度量，勾选后整行因此会轻微长高。功能选择
      // 已有底色、描边和勾选图标三重反馈，这里固定文字字重，让同一内容的选中 / 未
      // 选中状态保持完全等高；只覆盖 weight，选中态前景色仍由父级 DefaultTextStyle
      // 提供。
      title: Text(
        title,
        style: TextStyle(fontWeight: tokens.type.listTitle.fontWeight),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontWeight: tokens.type.listSubtitle.fontWeight),
      ),
      selected: selected,
      selectedShape: FushiListItemSelectedShape.pill,
      trailing: Icon(
        selected ? Icons.check_circle : Icons.radio_button_unchecked,
        color: selected ? colors.primary : colors.outline,
      ),
      onTap: onToggle,
    );
  }
}

/// 单个配置步骤的静态内容骨架（图标 + 标题 + 说明 + 动作按钮）。
/// 独立成公开 widget 便于脱离 [AppModel] 做 widget 测试。
/// 引导动作的「我要不要点」。
///
/// 用户盯着一屏按钮时的第一个问题不是「这是什么」，而是「我该不该点」。所以必要性
/// 和说明文字一样是 [OnboardingAction] 的**必填**字段，而不是某些按钮碰巧带上的
/// 装饰——结构上填不了「没说明的按钮」，才不会再长出一排看不懂的图标。
enum OnboardingActionNecessity {
  /// 不点这一步就走不通（例：还没连上 Anki 时的「测试连接」「安装 Anki」）。
  mustDo,

  /// 多数人应该点（例：推荐包的「下载并导入」）。
  recommended,

  /// 按需，跳过没有副作用（例：「打开词典管理」）。
  optional,
}

/// 引导里的一个可执行动作：图标 + 标题 + **一句「点了会发生什么」** + 必要性。
@immutable
class OnboardingAction {
  const OnboardingAction({
    required this.icon,
    required this.label,
    required this.description,
    required this.necessity,
    required this.onPressed,
    this.trailing,
  });

  final IconData icon;
  final String label;

  /// 点下去会发生什么。**不能省**：省掉它就退回「一排不知道干什么的按钮」。
  final String description;

  final OnboardingActionNecessity necessity;

  /// null 表示当前不可点（例：正在拉取牌组时的刷新）。
  final VoidCallback? onPressed;

  /// 行尾附加件（进度圈等）。
  final Widget? trailing;
}

/// 必要性徽标的两份取值：词 + 底色。**词**才是承载信息的那个——单色屏和色觉障碍
/// 下也读得出「必做」还是「可选」，颜色只是加强。
class _NecessityStyle {
  const _NecessityStyle(this.label, this.color);

  final String label;

  /// null = 中性底（[FushiTagChip] 的默认 overlay 面），给「可选」用。
  final Color? color;
}

_NecessityStyle _necessityStyle(
  OnboardingActionNecessity necessity,
  ColorScheme colors,
) {
  switch (necessity) {
    case OnboardingActionNecessity.mustDo:
      return _NecessityStyle(
        t.onboarding_action_badge_required,
        colors.errorContainer,
      );
    case OnboardingActionNecessity.recommended:
      return _NecessityStyle(
        t.onboarding_action_badge_recommended,
        colors.primaryContainer,
      );
    case OnboardingActionNecessity.optional:
      return _NecessityStyle(t.onboarding_action_badge_optional, null);
  }
}

/// 「必做 / 推荐 / 可选」徽标。走共享的 [FushiTagChip]（圆角、字号、前景对比度都
/// 由它统一算），不自己搭 Container + BoxDecoration。
class OnboardingNecessityBadge extends StatelessWidget {
  const OnboardingNecessityBadge({required this.necessity, super.key});

  final OnboardingActionNecessity necessity;

  @override
  Widget build(BuildContext context) {
    final _NecessityStyle style = _necessityStyle(
      necessity,
      Theme.of(context).colorScheme,
    );
    return FushiTagChip(label: style.label, color: style.color);
  }
}

/// 渲染一条 [OnboardingAction]：整行可点，标题右边挂必要性徽标，副标题是说明。
class OnboardingActionTile extends StatelessWidget {
  const OnboardingActionTile({required this.action, super.key});

  final OnboardingAction action;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final bool enabled = action.onPressed != null;
    return FushiListItem(
      leading: Icon(
        action.icon,
        color: enabled ? theme.colorScheme.primary : theme.disabledColor,
      ),
      title: Row(
        children: <Widget>[
          Flexible(child: Text(action.label, overflow: TextOverflow.ellipsis)),
          SizedBox(width: tokens.spacing.gap / 2),
          OnboardingNecessityBadge(necessity: action.necessity),
        ],
      ),
      // 说明是完整的一两句话，默认两行会截断。
      subtitle: Text(action.description),
      subtitleMaxLines: 5,
      trailing: action.trailing,
      onTap: action.onPressed,
    );
  }
}

class OnboardingStepView extends StatelessWidget {
  const OnboardingStepView({
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const <OnboardingAction>[],
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;

  /// 本步的可执行动作。类型是 [OnboardingAction] 而不是裸 [Widget]：说明和必要性
  /// 因此是**结构上必填**的，而不是某些按钮碰巧带上的东西。
  final List<OnboardingAction> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        SizedBox(height: tokens.spacing.card),
        Icon(icon, size: 56, color: colors.primary),
        SizedBox(height: tokens.spacing.card),
        Text(
          title,
          style: textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(body, style: textTheme.bodyMedium, textAlign: TextAlign.center),
        if (actions.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          for (final OnboardingAction action in actions)
            OnboardingActionTile(action: action),
        ],
      ],
    );
  }
}

/// 功能操作教程的一条动作：用图标帮助扫读，标题说「做什么」，说明说「怎么做」。
@immutable
class OnboardingTutorialItem {
  const OnboardingTutorialItem({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;
}

/// 功能操作教程页面。与配置步骤的 [OnboardingStepView] 分开：配置页强调按钮的
/// 必要性，操作页强调有顺序的「先做什么、再做什么」，不能用一排可选按钮冒充教程。
class OnboardingOperationTutorialView extends StatelessWidget {
  const OnboardingOperationTutorialView({
    required this.icon,
    required this.title,
    required this.body,
    required this.items,
    this.actions = const <OnboardingAction>[],
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<OnboardingTutorialItem> items;
  final List<OnboardingAction> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final TextTheme textTheme = Theme.of(context).textTheme;
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        SizedBox(height: tokens.spacing.card),
        Icon(icon, size: 56, color: colors.primary),
        SizedBox(height: tokens.spacing.card),
        Text(
          title,
          style: textTheme.headlineSmall,
          textAlign: TextAlign.center,
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(body, style: textTheme.bodyMedium, textAlign: TextAlign.center),
        SizedBox(height: tokens.spacing.card),
        for (int index = 0; index < items.length; index++)
          FushiListItem(
            leading: Badge(
              label: Text('${index + 1}'),
              child: Icon(items[index].icon),
            ),
            title: Text(items[index].title),
            subtitle: Text(items[index].description),
            subtitleMaxLines: 5,
          ),
        if (actions.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          for (final OnboardingAction action in actions)
            OnboardingActionTile(action: action),
        ],
      ],
    );
  }
}
