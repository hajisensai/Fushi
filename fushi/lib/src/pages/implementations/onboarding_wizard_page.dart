import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:fushi/pages.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankiconnect_addon_installer.dart';
import 'package:fushi_anki/fushi_anki.dart' show AnkiSettings;
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
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Anki 生态外链（Anki 步骤「先把 Anki 装起来」的出口；AnkiConnect 插件不走
/// 外链——内置包一键解压进 `addons21/`，见 [installAnkiConnectAddon]）。
const String kAnkiDesktopDownloadUrl = 'https://apps.ankiweb.net/';
const String kAnkiDroidDownloadUrl =
    'https://play.google.com/store/apps/details?id=com.ichi2.anki';

/// 推荐包下载线路：两条线路指向同一份包。Cloudflare 是默认（走稳定清单 +
/// sha256 校验），Google Drive 是备用镜像（应用内直下走 usercontent 直链，
/// 浏览器打开走分享页）。
enum _PackRoute { cloudflare, googleDrive }

/// 新手引导向导：首次启动（`onboarding_completed == false`）由 [HomePage] 首帧
/// 弹出，之后可从「设置 → 系统」重新打开。
///
/// 步骤序列由纯函数 [onboardingStepSequence] 生成：欢迎（界面语言/主题）→ 功能
/// 选择（库页模块显隐 + 要配置的能力）→ 按勾选出现的配置步骤 → 字体 → 完成。
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
  late final Directory _packDir =
      Directory(p.join(appModelNoUpdate.appDirectory.path, 'recommended_pack'));
  late final RecommendedPackDownloader _packDownloader =
      RecommendedPackDownloader(packDir: _packDir);

  /// 稳定清单解析出的下载器（URL/sha256 随清单走）；清单拉不到时保持 null，
  /// 用内置回退直链的 [_packDownloader]。
  RecommendedPackDownloader? _manifestDownloader;

  /// Google 备用镜像的下载器（懒建）。文件名沿用内置直链的包名——两条线路是
  /// 同一份包，半截文件天然可跨线路续传。
  RecommendedPackDownloader? _googleDownloader;

  /// 当前选中的下载线路（分段按钮；下载中不可切换）。
  _PackRoute _packRoute = _PackRoute.cloudflare;

  RecommendedPackDownloader get _activeDownloader {
    switch (_packRoute) {
      case _PackRoute.cloudflare:
        return _manifestDownloader ?? _packDownloader;
      case _PackRoute.googleDrive:
        return _googleDownloader ??= RecommendedPackDownloader(
          packDir: _packDir,
          url: kRecommendedPackGoogleDriveDirectUrl,
          fileName: kRecommendedPackFileName,
        );
    }
  }

  /// 浏览器下载按钮的目标：CF 用直链（清单拉到过就用清单里的最新 URL），
  /// Google 用分享页（浏览器场景让 Drive 自己处理确认页更稳）。
  String get _packBrowserUrl {
    switch (_packRoute) {
      case _PackRoute.cloudflare:
        return _manifestDownloader?.url ?? kRecommendedPackCloudflareUrl;
      case _PackRoute.googleDrive:
        return kRecommendedPackGoogleDriveUrl;
    }
  }

  final ValueNotifier<double> _packProgress = ValueNotifier<double>(0);
  final ValueNotifier<int> _packBytes = ValueNotifier<int>(0);
  CancelToken? _packCancelToken;
  bool _packDownloading = false;
  String? _packError;

  bool get _browserExtensionAvailable => DesktopLookupService.isDesktop;

  List<OnboardingStepId> get _steps => onboardingStepSequence(
        selected: _selected,
        browserExtensionAvailable: _browserExtensionAvailable,
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
    unawaited(_packDownloader.cleanupIfImported());
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
    final bool extension =
        _selected.contains(OnboardingFeature.browserExtension);
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
    await Navigator.of(context).push(
      adaptivePageRoute<void>(context: context, builder: builder),
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
      // CF 线路先拉稳定清单拿最新包地址（换包零发版）；拉不到回退内置直链。
      // 只解析一次并缓存——同一会话内 URL 抖动会打断续传。Google 线路是固定
      // 备用镜像，不走清单。
      if (_packRoute == _PackRoute.cloudflare && _manifestDownloader == null) {
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
      onImportConfirmed:
          deleteAfterImport ? _activeDownloader.markImportStarted : null,
    );
  }

  // ── Anki ──────────────────────────────────────────────────────────

  /// 是否点过「测试连接」。成功/失败反馈只在测试后显示，进入步骤不抢答。
  bool _ankiTestAttempted = false;

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
    setState(() => _ankiTestAttempted = true);
    // 与制卡设置的「刷新牌组与笔记类型」同一条路径：拉到牌组即连接成功，
    // 失败信息也复用设置页同一套本地化。
    await ref.read(ankiViewModelProvider.notifier).fetchConfiguration();
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
            style: textTheme.bodyMedium!
                .copyWith(color: theme.colorScheme.onSurfaceVariant),
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
        _ankiConfigRow(t.anki_deck, anki.settings.selectedDeckName ?? '—'),
        _ankiConfigRow(
          t.anki_note_type,
          anki.settings.selectedNoteTypeName ?? '—',
        ),
        SizedBox(height: tokens.spacing.card),
        if (_ankiTestAttempted && !anki.isFetching) ...<Widget>[
          if (connected)
            Text(
              t.onboarding_anki_test_success(
                count: anki.availableDecks.length,
              ),
              style: textTheme.bodyMedium!
                  .copyWith(color: theme.colorScheme.primary),
              textAlign: TextAlign.center,
            )
          else if (anki.errorMessage != null)
            Text(
              anki.errorMessage!,
              style:
                  textTheme.bodySmall!.copyWith(color: theme.colorScheme.error),
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
        Wrap(
          alignment: WrapAlignment.center,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FilledButton.tonalIcon(
              icon: anki.isFetching
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.link_outlined),
              label: Text(t.onboarding_anki_test_action),
              onPressed: anki.isFetching
                  ? null
                  : () => unawaited(_testAnkiConnection()),
            ),
            // 还没连上：给「先把 Anki 装起来」的出口（连上即收起；iOS 的
            // AnkiMobile 是付费 App，说明文字带过，不放商店外链）。
            if (!connected && Platform.isAndroid)
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new_outlined),
                label: Text(t.onboarding_anki_get_ankidroid_action),
                onPressed: () => launchUrl(
                  Uri.parse(kAnkiDroidDownloadUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
            if (!connected && !mobile) ...<Widget>[
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new_outlined),
                label: Text(t.onboarding_anki_get_anki_action),
                onPressed: () => launchUrl(
                  Uri.parse(kAnkiDesktopDownloadUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              // 内置插件包直接解压进 Anki 的 addons21，免去「获取插件填码」；
              // 手动路径（填码 2055492159）保留在上方说明文字里作后备。
              OutlinedButton.icon(
                icon: const Icon(Icons.extension_outlined),
                label: Text(t.onboarding_anki_install_addon_action),
                onPressed: () => unawaited(_installAnkiConnectAddonFromAsset()),
              ),
            ],
            FilledButton.tonalIcon(
              icon: const Icon(Icons.tune_outlined),
              label: Text(t.onboarding_step_anki_action),
              onPressed: () => _pushPage(
                (_) => SettingsDetailPage(
                  destination: buildCardCreationDestination(),
                ),
              ),
            ),
          ],
        ),
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
        // FSRS：没有 AnkiConnect/AnkiDroid API 能替用户打开，只能把路径讲清。
        SizedBox(height: tokens.spacing.card),
        FushiListItem(
          leading: const Icon(Icons.speed_outlined),
          title: Text(t.onboarding_anki_fsrs_title),
          subtitle: Text(t.onboarding_anki_fsrs_body),
          // 说明是三句话，不能用默认两行截断。
          subtitleMaxLines: 8,
        ),
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

    return FushiPageScaffold(
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
                    OutlinedButton(
                      onPressed: _goBack,
                      child: Text(t.back),
                    ),
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
      case OnboardingStepId.anki:
        return _buildAnkiStep();
      case OnboardingStepId.backup:
        return OnboardingStepView(
          icon: Icons.cloud_sync_outlined,
          title: t.onboarding_step_backup_title,
          body: t.onboarding_step_backup_body,
          actions: <Widget>[
            FilledButton.tonalIcon(
              icon: const Icon(Icons.settings_backup_restore_outlined),
              label: Text(t.onboarding_step_backup_action),
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
          actions: <Widget>[
            FilledButton.tonalIcon(
              icon: const Icon(Icons.hub_outlined),
              label: Text(t.onboarding_step_interconnect_action),
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
          actions: <Widget>[
            FilledButton.tonalIcon(
              icon: const Icon(Icons.open_in_new_outlined),
              label: Text(t.onboarding_step_extension_action),
              onPressed: () => _pushPage((_) => const BrowserExtensionPage()),
            ),
          ],
        );
      case OnboardingStepId.fonts:
        return OnboardingStepView(
          icon: Icons.font_download_outlined,
          title: t.onboarding_step_fonts_title,
          body: t.onboarding_step_fonts_body,
          actions: <Widget>[
            FilledButton.tonalIcon(
              icon: const Icon(Icons.font_download_outlined),
              label: Text(t.custom_fonts_catalog_title),
              onPressed: () => _pushPage((_) => const CustomFontsPage()),
            ),
          ],
        );
      case OnboardingStepId.finish:
        return OnboardingStepView(
          icon: Icons.check_circle_outline,
          title: t.onboarding_finish_title,
          body: t.onboarding_finish_body,
        );
    }
  }

  Widget _buildWelcomeStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SettingsContext settingsContext =
        createSettingsContext(appModel: appModel, ref: ref);
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
        Text(
          t.onboarding_features_modules_label,
          style: textTheme.labelLarge,
        ),
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
        Text(
          t.onboarding_features_setup_label,
          style: textTheme.labelLarge,
        ),
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

  Widget _buildPackStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool hasDownloaded = _activeDownloader.hasCompletedFile;
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        SizedBox(height: tokens.spacing.card),
        Icon(Icons.auto_stories_outlined,
            size: 56, color: theme.colorScheme.primary),
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
            style:
                textTheme.bodySmall!.copyWith(color: theme.colorScheme.error),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: tokens.spacing.gap),
        ],
        if (_packDownloading) ...<Widget>[
          ValueListenableBuilder<double>(
            valueListenable: _packProgress,
            builder: (_, double value, __) => LinearProgressIndicator(
              value: value > 0 ? value : null,
            ),
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
          // 下载线路：两条线路同一份包，应用内直下与浏览器下载都跟随此选择。
          Center(
            child: SegmentedButton<_PackRoute>(
              segments: const <ButtonSegment<_PackRoute>>[
                ButtonSegment<_PackRoute>(
                  value: _PackRoute.cloudflare,
                  label: Text('Cloudflare'),
                ),
                ButtonSegment<_PackRoute>(
                  value: _PackRoute.googleDrive,
                  label: Text('Google Drive'),
                ),
              ],
              selected: <_PackRoute>{_packRoute},
              onSelectionChanged: (Set<_PackRoute> selection) =>
                  setState(() => _packRoute = selection.first),
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: <Widget>[
              FilledButton.tonalIcon(
                icon: const Icon(Icons.download_outlined),
                label: Text(hasDownloaded
                    ? t.onboarding_step_pack_import_existing_action
                    : '${t.onboarding_step_pack_download_action}'
                        ' ($kRecommendedPackSizeLabel)'),
                onPressed: () => unawaited(_downloadPackAndImport()),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(t.onboarding_step_pack_pick_action),
                onPressed: () => unawaited(_pickPackFileAndImport()),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new_outlined),
                label: Text(t.onboarding_step_pack_browser_action),
                onPressed: () => launchUrl(
                  Uri.parse(_packBrowserUrl),
                  mode: LaunchMode.externalApplication,
                ),
              ),
              // 学其他语言 / 不想用推荐包：既有词典管理页（推荐词典目录 + 文件
              // 导入）与音频来源对话框仍是完整入口。
              TextButton(
                onPressed: () => _pushPage((_) => const DictionaryDialogPage()),
                child: Text(t.onboarding_step_dictionary_action),
              ),
              TextButton(
                onPressed: () => showAudioSourcesManagerDialog(
                  context: context,
                  appModel: appModel,
                ),
                child: Text(t.manage_audio_sources),
              ),
            ],
          ),
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
    final ColorScheme colors = Theme.of(context).colorScheme;
    return FushiListItem(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
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
class OnboardingStepView extends StatelessWidget {
  const OnboardingStepView({
    required this.icon,
    required this.title,
    required this.body,
    this.actions = const <Widget>[],
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;
  final List<Widget> actions;

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
        Text(title,
            style: textTheme.headlineSmall, textAlign: TextAlign.center),
        SizedBox(height: tokens.spacing.gap),
        Text(body, style: textTheme.bodyMedium, textAlign: TextAlign.center),
        if (actions.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: tokens.spacing.gap,
            runSpacing: tokens.spacing.gap,
            children: actions,
          ),
        ],
      ],
    );
  }
}
