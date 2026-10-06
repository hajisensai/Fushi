import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart'
    show SettingsSectionFooter;
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi_engine/media/torrent/anime_download_config.dart';
import 'package:fushi_engine/media/torrent/download_save_root.dart';
import 'package:fushi_engine/media/torrent/qb_torrent_backend.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';

/// 下载后端配置（后端二选一 + qb 连接 / 内置引擎限速·上传·做种·内存·连接数）。
/// 从「设置→视频」搬到「下载」页——下载既已独立成页，配置就该在页内，不再埋进
/// 视频设置。所有字段写 `QbConnectionConfig`（即时生效到内置引擎）。
enum TorrentSettingsScope { all, common, connection, trackers, advanced }

class TorrentSettingsSection extends ConsumerStatefulWidget {
  const TorrentSettingsSection({
    super.key,
    this.embeddedSupportedOverride,
    this.scope = TorrentSettingsScope.all,
  });

  /// 仅测试注入：覆盖「本平台是否有内置引擎」的判据（BUG-1207 的平台门控）。
  /// null = 用真实 `dart:io` 平台判断。照搬 `book_import_dialog.dart` 的
  /// `ocrEntryDesktopOverride` 范式——`Platform` 不可 override，不给注入口就
  /// 只能退回源码扫描守卫，测不到真实渲染行为。
  final bool? embeddedSupportedOverride;
  final TorrentSettingsScope scope;

  @override
  ConsumerState<TorrentSettingsSection> createState() =>
      _TorrentSettingsSectionState();
}

class _TorrentSettingsSectionState
    extends ConsumerState<TorrentSettingsSection> {
  /// 本平台是否具备内置引擎（桌面 + Android）。
  ///
  /// 走 [AppModel.supportsEmbeddedTorrent] 这**一个**真相源，不再手抄
  /// `Platform.isXxx` 串——判据抄成两份，某次加平台时 UI 和运行时后端解析就会
  /// 悄悄分叉（一边显示得出选择器、另一边解析不出后端）。
  bool get _supportsEmbedded =>
      widget.embeddedSupportedOverride ??
      ref.read(appProvider).supportsEmbeddedTorrent;

  QbConnectionConfig get _config =>
      effectiveTorrentConfig(ref.read(appProvider).qbConnectionConfig);

  /// 「测试连接」进行中（按钮禁用防重入）。
  bool _probing = false;

  /// TODO-1961：目录选择/校验进行中（按钮禁用防重入）。
  bool _pickingFolder = false;

  bool _fetchingTrackers = false;
  List<String> _trackerPreview = const <String>[];
  String? _trackerFetchError;

  /// 已配对且启用的互联 host（「下载执行设备」下拉的候选）。
  List<FushiClientUrl> _pairedHosts = const <FushiClientUrl>[];

  /// 全部已启用地址（含同一台 host 的多条），用于把偏好里的地址归到它的 host。
  List<FushiClientUrl> _pairedUrls = const <FushiClientUrl>[];

  /// 分类输入框：持 controller 是为了失焦回填——清空时存储侧兜底 'fushi'，
  /// 失焦把实际生效值写回输入框，所见即所得（不再「显示空、实际 fushi」）。
  late final TextEditingController _categoryCtrl;
  late final FocusNode _categoryFocus;
  late final TextEditingController _trackerUrlCtrl;

  @override
  void initState() {
    super.initState();
    // Some scopes never build these fields. Initialize while ref is active,
    // rather than letting disposal evaluate a lazy provider-backed initializer.
    final QbConnectionConfig config = _config;
    _categoryCtrl = TextEditingController(text: config.category);
    _categoryFocus = FocusNode()..addListener(_onCategoryFocusChanged);
    _trackerUrlCtrl = TextEditingController(
      text: config.trackerSubscriptionUrl,
    );
    unawaited(_loadPairedHosts());
  }

  Future<void> _loadPairedHosts() async {
    final AppModel appModel = ref.read(appProvider);
    // 配对清单在 DB 的 preferences 表里；库没开（测试 seam / 极早期）就是没有 host。
    if (!appModel.isDatabaseReady) return;
    final List<FushiClientUrl> enabled =
        (await SyncRepository(appModel.database).getFushiClientUrls())
            .where((FushiClientUrl u) => u.enabled)
            .toList(growable: false);
    if (mounted) {
      setState(() {
        _pairedUrls = enabled;
        // 同一台 host 的多条地址只列一次（身份代表稳定，存进偏好不会变孤儿）。
        _pairedHosts = interconnectPeerRepresentatives(enabled);
      });
    }
  }

  /// 当前偏好里的执行设备；不在配对清单里（已解绑）时退回本机显示。
  ///
  /// 顺手把偏好也清掉：只改显示的话，设置页写着「本机」而实际下载仍按那个死地址
  /// 报「执行设备连不上」，用户看不出所以然（解析侧另有一层「不在清单就回本机」
  /// 的兜底，这里是让持久值本身自愈）。
  String _executionHostValue(AppModel appModel) {
    final String url = appModel.prefsRepo.downloadExecutionHostUrl;
    if (url.isEmpty) return '';
    // 按所属 host 匹配：偏好里存的那条地址可能是该 host 的另一条（旧版本存的、
    // 或 host 换过 IP），只要那台 host 还在清单里就显示它。
    final FushiClientUrl? host = interconnectPeerRepresentativeOf(_pairedUrls, url);
    if (host != null) return host.url;
    unawaited(appModel.prefsRepo.setDownloadExecutionHostUrl(''));
    return '';
  }

  void _onCategoryFocusChanged() {
    if (_categoryFocus.hasFocus) return;
    final String effective = _config.category;
    if (_categoryCtrl.text.trim() != effective) {
      _categoryCtrl.text = effective;
    }
  }

  @override
  void dispose() {
    _categoryFocus.removeListener(_onCategoryFocusChanged);
    _categoryFocus.dispose();
    _categoryCtrl.dispose();
    _trackerUrlCtrl.dispose();
    super.dispose();
  }

  Future<void> _commit(
    QbConnectionConfig Function(QbConnectionConfig c) mutate,
  ) async {
    await ref.read(appProvider).setQbConnectionConfig(mutate(_config));
    if (mounted) setState(() {});
  }

  /// 测试与下载后端的连通性（按当前配置解析后端；qb = WebUI 版本号）。
  /// 成功 snack 显示版本；失败时透传后端给的具体原因（BUG-1295：网络不通/
  /// 账密错/qb 封 IP 此前折叠成同一句「检查地址与账号密码」，无从自查）。
  Future<void> _probeConnection() async {
    if (_probing) return;
    setState(() => _probing = true);
    final TorrentBackend backend = ref
        .read(appProvider)
        .createTorrentBackend(_config);
    String? version;
    String? failure;
    try {
      version = await backend.probeConnection();
    } finally {
      if (version == null && backend is QbTorrentBackend) {
        failure = backend.lastProbeFailure;
      }
      backend.close();
    }
    if (!mounted) return;
    setState(() => _probing = false);
    final String message;
    if (version != null) {
      message = t.download_test_connection_ok(version: version);
    } else if (failure != null && failure.isNotEmpty) {
      message = t.download_test_connection_failed_reason(message: failure);
    } else {
      message = t.download_test_connection_failed;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(FushiSnackBar(content: Text(message)));
  }

  Future<void> _refreshTrackers() async {
    if (_fetchingTrackers) return;
    final String sourceUrl = _trackerUrlCtrl.text.trim();
    await _commit(
      (QbConnectionConfig c) => c.copyWith(trackerSubscriptionUrl: sourceUrl),
    );
    if (!mounted) return;
    setState(() {
      _fetchingTrackers = true;
      _trackerFetchError = null;
    });
    try {
      final List<String> trackers = await ref
          .read(appProvider)
          .refreshTrackerSubscription(sourceUrl: sourceUrl);
      if (!mounted) return;
      setState(() => _trackerPreview = trackers);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _trackerPreview = const <String>[];
        _trackerFetchError = error.toString();
      });
    } finally {
      if (mounted) setState(() => _fetchingTrackers = false);
    }
  }

  /// TODO-1961：选新的下载目录。校验不过**不写**配置，直接 snack 报原因（不静默）。
  /// 统一走 [pickRealDirectoryPath]（与数据根设置同一惯例）：下载根长期承载写入，
  /// 必须是真实文件系统路径。
  Future<void> _changeDownloadFolder() async {
    if (_pickingFolder) return;
    setState(() => _pickingFolder = true);
    try {
      final String? picked = await pickRealDirectoryPath(
        context: context,
        appModel: ref.read(appProvider),
        dialogTitle: t.download_save_root_change,
        initialDirectory: ref.read(appProvider).downloadSaveRoot,
      );
      if (picked == null || picked.trim().isEmpty || !mounted) return;
      final DownloadSaveRootIssue? issue = await ref
          .read(appProvider)
          .setDownloadSaveRoot(picked);
      if (!mounted) return;
      if (issue != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(FushiSnackBar(content: Text(_saveRootIssueMessage(issue))));
      }
    } finally {
      if (mounted) setState(() => _pickingFolder = false);
    }
  }

  Future<void> _resetDownloadFolder() async {
    if (_pickingFolder) return;
    await ref.read(appProvider).resetDownloadSaveRoot();
    if (mounted) setState(() {});
  }

  static String _saveRootIssueMessage(DownloadSaveRootIssue issue) {
    switch (issue) {
      case DownloadSaveRootIssue.notAbsolute:
        return t.download_save_root_not_absolute;
      case DownloadSaveRootIssue.createFailed:
        return t.download_save_root_create_failed;
      case DownloadSaveRootIssue.notWritable:
        return t.download_save_root_not_writable;
    }
  }

  /// 下载目录分组（当前路径 + 更改 / 恢复默认 + 启动回退警告）。
  /// 只在内置引擎分支渲染：外接 qb 的落盘目录由 qb 自己管，改不到。
  ///
  /// 路径条目按系统设置的写法：标题 + 副标题显示当前路径 + 行尾「更改」按钮，
  /// 整行也可点；「恢复默认」只在确实改过时作为单独一行出现（灰着的按钮在设置
  /// 分组里只是噪音）。
  Widget _downloadFolderGroup(AppModel appModel) {
    final DownloadSaveRootIssue? issue = appModel.downloadSaveRootIssue;
    return _group(
      key: 'downloads.group.save_root',
      footer: t.download_save_root_hint,
      rows: <Widget>[
        SettingsSearchTarget(
          key: const ValueKey<String>('downloads.save_root'),
          id: 'downloads.save_root',
          child: AdaptiveSettingsRow(
            title: t.download_save_root_title,
            subtitle: appModel.downloadSaveRoot,
            onTap: _changeDownloadFolder,
            trailing: FushiFilledButton.tonal(
              onPressed: _pickingFolder ? null : _changeDownloadFolder,
              child: Text(t.download_save_root_change),
            ),
          ),
        ),
        if (!appModel.downloadSaveRootIsDefault)
          AdaptiveSettingsRow(
            key: const ValueKey<String>('downloads.save_root_reset'),
            title: t.download_save_root_reset,
            onTap: _resetDownloadFolder,
          ),
        if (issue != null)
          Padding(
            key: const ValueKey<String>('downloads.save_root_issue'),
            padding: EdgeInsets.symmetric(
              horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
              vertical: 10,
            ),
            child: FushiInlineNotice(
              severity: FushiNoticeSeverity.warning,
              message:
                  '${t.download_save_root_fallback_warning}'
                  '\n${appModel.downloadSaveRootRejectedPath ?? ''} — '
                  '${_saveRootIssueMessage(issue)}',
            ),
          ),
      ],
    );
  }

  static int _nonNegInt(String v) {
    final int n = int.tryParse(v.trim()) ?? 0;
    return n < 0 ? 0 : n;
  }

  static double _nonNegDouble(String v) {
    final double n = double.tryParse(v.trim()) ?? 0;
    return (n.isFinite && n > 0) ? n : 0;
  }

  /// 一个真正的设置分组：[AdaptiveSettingsSection]（MD3 分段卡 / Apple inset
  /// grouped）+ 可选组外标题 + 可选脚注。空分组整块不渲染。
  ///
  /// [key] 锚定分组身份：上传 / 反吸血开关会让后面的行与分组增删，没有 key 时
  /// 同类型相邻分组会按位置错配旧 State（输入框残留上一组的文字）。
  Widget _group({
    required String key,
    required List<Widget> rows,
    String? title,
    String? footer,
  }) {
    if (rows.isEmpty) return SizedBox.shrink(key: ValueKey<String>(key));
    return Column(
      key: ValueKey<String>(key),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AdaptiveSettingsSection(title: title, children: rows),
        if (footer != null) SettingsSectionFooter(footer),
      ],
    );
  }

  /// 输入行：标题 + 说明在上、输入框在下撑满行宽（与 schema 的
  /// `SettingsTextItem` / `SettingsNumberItem` 同一种行，BUG-1858 的「输入框吃满
  /// 内容区」宽度规则由行自己承接）。
  ///
  /// [subtitle] 是常驻说明（讲清输入框自身讲不完的生效边界）；[hint] 是输入后即
  /// 消失的占位提示（「0 = 不限」这类短句）。
  Widget _inputRow({
    required String id,
    required String label,
    String? initial,
    String? hint,
    String? subtitle,
    bool obscure = false,
    TextInputType keyboard = TextInputType.text,
    TextEditingController? controller,
    FocusNode? focusNode,
    required ValueChanged<String> onChanged,
  }) {
    assert(
      (initial == null) != (controller == null),
      'initial 与 controller 二选一',
    );
    return SettingsSearchTarget(
      key: ValueKey<String>(id),
      id: id,
      child: AdaptiveSettingsRow(
        title: label,
        subtitle: subtitle,
        controlBelow: true,
        trailing: AdaptiveSettingsTextField(
          controller: controller,
          focusNode: focusNode,
          initialValue: initial,
          obscureText: obscure,
          keyboardType: keyboard,
          hintText: hint,
          onChanged: onChanged,
        ),
      ),
    );
  }

  Widget _numRow({
    required String id,
    required String label,
    required int value,
    String? hint,
    String? subtitle,
    required ValueChanged<String> onChanged,
  }) {
    return _inputRow(
      id: id,
      label: label,
      initial: value == 0 ? '' : '$value',
      hint: hint,
      subtitle: subtitle,
      keyboard: TextInputType.number,
      onChanged: onChanged,
    );
  }

  Widget _switch({
    required String id,
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SettingsSearchTarget(
      key: ValueKey<String>(id),
      id: id,
      child: AdaptiveSettingsSwitchRow(
        title: label,
        subtitle: subtitle,
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  /// 动作行（测试连接 / 拉取 tracker）：整行是一个焦点停靠点，进行中行尾转圈。
  /// 进行中不摘掉 onTap——摘掉会让行从焦点注册表里消失，手柄焦点当场丢失；
  /// 防重入由动作本身的 in-flight 守卫负责。
  Widget _actionRow({
    required String id,
    required String title,
    String? subtitle,
    required bool busy,
    required VoidCallback onTap,
  }) {
    return AdaptiveSettingsRow(
      key: ValueKey<String>(id),
      title: title,
      subtitle: subtitle,
      onTap: onTap,
      trailing: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: FushiCircularProgressIndicator(strokeWidth: 2),
            )
          : null,
    );
  }

  /// 限速输入框下方那句「限速管不管局域网」的说明，**必须**随
  /// [QbConnectionConfig.limitLocalPeers] 变化：开关关着时限速确实放过局域网
  /// peer，开着时就不再放过，写死任一句都会让界面上出现与实际行为相反的话。
  static String _lanLimitHelper(QbConnectionConfig c) => c.limitLocalPeers
      ? t.download_rate_limit_lan_included
      : t.download_rate_limit_lan_exempt;

  /// tracker 动作行的状态句（失败原因 / 未拉取 / 拉到几条）。
  String get _trackerStatus => _trackerFetchError != null
      ? t.download_tracker_fetch_failed(message: _trackerFetchError!)
      : _trackerPreview.isEmpty
      ? t.download_tracker_preview_empty
      : t.download_tracker_preview_count(count: _trackerPreview.length);

  /// 后端二选一。标签是 `External qBittorrent` / `Built-in engine` 这类不可断行
  /// 的长词，窄屏裸 SegmentedButton 会直接裁字（BUG-1184），所以走
  /// [FushiSegmentedStrip]（装不下就横向滚动）；它独占分组里的一行，所选后端的
  /// 一句话说明落在分组脚注里。
  ///
  /// 内置引擎排在第一段：它才是本平台的默认（`backendAuto` 解析结果），也是
  /// 开箱即用的那一个。qb 需要用户另装并配好 WebUI 才能用，排第二。
  Widget _backendRow(String backend) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return SettingsSearchTarget(
      key: const ValueKey<String>('downloads.backend'),
      id: 'downloads.backend',
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.rowHorizontal,
          vertical: 10,
        ),
        child: FushiSegmentedStrip<String>(
          segments: <ButtonSegment<String>>[
            ButtonSegment<String>(
              value: QbConnectionConfig.backendEmbedded,
              label: Text(t.video_setting_torrent_backend_embedded),
            ),
            ButtonSegment<String>(
              value: QbConnectionConfig.backendQbittorrent,
              label: Text(t.video_setting_torrent_backend_qb),
            ),
          ],
          selected: backend,
          onChanged: (String value) =>
              _commit((QbConnectionConfig c) => c.copyWith(backend: value)),
        ),
      ),
    );
  }

  /// 「下载执行设备」：新任务默认投给哪台已配对的互联 host（设计 §3.3，手机让
  /// 电脑下）。这一层在「后端」之上——手机不需要知道电脑用的是内置引擎还是外接
  /// qb。没配对任何 host 时不渲染：只剩「本机」一个选项。
  Widget _executionHostRow(AppModel appModel) {
    return SettingsSearchTarget(
      key: const ValueKey<String>('downloads.execution_host'),
      id: 'downloads.execution_host',
      child: AdaptiveSettingsPickerRow<String>(
        key: const ValueKey<String>('downloads-execution-host'),
        title: t.download_execution_host_title,
        subtitle: t.download_execution_host_hint,
        selected: _executionHostValue(appModel),
        options: <AdaptiveSettingsPickerOption<String>>[
          AdaptiveSettingsPickerOption<String>(
            value: '',
            label: t.download_target_local,
          ),
          for (final FushiClientUrl host in _pairedHosts)
            AdaptiveSettingsPickerOption<String>(
              value: host.url,
              label: t.download_target_remote(
                device: host.deviceName ?? host.url,
              ),
            ),
        ],
        onChanged: (String value) async {
          await appModel.prefsRepo.setDownloadExecutionHostUrl(value);
          if (mounted) setState(() {});
        },
      ),
    );
  }

  /// 拉取到的 tracker 清单：分组里的一行，限高可滚、可选中复制。
  Widget _trackerListRow(ThemeData theme) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return Padding(
      key: const ValueKey<String>('downloads.tracker_list'),
      padding: EdgeInsets.symmetric(
        horizontal: tokens.spacing.rowHorizontal,
        vertical: 10,
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 160),
        child: SingleChildScrollView(
          child: SizedBox(
            width: double.infinity,
            child: SelectableText(
              _trackerPreview.join('\n'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final QbConnectionConfig c = _config;
    final AppModel appModel = ref.watch(appProvider);
    final String backend = c.resolveBackend(
      embeddedSupported: _supportsEmbedded,
    );
    final bool isQb = backend == QbConnectionConfig.backendQbittorrent;
    final bool isEmbedded = backend == QbConnectionConfig.backendEmbedded;

    final bool common =
        widget.scope == TorrentSettingsScope.all ||
        widget.scope == TorrentSettingsScope.common;
    final bool advanced =
        widget.scope == TorrentSettingsScope.all ||
        widget.scope == TorrentSettingsScope.advanced;
    final bool connection =
        widget.scope == TorrentSettingsScope.all ||
        widget.scope == TorrentSettingsScope.connection;
    final bool trackers =
        widget.scope == TorrentSettingsScope.all ||
        widget.scope == TorrentSettingsScope.trackers;

    // 代理不再在这里配：全应用只有系统设置里的一个代理项，下载发现链路与其它
    // 公网出站共用同一个出口（见 download_timeouts.dart 头注释）。
    //
    // 每一块都是一个真正的设置分组（[_group]），不再是「一整块表单塞进一个
    // 分组行、靠自绘小节标题和内部分割线分段」。
    final List<Widget> groups = <Widget>[
      if (common) ...<Widget>[
        if (_pairedHosts.isNotEmpty)
          _group(
            key: 'downloads.group.execution_host',
            rows: <Widget>[_executionHostRow(appModel)],
          ),
        // BUG-1207：无内置引擎的平台（现在只剩 iOS）不渲染选择器——选择器里放一个
        // 够不着的档位，选中后 resolveBackend 会把它规约回 qb，段选状态原地弹回，
        // 比没有选项更糟。改为一句说明交代本平台只有外接 qb。
        if (_supportsEmbedded)
          _group(
            key: 'downloads.group.backend',
            footer: isEmbedded
                ? t.download_backend_embedded_hint
                : t.download_backend_qb_hint,
            rows: <Widget>[_backendRow(backend)],
          )
        else
          SettingsSectionFooter(
            t.download_backend_unsupported_note,
            key: const ValueKey<String>('downloads.backend_unsupported'),
          ),
      ],

      // 外接 qb 连接。
      if (isQb && connection)
        _group(
          key: 'downloads.group.connection',
          rows: <Widget>[
            _inputRow(
              id: 'downloads.video_setting_qb_url',
              label: t.video_setting_qb_url,
              initial: c.baseUrl,
              hint: t.video_setting_qb_url_hint,
              keyboard: TextInputType.url,
              onChanged: (String v) => _commit(
                (QbConnectionConfig c) => c.copyWith(baseUrl: v.trim()),
              ),
            ),
            _inputRow(
              id: 'downloads.video_setting_qb_username',
              label: t.video_setting_qb_username,
              initial: c.username,
              onChanged: (String v) => _commit(
                (QbConnectionConfig c) => c.copyWith(username: v.trim()),
              ),
            ),
            _inputRow(
              id: 'downloads.video_setting_qb_password',
              label: t.video_setting_qb_password,
              initial: c.password,
              obscure: true,
              onChanged: (String v) =>
                  _commit((QbConnectionConfig c) => c.copyWith(password: v)),
            ),
            // 测试连接：probeConnection 早已存在，给用户一个即时验证入口
            // （成功显示 WebUI 版本，失败提示查地址/账号），不必推一次种子试错。
            _actionRow(
              id: 'downloads.test_connection',
              title: t.download_test_connection,
              busy: _probing,
              onTap: _probeConnection,
            ),
          ],
        ),

      // 内置引擎：下载目录 / 限速 / 上传与做种。
      if (isEmbedded && common) ...<Widget>[
        // TODO-1961：下载目录（只影响新增任务，旧任务留在原目录）。
        _downloadFolderGroup(appModel),
        // 限速默认只约束 session 全局速率：libtorrent 把局域网 peer 归入独立的
        // local peer class，该 class 不受全局上限约束（官方文档明写的默认行为，
        // 家里两台机器互传不该被限）。下面的 limitLocalPeers 开关（默认关）可以
        // 把同一组上限也套到 local peer class。
        // 完整决策记录见 docs/bugs/BUG-1114-local-rig-rate-limit-flake.md。
        //
        // 说明必须随开关走：开着时"不作用于局域网"就是**假话**，界面不能写
        // 一句和实际行为相反的说明。
        _group(
          key: 'downloads.group.limits',
          rows: <Widget>[
            _numRow(
              id: 'downloads.video_setting_torrent_download_limit',
              label: t.video_setting_torrent_download_limit,
              value: c.downloadLimitKbps,
              hint: t.video_setting_torrent_limit_hint,
              subtitle: _lanLimitHelper(c),
              onChanged: (String v) => _commit(
                (QbConnectionConfig c) =>
                    c.copyWith(downloadLimitKbps: _nonNegInt(v)),
              ),
            ),
            _switch(
              id: 'downloads.video_setting_torrent_limit_lan',
              label: t.video_setting_torrent_limit_lan,
              subtitle: t.video_setting_torrent_limit_lan_hint,
              value: c.limitLocalPeers,
              onChanged: (bool v) => _commit(
                (QbConnectionConfig c) => c.copyWith(limitLocalPeers: v),
              ),
            ),
          ],
        ),
        _group(
          key: 'downloads.group.upload',
          rows: <Widget>[
            _switch(
              id: 'downloads.video_setting_torrent_upload_enabled',
              label: t.video_setting_torrent_upload_enabled,
              subtitle: t.video_setting_torrent_upload_enabled_hint,
              value: c.uploadEnabled,
              onChanged: (bool v) => _commit(
                (QbConnectionConfig c) => c.copyWith(uploadEnabled: v),
              ),
            ),
            if (c.uploadEnabled) ...<Widget>[
              _numRow(
                id: 'downloads.video_setting_torrent_upload_limit',
                label: t.video_setting_torrent_upload_limit,
                value: c.uploadLimitKbps,
                hint: t.video_setting_torrent_limit_hint,
                subtitle: _lanLimitHelper(c),
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(uploadLimitKbps: _nonNegInt(v)),
                ),
              ),
              _numRow(
                id: 'downloads.video_setting_torrent_seed_time_limit',
                label: t.video_setting_torrent_seed_time_limit,
                value: c.seedTimeLimitMinutes,
                subtitle: t.video_setting_torrent_seed_time_hint,
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(seedTimeLimitMinutes: _nonNegInt(v)),
                ),
              ),
              _inputRow(
                id: 'downloads.video_setting_torrent_seed_ratio_limit',
                label: t.video_setting_torrent_seed_ratio_limit,
                initial: c.seedRatioLimit == 0 ? '' : '${c.seedRatioLimit}',
                subtitle: t.video_setting_torrent_seed_ratio_hint,
                keyboard: const TextInputType.numberWithOptions(decimal: true),
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(seedRatioLimit: _nonNegDouble(v)),
                ),
              ),
            ],
          ],
        ),
      ],

      if (trackers)
        _group(
          key: 'downloads.group.trackers',
          title: t.download_tracker_section,
          footer: t.download_tracker_auto_add_hint,
          rows: <Widget>[
            _switch(
              id: 'downloads.download_tracker_auto_add',
              label: t.download_tracker_auto_add,
              value: c.autoAddTrackerSubscription,
              onChanged: (bool value) => _commit(
                (QbConnectionConfig c) =>
                    c.copyWith(autoAddTrackerSubscription: value),
              ),
            ),
            _inputRow(
              id: 'downloads.download_tracker_url',
              label: t.download_tracker_url,
              controller: _trackerUrlCtrl,
              keyboard: TextInputType.url,
              onChanged: (String value) => _commit(
                (QbConnectionConfig c) =>
                    c.copyWith(trackerSubscriptionUrl: value.trim()),
              ),
            ),
            _actionRow(
              id: 'downloads.tracker_refresh',
              title: t.download_tracker_refresh,
              subtitle: _trackerStatus,
              busy: _fetchingTrackers,
              onTap: _refreshTrackers,
            ),
            if (_trackerFetchError == null && _trackerPreview.isNotEmpty)
              _trackerListRow(theme),
          ],
        ),

      if (advanced) ...<Widget>[
        // 分类（两后端通用）。清空时存储侧兜底 'fushi'，失焦回填生效值
        // （见 [_onCategoryFocusChanged]），所见即所得。
        _group(
          key: 'downloads.group.engine',
          rows: <Widget>[
            _inputRow(
              id: 'downloads.video_setting_qb_category',
              label: t.video_setting_qb_category,
              subtitle: t.video_setting_qb_category_hint,
              controller: _categoryCtrl,
              focusNode: _categoryFocus,
              onChanged: (String v) => _commit(
                (QbConnectionConfig c) =>
                    c.copyWith(category: v.trim().isEmpty ? 'fushi' : v.trim()),
              ),
            ),
            if (isEmbedded) ...<Widget>[
              _numRow(
                id: 'downloads.video_setting_torrent_max_connections',
                label: t.video_setting_torrent_max_connections,
                value: c.maxConnections,
                hint: t.video_setting_torrent_connections_hint,
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(maxConnections: _nonNegInt(v)),
                ),
              ),
              _numRow(
                id: 'downloads.video_setting_torrent_memory_limit',
                label: t.video_setting_torrent_memory_limit,
                value: c.memoryLimitMb,
                subtitle: t.video_setting_torrent_memory_hint,
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(memoryLimitMb: _nonNegInt(v)),
                ),
              ),
            ],
          ],
        ),
        if (isEmbedded) ...<Widget>[
          // ---- 会话设置（抄 qB 关键项）----
          _group(
            key: 'downloads.group.session',
            title: t.video_setting_torrent_section_session,
            rows: <Widget>[
              _numRow(
                id: 'downloads.video_setting_torrent_listen_port',
                label: t.video_setting_torrent_listen_port,
                value: c.listenPort,
                hint: t.video_setting_torrent_listen_port_hint,
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(listenPort: _nonNegInt(v)),
                ),
              ),
              _switch(
                id: 'downloads.video_setting_torrent_dht',
                label: t.video_setting_torrent_dht,
                value: c.enableDht,
                onChanged: (bool v) =>
                    _commit((QbConnectionConfig c) => c.copyWith(enableDht: v)),
              ),
              _switch(
                id: 'downloads.video_setting_torrent_lsd',
                label: t.video_setting_torrent_lsd,
                value: c.enableLsd,
                onChanged: (bool v) =>
                    _commit((QbConnectionConfig c) => c.copyWith(enableLsd: v)),
              ),
              _switch(
                id: 'downloads.video_setting_torrent_upnp',
                label: t.video_setting_torrent_upnp,
                value: c.enableUpnp,
                onChanged: (bool v) => _commit(
                  (QbConnectionConfig c) => c.copyWith(enableUpnp: v),
                ),
              ),
              _switch(
                id: 'downloads.video_setting_torrent_natpmp',
                label: t.video_setting_torrent_natpmp,
                value: c.enableNatpmp,
                onChanged: (bool v) => _commit(
                  (QbConnectionConfig c) => c.copyWith(enableNatpmp: v),
                ),
              ),
              _switch(
                id: 'downloads.video_setting_torrent_anonymous',
                label: t.video_setting_torrent_anonymous,
                value: c.anonymousMode,
                onChanged: (bool v) => _commit(
                  (QbConnectionConfig c) => c.copyWith(anonymousMode: v),
                ),
              ),
              // 三个短选项：分段控件（MD3 行右侧紧凑分段 / Apple 液态玻璃分段），
              // 放不下时共享判据自动退回弹出菜单。
              SettingsSearchTarget(
                key: const ValueKey<String>('downloads.encryption'),
                id: 'downloads.encryption',
                child: AdaptiveSettingsSegmentedRow<int>(
                  title: t.settings_downloads_encryption_title,
                  controlBelow: false,
                  segments: <ButtonSegment<int>>[
                    ButtonSegment<int>(
                      value: QbConnectionConfig.encryptionPrefer,
                      label: Text(t.video_setting_torrent_encryption_prefer),
                    ),
                    ButtonSegment<int>(
                      value: QbConnectionConfig.encryptionForced,
                      label: Text(t.video_setting_torrent_encryption_forced),
                    ),
                    ButtonSegment<int>(
                      value: QbConnectionConfig.encryptionDisabled,
                      label: Text(t.video_setting_torrent_encryption_disabled),
                    ),
                  ],
                  selected: c.encryptionMode,
                  onChanged: (int mode) => _commit(
                    (QbConnectionConfig c) => c.copyWith(encryptionMode: mode),
                  ),
                ),
              ),
            ],
          ),
          // ---- 队列（同时活动的任务 / 上传槽）----
          _group(
            key: 'downloads.group.queue',
            footer: t.video_setting_torrent_zero_default,
            rows: <Widget>[
              _numRow(
                id: 'downloads.video_setting_torrent_active_downloads',
                label: t.video_setting_torrent_active_downloads,
                value: c.maxActiveDownloads,
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(maxActiveDownloads: _nonNegInt(v)),
                ),
              ),
              _numRow(
                id: 'downloads.video_setting_torrent_active_seeds',
                label: t.video_setting_torrent_active_seeds,
                value: c.maxActiveSeeds,
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(maxActiveSeeds: _nonNegInt(v)),
                ),
              ),
              _numRow(
                id: 'downloads.video_setting_torrent_upload_slots',
                label: t.video_setting_torrent_upload_slots,
                value: c.maxUploadSlots,
                onChanged: (String v) => _commit(
                  (QbConnectionConfig c) =>
                      c.copyWith(maxUploadSlots: _nonNegInt(v)),
                ),
              ),
            ],
          ),
          // ---- 反吸血（抄 qBittorrent-ClientBlocker）----
          _group(
            key: 'downloads.group.antileech',
            title: t.video_setting_torrent_section_antileech,
            rows: <Widget>[
              _switch(
                id: 'downloads.video_setting_torrent_antileech',
                label: t.video_setting_torrent_antileech,
                value: c.antiLeechEnabled,
                onChanged: (bool v) => _commit(
                  (QbConnectionConfig c) => c.copyWith(antiLeechEnabled: v),
                ),
              ),
              if (c.antiLeechEnabled) ...<Widget>[
                _switch(
                  id: 'downloads.video_setting_torrent_ban_progress_cheat',
                  label: t.video_setting_torrent_ban_progress_cheat,
                  value: c.banProgressCheat,
                  onChanged: (bool v) => _commit(
                    (QbConnectionConfig c) => c.copyWith(banProgressCheat: v),
                  ),
                ),
                _switch(
                  id: 'downloads.video_setting_torrent_ban_relative_cheat',
                  label: t.video_setting_torrent_ban_relative_cheat,
                  value: c.banRelativeProgressCheat,
                  onChanged: (bool v) => _commit(
                    (QbConnectionConfig c) =>
                        c.copyWith(banRelativeProgressCheat: v),
                  ),
                ),
                _numRow(
                  id: 'downloads.video_setting_torrent_max_ip_ports',
                  label: t.video_setting_torrent_max_ip_ports,
                  value: c.maxIpPortCount,
                  hint: t.video_setting_torrent_zero_off,
                  onChanged: (String v) => _commit(
                    (QbConnectionConfig c) =>
                        c.copyWith(maxIpPortCount: _nonNegInt(v)),
                  ),
                ),
                _numRow(
                  id: 'downloads.video_setting_torrent_ban_time',
                  label: t.video_setting_torrent_ban_time,
                  value: c.banTimeMinutes,
                  hint: t.video_setting_torrent_ban_time_hint,
                  onChanged: (String v) => _commit(
                    (QbConnectionConfig c) =>
                        c.copyWith(banTimeMinutes: _nonNegInt(v)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ],
    ];
    // 宽度规则（BUG-1858，用户 2026-08-25 拍板）：分组吃满宿主给的内容宽度，
    // 行与输入框的左右基线由分组行自己承接（与其它设置分类同一条），本组件不再
    // 额外缩进或限宽。宿主（设置详情页 / 浏览 › 下载设置页）负责页边距。
    return SizedBox(
      key: const ValueKey<String>('torrent-settings-content'),
      width: double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: groups,
      ),
    );
  }
}
