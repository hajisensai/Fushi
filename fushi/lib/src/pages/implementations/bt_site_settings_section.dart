/// 「BT 站」设置区：用户自己添加的 BT 站增 / 改 / 删 / 启停 / 重新检测 / 测试搜索。
///
/// Fushi 不内置任何 BT 站。用户只填地址，站点是哪种接口由添加时的自动探测决定
/// （`bt_site_probe.dart`），那是内部字段：**界面上不出现任何站名或接口格式**，
/// 探测失败也只给中性提示（所有者 2026-10 拍板，规避风险，不是疏漏）。
///
/// 列表行只显示名称（没起名就是主机名），从不显示完整地址——地址里可能带站点
/// passkey。地址只在编辑对话框的输入框里出现。
///
/// 读写经 [BtSiteSettingsStore] 注入：生产路径是 [AppBtSiteSettingsStore]
/// （`AppModel.setBtSites` 会重建下载流水线与发现源并唤醒暂停的订阅），widget
/// 测试换假 store，不碰网络。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/bt_site_probe.dart';

/// BT 站设置的读写口。
abstract interface class BtSiteSettingsStore {
  List<BtSiteConfig> load();

  Future<void> save(List<BtSiteConfig> sites);

  /// 自动识别站点；失败抛 [BtSiteProbeException]（或底层异常）。
  Future<BtSiteProbeResult> detect(
    String url, {
    required bool allowInsecureHttp,
  });

  /// 用站点生效的第一个视频域搜一次，返回条数；没有视频域时 null。
  Future<int?> testSearch(BtSiteConfig site);
}

class AppBtSiteSettingsStore implements BtSiteSettingsStore {
  const AppBtSiteSettingsStore(this.appModel);

  final AppModel appModel;

  @override
  List<BtSiteConfig> load() => appModel.btSites;

  @override
  Future<void> save(List<BtSiteConfig> sites) => appModel.setBtSites(sites);

  @override
  Future<BtSiteProbeResult> detect(
    String url, {
    required bool allowInsecureHttp,
  }) => appModel.detectBtSite(url, allowInsecureHttp: allowInsecureHttp);

  @override
  Future<int?> testSearch(BtSiteConfig site) => appModel.testBtSiteSearch(site);
}

/// 媒体域的界面名。
String btSiteDomainLabel(BtSiteDomain domain) => switch (domain) {
  BtSiteDomain.anime => t.bt_site_domain_anime,
  BtSiteDomain.movie => t.bt_site_domain_movie,
  BtSiteDomain.tv => t.bt_site_domain_tv,
  BtSiteDomain.novel => t.bt_site_domain_novel,
  BtSiteDomain.audiobook => t.bt_site_domain_audiobook,
  BtSiteDomain.manga => t.bt_site_domain_manga,
  BtSiteDomain.game => t.bt_site_domain_game,
};

/// 探测失败的中性提示（不列格式、不举站名）。
String btSiteProbeErrorMessage(Object error) {
  if (error is BtSiteProbeException) {
    return switch (error.error) {
      BtSiteProbeError.invalidUrl => t.bt_site_url_invalid_error,
      BtSiteProbeError.insecureHttp => t.bt_site_url_insecure_error,
      BtSiteProbeError.unrecognized => t.bt_site_detect_failed_error,
      BtSiteProbeError.timedOut => t.bt_site_detect_timeout_error,
    };
  }
  if (error is TimeoutException) return t.bt_site_detect_timeout_error;
  return t.bt_site_detect_failed_error;
}

/// 按枚举声明序拼域名（Set 迭代序不稳定）。
String _domainsLine(Iterable<BtSiteDomain> domains) {
  final Set<BtSiteDomain> set = domains.toSet();
  return BtSiteDomain.values
      .where(set.contains)
      .map(btSiteDomainLabel)
      .join(' · ');
}

class BtSiteSettingsSection extends ConsumerStatefulWidget {
  const BtSiteSettingsSection({super.key, this.store});

  /// 测试注入口；null = 从 [AppModel] 构造。
  final BtSiteSettingsStore? store;

  @override
  ConsumerState<BtSiteSettingsSection> createState() =>
      _BtSiteSettingsSectionState();
}

class _BtSiteSettingsSectionState extends ConsumerState<BtSiteSettingsSection> {
  List<BtSiteConfig> _sites = const <BtSiteConfig>[];
  bool _loaded = false;
  bool _saveFailed = false;

  /// 行内的「重新检测 / 测试搜索」进度与结论，按站点 id。
  final Map<String, _RowStatus> _status = <String, _RowStatus>{};

  BtSiteSettingsStore? _resolveStore() {
    final BtSiteSettingsStore? injected = widget.store;
    if (injected != null) return injected;
    final AppModel appModel = ref.read(appProvider);
    return appModel.isPreferencesReady
        ? AppBtSiteSettingsStore(appModel)
        : null;
  }

  Future<bool> _save(List<BtSiteConfig> next) async {
    final BtSiteSettingsStore? store = _resolveStore();
    if (store == null) return false;
    final List<BtSiteConfig> previous = _sites;
    setState(() => _sites = List<BtSiteConfig>.unmodifiable(next));
    try {
      await store.save(next);
      if (mounted && _saveFailed) setState(() => _saveFailed = false);
      return true;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('BtSiteSettings.save', error, stack);
      if (mounted) {
        setState(() {
          _sites = previous;
          _saveFailed = true;
        });
      }
      return false;
    }
  }

  Future<void> _add() async {
    final BtSiteSettingsStore? store = _resolveStore();
    if (store == null) return;
    final BtSiteConfig? created = await showAppDialog<BtSiteConfig>(
      context: context,
      builder: (BuildContext context) => BtSiteEditDialog(store: store),
    );
    if (created == null || !mounted) return;
    await _save(<BtSiteConfig>[..._sites, created]);
  }

  Future<void> _edit(BtSiteConfig site) async {
    final BtSiteSettingsStore? store = _resolveStore();
    if (store == null) return;
    final BtSiteConfig? edited = await showAppDialog<BtSiteConfig>(
      context: context,
      builder: (BuildContext context) =>
          BtSiteEditDialog(store: store, initial: site),
    );
    if (edited == null || !mounted) return;
    setState(() => _status.remove(site.id));
    await _save(<BtSiteConfig>[
      for (final BtSiteConfig s in _sites) s.id == site.id ? edited : s,
    ]);
  }

  Future<void> _delete(BtSiteConfig site) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.bt_site_delete_confirm_title,
      message: site.displayName,
      confirmLabel: t.dialog_delete,
      icon: FushiIcons.delete,
      destructive: true,
    );
    if (!ok || !mounted) return;
    setState(() => _status.remove(site.id));
    await _save(<BtSiteConfig>[
      for (final BtSiteConfig s in _sites)
        if (s.id != site.id) s,
    ]);
  }

  Future<void> _setEnabled(BtSiteConfig site, bool enabled) =>
      _save(<BtSiteConfig>[
        for (final BtSiteConfig s in _sites)
          s.id == site.id ? s.copyWith(enabled: enabled) : s,
      ]);

  Future<void> _redetect(BtSiteConfig site) async {
    final BtSiteSettingsStore? store = _resolveStore();
    if (store == null) return;
    setState(() => _status[site.id] = const _RowStatus.running());
    _RowStatus result;
    try {
      final BtSiteProbeResult probe = await store.detect(
        site.baseUrl.toString(),
        allowInsecureHttp: site.allowInsecureHttp,
      );
      final BtSiteConfig next = probe.applyTo(
        id: site.id,
        name: site.name,
        domains: site.domains,
        enabled: site.enabled,
        allowInsecureHttp: site.allowInsecureHttp,
      );
      if (!mounted) return;
      final bool saved = await _save(<BtSiteConfig>[
        for (final BtSiteConfig s in _sites) s.id == site.id ? next : s,
      ]);
      result = saved
          ? _RowStatus.done(ok: true, message: t.bt_site_redetect_done_status)
          : _RowStatus.done(ok: false, message: t.video_external_save_error);
    } on Object catch (error) {
      result = _RowStatus.done(
        ok: false,
        message: btSiteProbeErrorMessage(error),
      );
    }
    if (mounted) setState(() => _status[site.id] = result);
  }

  Future<void> _testSearch(BtSiteConfig site) async {
    final BtSiteSettingsStore? store = _resolveStore();
    if (store == null) return;
    setState(() => _status[site.id] = const _RowStatus.running());
    _RowStatus result;
    try {
      final int? count = await store.testSearch(site);
      result = count == null
          ? _RowStatus.done(
              ok: false,
              message: t.bt_site_domains_unmatched_status,
            )
          : _RowStatus.done(
              ok: true,
              message: t.bt_site_test_search_result(n: count),
            );
    } on Object {
      // 不记异常正文：请求地址里可能带 passkey。
      result = _RowStatus.done(
        ok: false,
        message: t.bt_site_test_search_failed_error,
      );
    }
    if (mounted) setState(() => _status[site.id] = result);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.store == null) {
      // 偏好就绪前不渲染（同 AList / OPDS 设置区）；就绪后 rebuild 再读一次。
      final AppModel appModel = ref.watch(appProvider);
      if (!appModel.isPreferencesReady) return const SizedBox.shrink();
    }
    if (!_loaded) {
      final BtSiteSettingsStore? store = _resolveStore();
      if (store == null) return const SizedBox.shrink();
      _loaded = true;
      _sites = store.load();
    }
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('bt-site-settings'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SourceSectionHeading(
            title: t.bt_site_section_title,
            hint: t.bt_site_section_hint,
            icon: FushiIcons.travelExplore,
          ),
          if (_saveFailed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: FushiInlineNotice(
                key: const ValueKey<String>('bt-site-save-failed'),
                message: t.video_external_save_error,
                severity: FushiNoticeSeverity.error,
                icon: FushiIcons.error,
              ),
            ),
          if (_sites.isEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: FushiInlineNotice(
                key: const ValueKey<String>('bt-site-empty'),
                message: t.bt_site_empty_hint,
              ),
            ),
          FushiEntranceScope(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (int index = 0; index < _sites.length; index++)
                  FushiStaggeredEntrance(
                    key: ValueKey<String>(
                      'bt-site-entrance-${_sites[index].id}',
                    ),
                    index: index,
                    child: _row(_sites[index]),
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FushiFilledButton.tonalIcon(
              key: const ValueKey<String>('bt-site-add'),
              onPressed: _add,
              icon: const FushiIcon(FushiIcons.add),
              label: Text(t.bt_site_add_action),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _row(BtSiteConfig site) {
    final ThemeData theme = Theme.of(context);
    final _RowStatus? status = _status[site.id];
    final bool running = status?.running ?? false;
    final Set<BtSiteDomain> effective = site.effectiveDomains;
    final bool unmatched = site.domains.any(
      (BtSiteDomain d) => !effective.contains(d),
    );
    final String domainsLine = _domainsLine(effective);
    return FushiCard(
      key: ValueKey<String>('bt-site-${site.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      onTap: running ? null : () => unawaited(_edit(site)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      site.displayName,
                      key: ValueKey<String>('bt-site-${site.id}-title'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium,
                    ),
                    if (domainsLine.isNotEmpty)
                      Text(
                        domainsLine,
                        key: ValueKey<String>('bt-site-${site.id}-domains'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (unmatched)
                      Text(
                        t.bt_site_domains_unmatched_status,
                        key: ValueKey<String>('bt-site-${site.id}-unmatched'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              Semantics(
                label: t.bt_site_enabled_label,
                child: FushiSwitch.adaptive(
                  key: ValueKey<String>('bt-site-${site.id}-enabled'),
                  value: site.enabled,
                  onChanged: running
                      ? null
                      : (bool value) => unawaited(_setEnabled(site, value)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              FushiTextButton.icon(
                key: ValueKey<String>('bt-site-${site.id}-edit'),
                onPressed: running ? null : () => unawaited(_edit(site)),
                icon: const FushiIcon(FushiIcons.edit, size: 18),
                label: Text(t.dialog_edit),
              ),
              FushiTextButton.icon(
                key: ValueKey<String>('bt-site-${site.id}-redetect'),
                onPressed: running ? null : () => unawaited(_redetect(site)),
                icon: const FushiIcon(FushiIcons.refresh, size: 18),
                label: Text(t.bt_site_redetect_action),
              ),
              FushiTextButton.icon(
                key: ValueKey<String>('bt-site-${site.id}-test'),
                onPressed: running || site.effectiveVideoCategories.isEmpty
                    ? null
                    : () => unawaited(_testSearch(site)),
                icon: const FushiIcon(FushiIcons.search, size: 18),
                label: Text(t.bt_site_test_search_action),
              ),
              FushiTextButton.icon(
                key: ValueKey<String>('bt-site-${site.id}-delete'),
                onPressed: running ? null : () => unawaited(_delete(site)),
                icon: const FushiIcon(FushiIcons.delete, size: 18),
                label: Text(t.dialog_delete),
              ),
              if (running)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
            ],
          ),
          if (status != null && !status.running)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: FushiInlineNotice(
                key: ValueKey<String>('bt-site-${site.id}-status'),
                severity: status.ok
                    ? FushiNoticeSeverity.success
                    : FushiNoticeSeverity.error,
                message: status.message,
              ),
            ),
        ],
      ),
    );
  }
}

/// 添加 / 编辑一个 BT 站。点保存时按需探测（新增、改了地址、改了明文 HTTP），
/// 探测成功才返回配置；只改名称 / 域 / 启用不探测。返回 null = 取消。
class BtSiteEditDialog extends StatefulWidget {
  const BtSiteEditDialog({super.key, required this.store, this.initial});

  final BtSiteSettingsStore store;

  /// null = 新增。
  final BtSiteConfig? initial;

  @override
  State<BtSiteEditDialog> createState() => _BtSiteEditDialogState();
}

class _BtSiteEditDialogState extends State<BtSiteEditDialog> {
  late final TextEditingController _url = TextEditingController(
    text: widget.initial?.baseUrl.toString() ?? '',
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late Set<BtSiteDomain> _domains = <BtSiteDomain>{...?widget.initial?.domains};
  late bool _enabled = widget.initial?.enabled ?? true;
  late bool _allowInsecureHttp = widget.initial?.allowInsecureHttp ?? false;

  bool _detecting = false;
  String? _error;
  bool _domainsError = false;

  /// 每次保存递增；对话框被关掉 / 再次保存后，旧探测晚回的结果不落地。
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _url.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _generation++;
    _url.removeListener(_onUrlChanged);
    _url.dispose();
    _name.dispose();
    super.dispose();
  }

  void _onUrlChanged() => setState(() => _error = null);

  /// 明文 HTTP 开关只在地址是 http 时需要；已开着的也显示（好关掉）。
  bool get _showAllowHttp =>
      _allowInsecureHttp ||
      _url.text.trim().toLowerCase().startsWith('http://');

  bool get _needsProbe {
    final BtSiteConfig? initial = widget.initial;
    if (initial == null) return true;
    return _url.text.trim() != initial.baseUrl.toString() ||
        _allowInsecureHttp != initial.allowInsecureHttp;
  }

  Future<void> _submit() async {
    if (_detecting) return;
    if (_domains.isEmpty) {
      setState(() => _domainsError = true);
      return;
    }
    final BtSiteConfig? initial = widget.initial;
    final String name = _name.text.trim();
    if (initial != null && !_needsProbe) {
      Navigator.of(
        context,
      ).pop(initial.copyWith(name: name, domains: _domains, enabled: _enabled));
      return;
    }
    final int generation = ++_generation;
    setState(() {
      _detecting = true;
      _error = null;
    });
    try {
      final BtSiteProbeResult result = await widget.store.detect(
        _url.text.trim(),
        allowInsecureHttp: _allowInsecureHttp,
      );
      if (!mounted || generation != _generation) return;
      Navigator.of(context).pop(
        result.applyTo(
          id: initial?.id ?? newBtSiteId(),
          name: name,
          domains: _domains,
          enabled: _enabled,
          allowInsecureHttp: _allowInsecureHttp,
        ),
      );
    } on Object catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _detecting = false;
        _error = btSiteProbeErrorMessage(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.travelExplore),
      title: Text(
        widget.initial == null ? t.bt_site_add_action : t.bt_site_edit_title,
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiTextFieldControl(
            key: const ValueKey<String>('bt-site-dialog-url'),
            controller: _url,
            autofocus: widget.initial == null,
            enabled: !_detecting,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: t.bt_site_url_label,
              hintText: t.bt_site_url_hint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FushiTextFieldControl(
            key: const ValueKey<String>('bt-site-dialog-name'),
            controller: _name,
            enabled: !_detecting,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => unawaited(_submit()),
            decoration: InputDecoration(
              labelText: t.bt_site_name_label,
              hintText: t.bt_site_name_hint,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(t.bt_site_domains_label, style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final BtSiteDomain domain in BtSiteDomain.values)
                FushiFilterChip(
                  key: ValueKey<String>('bt-site-dialog-domain-${domain.name}'),
                  label: Text(btSiteDomainLabel(domain)),
                  selected: _domains.contains(domain),
                  onSelected: _detecting
                      ? null
                      : (bool selected) => setState(() {
                          _domains = <BtSiteDomain>{..._domains};
                          if (selected) {
                            _domains.add(domain);
                          } else {
                            _domains.remove(domain);
                          }
                          if (_domains.isNotEmpty) _domainsError = false;
                        }),
                ),
            ],
          ),
          if (_domainsError)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                t.bt_site_domains_required_error,
                key: const ValueKey<String>('bt-site-dialog-domains-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          FushiSwitchListTile.adaptive(
            key: const ValueKey<String>('bt-site-dialog-enabled'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.bt_site_enabled_label),
            value: _enabled,
            onChanged: _detecting
                ? null
                : (bool value) => setState(() => _enabled = value),
          ),
          if (_showAllowHttp)
            FushiSwitchListTile.adaptive(
              key: const ValueKey<String>('bt-site-dialog-allow-http'),
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(t.bt_site_allow_http_label),
              value: _allowInsecureHttp,
              onChanged: _detecting
                  ? null
                  : (bool value) => setState(() {
                      _allowInsecureHttp = value;
                      _error = null;
                    }),
            ),
          if (_detecting)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                key: const ValueKey<String>('bt-site-dialog-detecting'),
                children: <Widget>[
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: FushiCircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(t.bt_site_detecting_status)),
                ],
              ),
            )
          else if (_error case final String error)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FushiInlineNotice(
                key: const ValueKey<String>('bt-site-dialog-error'),
                severity: FushiNoticeSeverity.error,
                message: error,
              ),
            ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          key: const ValueKey<String>('bt-site-dialog-cancel'),
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('bt-site-dialog-save'),
          label: t.dialog_save,
          kind: FushiDialogActionKind.primary,
          onPressed: _detecting || _url.text.trim().isEmpty
              ? null
              : () => unawaited(_submit()),
        ),
      ],
    );
  }
}

class _RowStatus {
  const _RowStatus.running() : running = true, ok = false, message = '';

  const _RowStatus.done({required this.ok, required this.message})
    : running = false;

  final bool running;
  final bool ok;
  final String message;
}
