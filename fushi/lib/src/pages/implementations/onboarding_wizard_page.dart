import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:fushi/pages.dart';
import 'package:fushi/src/anki/anki_config_controls.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/anki/ankiconnect_addon_installer.dart';
import 'package:fushi/src/media/audiobook/book_import_dialog.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/onboarding/onboarding_sample_text.dart';
import 'package:fushi/src/onboarding/onboarding_steps.dart';
import 'package:fushi/src/onboarding/recommended_pack.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/settings/settings_actions.dart'
    show buildLanguageSelector, buildBrightnessSelector;
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_schema_card_creation.dart';
import 'package:fushi/src/settings/settings_schema_lookup.dart'
    show showAudioSourcesManagerDialog;
import 'package:fushi/src/shortcuts/input_binding.dart'
    show InputBinding, ShortcutBindingSet;
import 'package:fushi/src/shortcuts/shortcut_action.dart' show ShortcutAction;
import 'package:fushi/src/shortcuts/visual/key_cap_widget.dart';
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
import 'package:fushi_dictionary/fushi_dictionary.dart' show Dictionary;
import 'package:url_launcher/url_launcher.dart';

/// Anki 生态外链（Anki 步骤「先把 Anki 装起来」的出口；AnkiConnect 插件不走
/// 外链——内置包一键解压进 `addons21/`，见 [installAnkiConnectAddon]）。
const String kAnkiDesktopDownloadUrl = 'https://apps.ankiweb.net/';
const String kAnkiDroidDownloadUrl =
    'https://play.google.com/store/apps/details?id=com.ichi2.anki';

/// 「在 Anki 里开启 FSRS」教程的三步。
///
/// Anki 自 23.10 起内置 FSRS，但排程默认仍是三十多年前的 SM-2：开关必须用户自己
/// 在 Anki 的牌组选项里打开一次，应用侧代劳不了——AnkiConnect 没有 FSRS 开关
/// API，绕过它直接改 collection config 会在 Anki 版本之间碎掉。所以引导把步骤整段
/// 写在这里，而不是甩一条外链让用户自己找。
///
/// 第一步的入口桌面与移动端不同（牌组齿轮菜单 vs 长按牌组），其余两步各端一致。
List<OnboardingTutorialItem> ankiFsrsTutorialSteps({required bool mobile}) =>
    <OnboardingTutorialItem>[
      OnboardingTutorialItem(
        icon: Icons.settings_outlined,
        title: t.onboarding_anki_fsrs_step_options_title,
        description: mobile
            ? t.onboarding_anki_fsrs_step_options_mobile_desc
            : t.onboarding_anki_fsrs_step_options_desktop_desc,
      ),
      OnboardingTutorialItem(
        icon: Icons.toggle_on_outlined,
        title: t.onboarding_anki_fsrs_step_toggle_title,
        description: t.onboarding_anki_fsrs_step_toggle_desc,
      ),
      OnboardingTutorialItem(
        icon: Icons.auto_graph_outlined,
        title: t.onboarding_anki_fsrs_step_optimize_title,
        description: t.onboarding_anki_fsrs_step_optimize_desc,
      ),
    ];

/// 步骤内容区最大宽度：桌面宽窗口下正文行长过长会难读，卡片也会被拉成长条。
const double _kOnboardingContentMaxWidth = 720;

/// 功能选择页在多宽以上排两列。
const double _kOnboardingTwoColumnMinWidth = 560;

/// 新手引导向导：首次启动（`onboarding_completed == false`）由 [HomePage] 首帧
/// 弹出，之后可从「设置 → 系统」重新打开。
///
/// 步骤序列由纯函数 [onboardingStepSequence] 生成：欢迎（界面语言/主题）→ 功能
/// 选择（库页模块显隐 + 要配置的能力）→ 资源准备（推荐包 / 自备资源可独立多选）→
/// 按勾选出现的配置步骤（含字体）→ 功能操作教程（点击查词 + 平台支持时的全局
/// 查词 + Anki 真正就绪后的第一张卡片）→ 完成。
/// 配置步骤只做说明 + 跳转到**既有**配置入口（推荐包走备份导入共享编排
/// [runBackupImportFlowForFile]；Anki/备份/互联推各自设置详情页），不复制配置
/// UI——配置能力的单一真相源仍在各自页面。向导的持久化副作用只有两个：离开功能
/// 选择步骤时写 `module_*_enabled` 显隐偏好；完成/跳过时把 `onboarding_completed`
/// 置回 true。
///
/// 页面骨架：页头下方一条分段进度条（[OnboardingProgressBar]）；每步以左对齐的
/// [OnboardingStepHero]（图标 + 标题 + 一句话）开头；动作走 [OnboardingActionList]
/// ——必做/推荐的动作直接摊开，可选动作收进「其他方式」折叠组，避免一屏五个入口。
class OnboardingWizardPage extends BasePage {
  const OnboardingWizardPage({super.key});

  @override
  BasePageState<OnboardingWizardPage> createState() =>
      _OnboardingWizardPageState();
}

class _OnboardingWizardPageState extends BasePageState<OnboardingWizardPage>
    with SettingsContextHost<OnboardingWizardPage> {
  /// 已勾选的功能。模块项在 initState 从当前偏好播种（重开向导时反映现状）；
  /// 能力项默认勾推荐包 + Anki 制卡 + 字体（查词→制卡是本应用的最大公约数，
  /// 字体是几乎所有人都会碰的一步；备份/互联按需自选）。
  final Set<OnboardingFeature> _selected = <OnboardingFeature>{
    OnboardingFeature.recommendedPack,
    OnboardingFeature.anki,
    OnboardingFeature.fonts,
  };

  int _stepIndex = 0;

  // ── 推荐包下载 ────────────────────────────────────────────────────
  /// 下载任务的所有权在 [AppModel] 上的 controller 里，本页只是它的一个视图：
  /// 走下一步、关掉向导都不再取消下载（BUG-2097）。来源同样不给用户选——清单里
  /// 挂着 GitHub Release 分片、官网 CF 同名分片和 Drive 整包镜像，下载器按实测
  /// 吞吐自己派活（见 `SourceSpeedLedger`）。
  RecommendedPackDownloadController get _packController =>
      appModelNoUpdate.recommendedPackDownloadController;

  /// BUG-2107：本地包「选择文件」的重入守卫。设置页那条导入本来就有
  /// （`_BackupImportWidget._isImporting`），引导这条漏了 —— 连点两次会撞
  /// file_picker 的 `already_active`，而异常在 `unawaited(...)` 里静默漂走。
  ///
  /// 选文件**不归 controller 管**：controller 持有的是那条跨页存活的下载任务
  /// （BUG-2097），而选文件是本页当场发起、当场结束的一次交互。
  bool _packPicking = false;

  /// 选文件路径的可见失败原因（**已组好的整句用户文案**）。
  ///
  /// 与下载失败分开存：controller 的 `error` 存的是裸消息、显示时才套
  /// `onboarding_pack_download_failed` 模板；选文件失败是另一条路径、另一套文案
  /// （BUG-2107），套那个模板会把「没拿到路径」说成「下载失败」。
  String? _packPickError;

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
      availableNoteTypeIds: anki.availableNoteTypes.map(
        (AnkiNoteType noteType) => noteType.id,
      ),
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
    // 包目录进场收尾（删已导入的残包、搬旧命名的半截文件、按磁盘对齐阶段）。
    // 下载正在跑时 controller 整体跳过——那些都是在动同一批文件。
    unawaited(_packController.prepareDiskState());
  }

  // dispose 里**没有**取消下载：BUG-2097 的根因就是这里曾经有一句
  // `_packCancelToken?.cancel()`，于是走完向导 = 9.5 GB 的下载被静默掐断。
  // 进度/取消/导入现在都由 [RecommendedPackDownloadController] 持有。

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

  /// 打开独立查词页；[query] 非空时把它当作用户输入立即查一次（练习句子整句进
  /// 源文本条，用户在真实查词面板里点词）。
  void _openStandaloneLookup({String? query}) {
    unawaited(
      _pushPage(
        (_) => Scaffold(
          body: SafeArea(
            child: HomeDictionaryPage(
              showBackButton: true,
              initialQuery: query,
            ),
          ),
        ),
      ),
    );
  }

  /// 查词教程用的练习句子：按已安装词典的词头语言挑，没有就按推荐包（日语）/
  /// 英语兜底。见 [onboardingSampleSentence]。
  String get _sampleSentence => onboardingSampleSentence(
        dictionarySourceLanguages: appModel.dictionaries.map(
          (Dictionary dictionary) => dictionary.effectiveSourceLanguage,
        ),
        recommendedPackSelected: _selected.contains(
          OnboardingFeature.recommendedPack,
        ),
      );

  /// 练习句子卡 + 点它就进查词页，两处查词教程共用。
  Widget _sampleSentencePreface() {
    final String sentence = _sampleSentence;
    return OnboardingSampleSentenceCard(
      sentence: sentence,
      onTap: () => _openStandaloneLookup(query: sentence),
    );
  }

  // ── 推荐包 ────────────────────────────────────────────────────────

  /// 下载 → 下完就地导入。下载本身在 controller 里跑完（取消/失败提示也在那边），
  /// 本页只负责「我还在的话，顺手把导入接上」：向导已经关了就停在「已下载待导入」，
  /// 由设置 → 系统里那一行接手（BUG-2097）。
  Future<void> _downloadPackAndImport() async {
    // 上一次「选文件」的失败文案不该压住这次下载的状态。
    if (_packPickError != null) setState(() => _packPickError = null);
    final File? file = await _packController.start();
    if (file == null || !mounted) return;
    await _importPackFile(file.path, deleteAfterImport: true);
  }

  /// 选一个已经下载好的包文件（备份 zip）并导入。
  ///
  /// BUG-2107：原先是全 app 仅剩的几处裸 `FilePicker.platform.pickFiles()` 之一，而它
  /// 承载的恰是**体积最大**的文件（推荐包 [kRecommendedPackSizeLabel] = 9.5 GB）。安卓上
  /// file_picker 会先把整份文件同步复制进 app cache 再返回缓存路径 → 需要约 2 倍包体积的
  /// 内部存储、几分钟没有任何 UI 反馈；失败时 `path == null` 与「用户取消」同形被静默
  /// 丢弃，`PlatformException` 又被调用点的 `unawaited(...)` 吞掉 —— 用户看到的就是
  /// 「点了『导入文件』没有任何提醒」。改走 [pickRealFilePathDetailed]（安卓解析真实路径、
  /// 零复制；BUG-1667 后其余大文件入口都已统一到它），并把三种结果分开：
  ///   * 返回 null = 用户取消 → 静默（取消不是失败）；
  ///   * [PickedFileWithoutPathException] = 平台交回条目却没给路径 → **可见失败**（BUG-446）；
  ///   * 其它异常 → 可见失败 + 诊断日志。
  Future<void> _pickPackFileAndImport() async {
    if (_packPicking || _packController.isDownloading) return;
    setState(() {
      _packPicking = true;
      _packPickError = null;
    });
    try {
      final PickedFilePath? picked = await pickRealFilePathDetailed(
        context: context,
        appModel: appModel,
        allowedExtensions: <String>{'zip'},
      );
      // 用户取消：静默返回（不是失败，不写 _packPickError）。
      if (picked == null) return;
      if (!mounted) return;
      // 用户自备的文件不归下载器管，导入后不删。
      await _importPackFile(picked.path, deleteAfterImport: false);
    } on PickedFileWithoutPathException catch (e) {
      ErrorLogService.instance.log(
        'OnboardingWizard.pickPackFile',
        'unexpected file selection: count=${e.count}, pathNull=true',
      );
      _packPickError = t.onboarding_pack_pick_no_path;
    } catch (e) {
      ErrorLogService.instance.log(
        'OnboardingWizard.pickPackFile',
        'pack file pick failed: $e',
      );
      _packPickError = t.onboarding_pack_pick_failed(message: e.toString());
    } finally {
      if (mounted) setState(() => _packPicking = false);
    }
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
      onImportConfirmed:
          deleteAfterImport ? _packController.markImportStarted : null,
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

  /// 「一键安装插件」的结果提示（装好/没找到 Anki/失败），显示在状态卡下方。
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

  /// 状态卡里的一行「标签 … 值」。
  Widget _ankiConfigRow(String label, String value) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
      child: Row(
        children: <Widget>[
          Text(
            label,
            style: textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Text(
              value,
              style: textTheme.bodyMedium,
              textAlign: TextAlign.end,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Anki 步骤的动作表。
  ///
  /// 每条都必须回答「点了会发生什么、要不要点」。必要性跟着连接状态走：没连上时
  /// 「测试连接」和「装 Anki」是必做，连上之后它降级成「刷新牌组」这种可选动作。
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

  /// 状态卡底部那一行：没测过 / 拉取中 / 连上了 / 出错。
  Widget _ankiStatusLine(AnkiUiState anki, {required bool connected}) {
    final ColorScheme colors = theme.colorScheme;
    if (anki.isFetching) {
      return Row(
        children: <Widget>[
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          SizedBox(width: FushiDesignTokens.of(context).spacing.gap),
          Text(t.anki_fetch, style: textTheme.bodySmall),
        ],
      );
    }
    if (!_ankiTestAttempted) {
      return Text(
        t.onboarding_anki_status_pending,
        style: textTheme.bodySmall!.copyWith(color: colors.onSurfaceVariant),
      );
    }
    if (connected) {
      return Row(
        children: <Widget>[
          Icon(Icons.check_circle_outline, size: 16, color: colors.primary),
          SizedBox(width: FushiDesignTokens.of(context).spacing.gap / 2),
          Expanded(
            child: Text(
              t.onboarding_anki_test_success(count: anki.availableDecks.length),
              style: textTheme.bodySmall!.copyWith(color: colors.primary),
            ),
          ),
        ],
      );
    }
    return Text(
      anki.errorMessage ?? '',
      style: textTheme.bodySmall!.copyWith(color: colors.error),
    );
  }

  Widget _buildAnkiStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final AnkiUiState anki = ref.watch(ankiViewModelProvider);
    final bool mobile = Platform.isAndroid || Platform.isIOS;
    final List<OnboardingTutorialItem> fsrsSteps = ankiFsrsTutorialSteps(
      mobile: mobile,
    );
    final bool connected = _ankiTestAttempted &&
        !anki.isFetching &&
        anki.errorMessage == null &&
        anki.availableDecks.isNotEmpty;
    final String platformHint = Platform.isAndroid
        ? t.onboarding_anki_setup_android_hint
        : Platform.isIOS
            ? t.onboarding_anki_setup_ios_hint
            : t.onboarding_anki_setup_desktop_hint;
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        OnboardingStepHero(
          icon: Icons.style_outlined,
          title: t.onboarding_step_anki_title,
          body: t.onboarding_anki_intro_body,
        ),
        SizedBox(height: tokens.spacing.gap),
        Text(platformHint, style: textTheme.bodyMedium),
        SizedBox(height: tokens.spacing.card),
        // 当前配置一张卡（与制卡设置同一份 AnkiSettings 真值）。
        // BUG-1902：连上 Anki 之后就地给出「创建 Lapis 卡组 / 选牌组 / 选笔记类型」，
        // 用的是与制卡设置页**同一份**共享组件（anki/anki_config_controls.dart），
        // 不是复制一份。「一键创建 Lapis 卡组」一次性把 deck + note type + 字段映射
        // 三者对齐，消除 BUG-1900 那类「换了笔记类型但映射没跟着换」的状态。
        FushiCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _ankiConfigRow(
                t.onboarding_anki_backend_label,
                _ankiBackendLabel(anki.settings),
              ),
              if (anki.settings.availableDecks.isEmpty) ...<Widget>[
                // 还没拉到牌组：只读摘要，先引导用户点下面的「测试连接」。
                _ankiConfigRow(
                  t.anki_deck,
                  anki.settings.selectedDeckName ?? '—',
                ),
                _ankiConfigRow(
                  t.anki_note_type,
                  anki.settings.selectedNoteTypeName ?? '—',
                ),
              ] else ...<Widget>[
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
              SizedBox(height: tokens.spacing.gap),
              _ankiStatusLine(anki, connected: connected),
            ],
          ),
        ),
        if (_ankiAddonNotice != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          Text(_ankiAddonNotice!, style: textTheme.bodySmall),
        ],
        SizedBox(height: tokens.spacing.card),
        OnboardingActionList(
          actions: _ankiActions(
            anki: anki,
            connected: connected,
            mobile: mobile,
          ),
        ),
        // 「去 Anki 里把 FSRS 打开」的整段教程（见 [ankiFsrsTutorialSteps]）。
        // 常显、不折叠：Anki 默认排程还是 SM-2，收起来等于没说。
        SizedBox(height: tokens.spacing.card),
        OnboardingSectionLabel(
          title: t.onboarding_anki_fsrs_title,
          hint: t.onboarding_anki_fsrs_body,
        ),
        SizedBox(height: tokens.spacing.gap),
        for (int index = 0; index < fsrsSteps.length; index++)
          OnboardingTutorialStep(
            number: index + 1,
            item: fsrsSteps[index],
            isLast: index == fsrsSteps.length - 1,
          ),
        // 移动端次级入口：本机改用 AnkiConnect 连电脑（默认收起，配置真值仍在
        // 制卡设置，不在向导里复制表单）。
        if (mobile) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          OnboardingDisclosureRow(
            icon: Icons.lan_outlined,
            title: t.onboarding_anki_mobile_ankiconnect_title,
            expanded: _mobileAnkiConnectExpanded,
            onToggle: () => setState(
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

    // 单行页头：返回按钮和标题同一行，页头下方挂分段进度条。
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
      headerBottom: OnboardingProgressBar(
        current: _stepIndex,
        total: steps.length,
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: _kOnboardingContentMaxWidth,
                ),
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
                    style: textTheme.labelMedium!.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  if (_stepIndex > 0)
                    OutlinedButton(onPressed: _goBack, child: Text(t.back)),
                  if (_stepIndex > 0) SizedBox(width: tokens.spacing.gap),
                  FilledButton(
                    onPressed: _goNext,
                    child: Text(
                      isLast
                          ? t.onboarding_action_start
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
              necessity: OnboardingActionNecessity.recommended,
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
              necessity: OnboardingActionNecessity.recommended,
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
              necessity: OnboardingActionNecessity.recommended,
              onPressed: () => _pushPage((_) => const CustomFontsPage()),
            ),
          ],
        );
      case OnboardingStepId.clickLookup:
        return OnboardingOperationTutorialView(
          icon: Icons.touch_app_outlined,
          title: t.onboarding_step_click_lookup_title,
          body: t.onboarding_click_lookup_intro,
          preface: _sampleSentencePreface(),
          items: <OnboardingTutorialItem>[
            OnboardingTutorialItem(
              icon: Icons.ads_click_outlined,
              title: t.onboarding_click_lookup_tap_title,
              description: t.onboarding_click_lookup_tap_desc,
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
              label: t.onboarding_lookup_practice_action,
              description: t.onboarding_lookup_practice_desc,
              necessity: OnboardingActionNecessity.mustDo,
              onPressed: () => _openStandaloneLookup(query: _sampleSentence),
            ),
          ],
        );
      case OnboardingStepId.globalLookup:
        return _buildGlobalLookupTutorial();
      case OnboardingStepId.firstAnkiCard:
        return _buildFirstAnkiCardTutorial();
      case OnboardingStepId.finish:
        return _buildFinishStep();
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
      body: t.onboarding_first_anki_card_intro,
      preface: _sampleSentencePreface(),
      items: <OnboardingTutorialItem>[
        OnboardingTutorialItem(
          icon: Icons.fact_check_outlined,
          title: t.onboarding_first_anki_lookup_title,
          description: t.onboarding_first_anki_lookup_desc,
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
          onPressed: () => _openStandaloneLookup(query: _sampleSentence),
        ),
      ],
    );
  }

  /// 当前应用外查词热键的键帽（读快捷键 registry 真值，而不是把默认 Ctrl+Alt+D
  /// 写死进文案——用户改过键位后教程还得说对）。没绑定时返回 null。
  Widget? _globalLookupKeycaps() {
    final ShortcutBindingSet set = appModel.shortcutRegistry.bindingsFor(
      ShortcutAction.globalExternalLookup,
    );
    if (set.keyboardBindings.isEmpty) return null;
    final InputBinding binding = set.keyboardBindings.first;
    final List<String> parts = binding.displayLabel.split('+');
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Wrap(
      spacing: tokens.spacing.gap / 2,
      runSpacing: tokens.spacing.gap / 2,
      children: <Widget>[
        for (int i = 0; i < parts.length; i++)
          KeyCapWidget(
            logicalKey: binding.key,
            label: parts[i],
            bound: true,
            isModifier: i < parts.length - 1,
            height: 36,
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
            description: t.onboarding_global_lookup_android_select_desc,
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
          description: t.onboarding_global_lookup_windows_select_desc,
        ),
        OnboardingTutorialItem(
          icon: Icons.keyboard_outlined,
          title: t.onboarding_global_lookup_windows_shortcut_press,
          description: t.onboarding_global_lookup_windows_shortcut_body,
          extra: _globalLookupKeycaps(),
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
        OnboardingStepHero(
          icon: Icons.waving_hand_outlined,
          title: t.onboarding_welcome_headline,
          body: t.onboarding_welcome_body,
        ),
        SizedBox(height: tokens.spacing.card),
        // 复用外观设置的行选择器（同一真相源），语言/明暗改动立即生效。
        FushiCard(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
          child: Column(
            children: <Widget>[
              buildLanguageSelector(settingsContext),
              buildBrightnessSelector(settingsContext),
            ],
          ),
        ),
      ],
    );
  }

  /// 功能选择页里当前平台真的提供勾选的模块。
  List<OnboardingFeature> get _visibleModuleFeatures => <OnboardingFeature>[
        for (final OnboardingFeature feature in OnboardingFeature.values)
          if (kOnboardingModuleFeatures.contains(feature) &&
              (feature != OnboardingFeature.games || Platform.isWindows) &&
              (feature != OnboardingFeature.browserExtension ||
                  _browserExtensionAvailable))
            feature,
      ];

  List<OnboardingFeature> get _capabilityFeatures => <OnboardingFeature>[
        for (final OnboardingFeature feature in OnboardingFeature.values)
          if (!kOnboardingModuleFeatures.contains(feature)) feature,
      ];

  OnboardingFeatureTile _featureTile(OnboardingFeature feature) =>
      OnboardingFeatureTile(
        icon: _featureIcon(feature),
        title: _featureTitle(feature),
        subtitle: _featureHint(feature),
        selected: _selected.contains(feature),
        onToggle: () => _toggleFeature(feature),
      );

  Widget _buildFeaturesStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        OnboardingStepHero(
          icon: Icons.checklist_outlined,
          title: t.onboarding_features_title,
          body: t.onboarding_features_setup_hint,
        ),
        SizedBox(height: tokens.spacing.card),
        OnboardingSectionLabel(
          title: t.onboarding_features_modules_title,
          hint: t.onboarding_features_modules_hint,
        ),
        SizedBox(height: tokens.spacing.gap),
        OnboardingFeatureGrid(
          tiles: <OnboardingFeatureTile>[
            for (final OnboardingFeature feature in _visibleModuleFeatures)
              _featureTile(feature),
          ],
        ),
        SizedBox(height: tokens.spacing.section),
        OnboardingSectionLabel(title: t.onboarding_features_setup_title),
        SizedBox(height: tokens.spacing.gap),
        OnboardingFeatureGrid(
          tiles: <OnboardingFeatureTile>[
            for (final OnboardingFeature feature in _capabilityFeatures)
              _featureTile(feature),
          ],
        ),
      ],
    );
  }

  /// 推荐包步骤的动作表。只有第一条是主线，其余四条都是「不想下整包」或「学别的
  /// 语言」时的替代路径——它们由 [OnboardingActionList] 收进「其他方式」。
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
      // 浏览器下载不直接甩一条 9.5 GB 的裸直链：官网下载页上有分片直链
      // （IDM / aria2 能用）、整包镜像和「导入方式选合并」的说明。
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
    // 整步都跟着 controller 走：下载不再属于本页，走开一步再回来（甚至关掉向导
    // 再从设置重开）看到的都是同一个任务的真实状态（BUG-2097）。
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _packController.stage,
        _packController.progress,
        _packController.receivedBytes,
        _packController.error,
      ]),
      builder: (BuildContext context, _) {
        final String? downloadError = _packController.error.value;
        // 两条失败路径、两套文案：下载失败由 controller 存裸消息，此处才套模板；
        // 选文件失败（BUG-2107）在写入处就已组好整句，直接显示。
        final String? shownError = _packPickError ??
            (downloadError == null
                ? null
                : t.onboarding_pack_download_failed(message: downloadError));
        return ListView(
          padding: EdgeInsets.all(tokens.spacing.card),
          children: <Widget>[
            OnboardingStepHero(
              icon: Icons.auto_stories_outlined,
              title: t.onboarding_step_pack_title,
              body: t.onboarding_pack_intro,
            ),
            SizedBox(height: tokens.spacing.card),
            if (shownError != null) ...<Widget>[
              Text(
                shownError,
                style: textTheme.bodySmall!.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
              SizedBox(height: tokens.spacing.gap),
            ],
            if (_packController.isDownloading)
              FushiCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    LinearProgressIndicator(
                      value: _packController.progress.value > 0
                          ? _packController.progress.value
                          : null,
                    ),
                    SizedBox(height: tokens.spacing.gap),
                    Text(
                      '${t.onboarding_pack_downloading} · '
                      '${recommendedPackProgressLabel(progress: _packController.progress.value, receivedBytes: _packController.receivedBytes.value)}',
                      style: textTheme.bodySmall,
                    ),
                    SizedBox(height: tokens.spacing.gap),
                    // 用户最想知道的一件事：现在能不能走开。能。
                    Text(
                      t.onboarding_pack_download_background_hint,
                      style: textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    SizedBox(height: tokens.spacing.gap),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: OutlinedButton(
                        onPressed: _packController.requestCancel,
                        child: Text(t.dialog_cancel),
                      ),
                    ),
                  ],
                ),
              )
            else
              OnboardingActionList(
                actions: _packActions(_packController.hasPendingImport),
              ),
          ],
        );
      },
    );
  }

  Widget _buildFinishStep() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<String> modules = <String>[
      for (final OnboardingFeature feature in _visibleModuleFeatures)
        if (_selected.contains(feature)) _featureTitle(feature),
    ];
    final List<String> setup = <String>[
      for (final OnboardingFeature feature in _capabilityFeatures)
        if (_selected.contains(feature)) _featureTitle(feature),
    ];
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        OnboardingStepHero(
          icon: Icons.check_circle_outline,
          title: t.onboarding_finish_title,
          body: t.onboarding_finish_body,
        ),
        SizedBox(height: tokens.spacing.card),
        FushiCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              OnboardingSummaryRow(
                label: t.onboarding_finish_summary_modules,
                items: modules,
              ),
              SizedBox(height: tokens.spacing.card),
              OnboardingSummaryRow(
                label: t.onboarding_finish_summary_setup,
                items: setup,
              ),
            ],
          ),
        ),
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
      case OnboardingFeature.fonts:
        return Icons.font_download_outlined;
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
      case OnboardingFeature.fonts:
        return t.onboarding_feature_fonts;
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
      case OnboardingFeature.fonts:
        return t.onboarding_feature_fonts_hint;
      case OnboardingFeature.backup:
        return t.onboarding_feature_backup_hint;
      case OnboardingFeature.interconnect:
        return t.onboarding_feature_interconnect_hint;
    }
  }
}

// ── 共享 widget（公开，便于脱离 AppModel 做 widget 测试）────────────────

/// 页头下方的分段进度条：已走过 / 当前 段用主色，未到的段用轮廓色。
/// 每段等宽，段数 = 步骤数——勾选变化让步骤增减时条也跟着重排。
class OnboardingProgressBar extends StatelessWidget {
  const OnboardingProgressBar({
    required this.current,
    required this.total,
    super.key,
  });

  /// 当前步骤下标（0-based）。
  final int current;
  final int total;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '${current + 1} / $total',
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.page,
          0,
          tokens.spacing.page,
          tokens.spacing.gap,
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < total; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.symmetric(
                    horizontal: tokens.spacing.gap / 4,
                  ),
                  child: AnimatedContainer(
                    duration: fushiMd3StateDuration,
                    curve: fushiMd3StateCurve,
                    height: 4,
                    decoration: BoxDecoration(
                      color:
                          i <= current ? colors.primary : colors.outlineVariant,
                      borderRadius: tokens.radii.chipRadius,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 每一步开头的 hero：圆底图标 + 标题 + 一句说明，左对齐。
class OnboardingStepHero extends StatelessWidget {
  const OnboardingStepHero({
    required this.icon,
    required this.title,
    required this.body,
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: colors.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, size: 28, color: colors.onPrimaryContainer),
        ),
        SizedBox(width: tokens.spacing.card),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title, style: theme.textTheme.headlineSmall),
              SizedBox(height: tokens.spacing.gap / 2),
              Text(
                body,
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 分组小标题 + 可选的一句提示。
class OnboardingSectionLabel extends StatelessWidget {
  const OnboardingSectionLabel({required this.title, this.hint, super.key});

  final String title;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: tokens.type.sectionLabel),
        if (hint != null) ...<Widget>[
          SizedBox(height: tokens.spacing.gap / 4),
          Text(
            hint!,
            style: theme.textTheme.bodySmall!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// 功能选择步骤里的勾选卡片。
///
/// 两态**几何完全一致**：边框两态都画（颜色不同）、文字字重不随选中变化，只有
/// 底色 / 描边色 / 右侧勾选图标三重反馈。否则同一列卡片会因选中而逐个长高错位。
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
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return FushiCard(
      selected: selected,
      borderColor: selected ? colors.primary : colors.outlineVariant,
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.card,
        vertical: tokens.spacing.gap,
      ),
      onTap: onToggle,
      child: Row(
        children: <Widget>[
          Icon(
            icon,
            color: selected ? colors.primary : colors.onSurfaceVariant,
          ),
          SizedBox(width: tokens.spacing.card),
          Expanded(
            child: Column(
              // 有界父级里默认 max 会把卡片撑满整个可用高度。
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: tokens.type.listTitle),
                SizedBox(height: tokens.spacing.gap / 4),
                Text(
                  subtitle,
                  style: tokens.type.listSubtitle.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Icon(
            selected ? Icons.check_circle : Icons.radio_button_unchecked,
            color: selected ? colors.primary : colors.outline,
          ),
        ],
      ),
    );
  }
}

/// 功能卡片的响应式排布：宽屏两列（同一行用 [IntrinsicHeight] 拉齐高度），窄屏
/// 一列。
class OnboardingFeatureGrid extends StatelessWidget {
  const OnboardingFeatureGrid({required this.tiles, super.key});

  final List<OnboardingFeatureTile> tiles;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final int columns =
            constraints.maxWidth >= _kOnboardingTwoColumnMinWidth ? 2 : 1;
        final List<Widget> rows = <Widget>[];
        for (int start = 0; start < tiles.length; start += columns) {
          final List<Widget> cells = <Widget>[];
          for (int column = 0; column < columns; column++) {
            if (column > 0) cells.add(SizedBox(width: tokens.spacing.gap));
            final int index = start + column;
            cells.add(
              Expanded(
                child: index < tiles.length
                    ? tiles[index]
                    : const SizedBox.shrink(),
              ),
            );
          }
          rows.add(
            Padding(
              padding: EdgeInsets.only(bottom: tokens.spacing.gap),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: cells,
                ),
              ),
            ),
          );
        }
        return Column(children: rows);
      },
    );
  }
}

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

/// 渲染一条 [OnboardingAction]：整卡可点，标题右边挂必要性徽标，下面是说明。
class OnboardingActionTile extends StatelessWidget {
  const OnboardingActionTile({required this.action, super.key});

  final OnboardingAction action;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final bool enabled = action.onPressed != null;
    final Widget? trailing = action.trailing ??
        (enabled
            ? Icon(Icons.chevron_right, color: colors.onSurfaceVariant)
            : null);
    return FushiCard(
      margin: EdgeInsets.only(bottom: tokens.spacing.gap),
      onTap: action.onPressed,
      child: Row(
        children: <Widget>[
          Icon(
            action.icon,
            color: enabled ? colors.primary : theme.disabledColor,
          ),
          SizedBox(width: tokens.spacing.card),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        action.label,
                        style: tokens.type.listTitle,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    SizedBox(width: tokens.spacing.gap / 2),
                    OnboardingNecessityBadge(necessity: action.necessity),
                  ],
                ),
                SizedBox(height: tokens.spacing.gap / 4),
                // 说明是完整的一两句话，不截断。
                Text(
                  action.description,
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...<Widget>[
            SizedBox(width: tokens.spacing.gap),
            trailing,
          ],
        ],
      ),
    );
  }
}

/// 可展开的一行（「其他方式」「高级：…」）。
class OnboardingDisclosureRow extends StatelessWidget {
  const OnboardingDisclosureRow({
    required this.icon,
    required this.title,
    required this.expanded,
    required this.onToggle,
    super.key,
  });

  final IconData icon;
  final String title;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return FushiListItem(
      leading: Icon(icon),
      title: Text(title),
      trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more),
      onTap: onToggle,
    );
  }
}

/// 一步的动作列表：必做 / 推荐的动作直接摊开；有主线时，可选动作收进「其他方式」
/// 折叠组（默认收起）。没有主线动作（这一步全是可选）时就全部摊开——折叠一个
/// 只有可选项的列表等于把整页藏起来。
class OnboardingActionList extends StatefulWidget {
  const OnboardingActionList({required this.actions, super.key});

  final List<OnboardingAction> actions;

  @override
  State<OnboardingActionList> createState() => _OnboardingActionListState();
}

class _OnboardingActionListState extends State<OnboardingActionList> {
  bool _moreExpanded = false;

  @override
  Widget build(BuildContext context) {
    final List<OnboardingAction> primary = <OnboardingAction>[
      for (final OnboardingAction action in widget.actions)
        if (action.necessity != OnboardingActionNecessity.optional) action,
    ];
    final List<OnboardingAction> secondary = <OnboardingAction>[
      for (final OnboardingAction action in widget.actions)
        if (action.necessity == OnboardingActionNecessity.optional) action,
    ];
    final bool collapsible = primary.isNotEmpty && secondary.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final OnboardingAction action in primary)
          OnboardingActionTile(action: action),
        if (collapsible)
          OnboardingDisclosureRow(
            icon: Icons.more_horiz,
            title: t.onboarding_actions_more,
            expanded: _moreExpanded,
            onToggle: () => setState(() => _moreExpanded = !_moreExpanded),
          ),
        if (!collapsible || _moreExpanded)
          for (final OnboardingAction action in secondary)
            OnboardingActionTile(action: action),
      ],
    );
  }
}

/// 单个配置步骤的内容骨架（hero + 动作列表）。
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
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        OnboardingStepHero(icon: icon, title: title, body: body),
        if (actions.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.card),
          OnboardingActionList(actions: actions),
        ],
      ],
    );
  }
}

/// 功能操作教程的一条动作：用图标帮助扫读，标题说「做什么」，说明说「怎么做」。
/// [extra] 是说明下方的附加内容（例：热键键帽）。
@immutable
class OnboardingTutorialItem {
  const OnboardingTutorialItem({
    required this.icon,
    required this.title,
    required this.description,
    this.extra,
  });

  final IconData icon;
  final String title;
  final String description;
  final Widget? extra;
}

/// 功能操作教程页面。与配置步骤的 [OnboardingStepView] 分开：配置页强调按钮的
/// 必要性，操作页强调有顺序的「先做什么、再做什么」——竖向 stepper（编号圆点 +
/// 连线），不能用一排可选按钮冒充教程。
class OnboardingOperationTutorialView extends StatelessWidget {
  const OnboardingOperationTutorialView({
    required this.icon,
    required this.title,
    required this.body,
    required this.items,
    this.preface,
    this.actions = const <OnboardingAction>[],
    super.key,
  });

  final IconData icon;
  final String title;
  final String body;

  /// hero 与步骤之间的引子（例：练习句子卡）。
  final Widget? preface;
  final List<OnboardingTutorialItem> items;
  final List<OnboardingAction> actions;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ListView(
      padding: EdgeInsets.all(tokens.spacing.card),
      children: <Widget>[
        OnboardingStepHero(icon: icon, title: title, body: body),
        SizedBox(height: tokens.spacing.card),
        if (preface != null) ...<Widget>[
          preface!,
          SizedBox(height: tokens.spacing.card),
        ],
        for (int index = 0; index < items.length; index++)
          OnboardingTutorialStep(
            number: index + 1,
            item: items[index],
            isLast: index == items.length - 1,
          ),
        if (actions.isNotEmpty) ...<Widget>[
          SizedBox(height: tokens.spacing.gap),
          OnboardingActionList(actions: actions),
        ],
      ],
    );
  }
}

/// 竖向 stepper 的一格：左列编号圆点 + 向下的连线，右列图标标题 + 说明 + 附加。
class OnboardingTutorialStep extends StatelessWidget {
  const OnboardingTutorialStep({
    required this.number,
    required this.item,
    required this.isLast,
    super.key,
  });

  final int number;
  final OnboardingTutorialItem item;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 32,
            child: Column(
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '$number',
                    style: theme.textTheme.labelLarge!.copyWith(
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                ),
                if (!isLast)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: EdgeInsets.symmetric(
                        vertical: tokens.spacing.gap / 2,
                      ),
                      color: colors.outlineVariant,
                    ),
                  ),
              ],
            ),
          ),
          SizedBox(width: tokens.spacing.gap),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                bottom: isLast ? 0 : tokens.spacing.card,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Icon(item.icon, size: 18, color: colors.onSurfaceVariant),
                      SizedBox(width: tokens.spacing.gap / 2),
                      Expanded(
                        child: Text(item.title, style: tokens.type.listTitle),
                      ),
                    ],
                  ),
                  SizedBox(height: tokens.spacing.gap / 4),
                  Text(
                    item.description,
                    style: theme.textTheme.bodyMedium!.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (item.extra != null) ...<Widget>[
                    SizedBox(height: tokens.spacing.gap),
                    item.extra!,
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 完成页里的一行「标签 + 一组 chip」；空集合显示「无」。
class OnboardingSummaryRow extends StatelessWidget {
  const OnboardingSummaryRow({
    required this.label,
    required this.items,
    super.key,
  });

  final String label;
  final List<String> items;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: tokens.type.sectionLabel),
        SizedBox(height: tokens.spacing.gap / 2),
        if (items.isEmpty)
          Text(
            t.onboarding_finish_summary_none,
            style: theme.textTheme.bodyMedium!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          )
        else
          Wrap(
            spacing: tokens.spacing.gap / 2,
            runSpacing: tokens.spacing.gap / 2,
            children: <Widget>[
              for (final String item in items) FushiTagChip(label: item),
            ],
          ),
      ],
    );
  }
}

/// 查词教程的练习句子卡：标签 + 大字号句子 + 一句「点开去查」提示，整卡可点。
///
/// 句子本身不在向导里做逐字点词——那要把查词弹窗栈整套搬进向导；点卡片把整句喂进
/// 真实查词页（源文本条 + 嵌套弹窗 + 加号制卡），用户在那里练的就是产品里的真路径。
class OnboardingSampleSentenceCard extends StatelessWidget {
  const OnboardingSampleSentenceCard({
    required this.sentence,
    required this.onTap,
    super.key,
  });

  final String sentence;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return FushiCard(
      color: colors.primaryContainer,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                Icons.touch_app_outlined,
                size: 18,
                color: colors.onPrimaryContainer,
              ),
              SizedBox(width: tokens.spacing.gap / 2),
              Text(
                t.onboarding_sample_sentence_label,
                style: tokens.type.sectionLabel.copyWith(
                  color: colors.onPrimaryContainer,
                ),
              ),
            ],
          ),
          SizedBox(height: tokens.spacing.gap),
          Text(
            sentence,
            style: theme.textTheme.titleLarge!.copyWith(
              color: colors.onPrimaryContainer,
            ),
          ),
          SizedBox(height: tokens.spacing.gap),
          Text(
            t.onboarding_sample_sentence_hint,
            style: theme.textTheme.bodySmall!.copyWith(
              color: colors.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
