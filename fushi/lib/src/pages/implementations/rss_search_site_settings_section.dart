/// 「RSS 搜索站」设置区：用户自配 BT 搜索站的增删改、启用开关与真搜自检。
///
/// 仓库不内置任何 BT 搜索站、也不给预设或模板：一个站 = 用户填的名字 + 带
/// `{query}` 的搜索地址模板 + 参与的媒体域（视频三域进视频资源搜索与订阅，
/// 小说 / 有声书 / 漫画 / 游戏进发现页）。校验只有一份——引擎
/// [validateRssSearchUrlTemplate] / [RssSearchSiteConfig] 构造器，这里只把
/// 结论映射成本地化提示。
///
/// 一个 BT 来源都没有（RSS 站与 Torznab 都没配）时顶部给出两条路的说明：直接
/// 加 RSS 站（简单，但结果少、不能排序和翻页），或自建 Jackett / Prowlarr 用
/// Torznab 接入（搜索更完整）。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/media/discovery/discovery_labels.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/source_toggle_section.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_provider.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';

/// 输入框里的通用示例：只示意 `{query}` 放哪，**不是**任何真实站点。
const String kRssSearchUrlTemplateExample = 'https://example.com/rss?q={query}';

/// 设置区的读写端口（测试注入假实现；生产走 [AppRssSearchSiteSettingsStore]）。
abstract interface class RssSearchSiteSettingsStore {
  /// 当前 RSS 站清单。
  List<RssSearchSiteConfig> loadSites();

  /// 是否配了至少一个 Torznab 索引器（决定是否显示「一个来源都没有」说明）。
  bool hasTorznabIndexers();

  Future<void> saveSites(List<RssSearchSiteConfig> sites);

  /// 用 [query] 真搜一次 [site] 的第一页，返回条数；失败抛
  /// [ExternalProviderFailure]（已脱敏）。
  Future<int> testSite(RssSearchSiteConfig site, String query);
}

class AppRssSearchSiteSettingsStore implements RssSearchSiteSettingsStore {
  const AppRssSearchSiteSettingsStore(this.appModel);

  final AppModel appModel;

  @override
  List<RssSearchSiteConfig> loadSites() => appModel.prefsRepo.resourceRssSites;

  @override
  bool hasTorznabIndexers() =>
      appModel.prefsRepo.videoResourceTorznabConfigs.isNotEmpty;

  @override
  Future<void> saveSites(List<RssSearchSiteConfig> sites) =>
      appModel.setResourceRssSites(sites);

  @override
  Future<int> testSite(RssSearchSiteConfig site, String query) async {
    // 与真实搜索同一个网络层与同一个 http 工厂（全应用代理装配）。
    final RssSearchClient client = RssSearchClient(
      client: await appModel.createDownloadHttpClient(),
    );
    try {
      return (await client.searchSite(site, query)).length;
    } finally {
      client.close();
    }
  }
}

/// 媒体域的用户可见名（视频三域沿用视频发现页的分类文案，其余沿用发现页）。
String rssSearchDomainLabel(RssSearchDomain domain) {
  final VideoDiscoveryCategory? video = domain.videoCategory;
  if (video != null) {
    return switch (video) {
      VideoDiscoveryCategory.anime => t.media_tracking_anime,
      VideoDiscoveryCategory.movie => t.collection_relation_movie,
      VideoDiscoveryCategory.tv => t.series,
    };
  }
  return discoveryMediaKindLabel(domain.discoveryKind!);
}

/// URL 模板的本地化错误提示；合法返回 null。判据全在
/// [validateRssSearchUrlTemplate]，这里只区分该给哪句话。
String? rssSearchUrlTemplateError(
  String template, {
  required bool allowInsecureHttp,
}) {
  final String value = template.trim();
  if (validateRssSearchUrlTemplate(
        value,
        allowInsecureHttp: allowInsecureHttp,
      ) ==
      null) {
    return null;
  }
  if (value.isEmpty) return t.video_rss_url_required;
  if (!value.contains(kRssSearchQueryPlaceholder)) {
    return t.video_rss_url_missing_query;
  }
  if (!allowInsecureHttp &&
      validateRssSearchUrlTemplate(value, allowInsecureHttp: true) == null) {
    return t.video_rss_url_needs_http_optin;
  }
  return t.video_rss_url_invalid;
}

class RssSearchSiteSettingsSection extends ConsumerStatefulWidget {
  const RssSearchSiteSettingsSection({super.key, this.store});

  /// 测试注入口；null = 从 [AppModel] 构造。
  final RssSearchSiteSettingsStore? store;

  @override
  ConsumerState<RssSearchSiteSettingsSection> createState() =>
      _RssSearchSiteSettingsSectionState();
}

class _RssSearchSiteSettingsSectionState
    extends ConsumerState<RssSearchSiteSettingsSection> {
  RssSearchSiteSettingsStore? _store;
  List<RssSearchSiteConfig> _sites = <RssSearchSiteConfig>[];
  bool _hasTorznab = false;
  bool _saveFailed = false;
  Future<void> _saveTail = Future<void>.value();
  final Map<String, _TestState> _tests = <String, _TestState>{};

  RssSearchSiteSettingsStore? _resolveStore() {
    final RssSearchSiteSettingsStore? injected = widget.store;
    if (injected != null) return injected;
    final AppModel appModel = ref.watch(appProvider);
    return appModel.isPreferencesReady
        ? AppRssSearchSiteSettingsStore(appModel)
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final RssSearchSiteSettingsStore? store = _resolveStore();
    if (store == null) return const SizedBox.shrink();
    // 只在第一次拿到 store 时装载：之后以本地列表为准（保存是异步的，重新从
    // store 读会把还没落盘的改动弹回去）。
    if (_store == null) {
      _store = store;
      _sites = List<RssSearchSiteConfig>.of(store.loadSites());
      _hasTorznab = store.hasTorznabIndexers();
    }
    final bool empty = _sites.isEmpty && !_hasTorznab;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: FushiEntranceScope(
        child: Column(
          key: const ValueKey<String>('video-rss-sites'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SourceSectionHeading(
              title: t.video_rss_settings_title,
              hint: t.video_rss_settings_hint,
              icon: FushiIcons.travelExplore,
            ),
            if (_saveFailed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: FushiInlineNotice(
                  message: t.video_external_save_error,
                  severity: FushiNoticeSeverity.error,
                  icon: FushiIcons.error,
                ),
              ),
            if (empty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: FushiInlineNotice(
                  key: const ValueKey<String>('video-rss-empty'),
                  icon: FushiIcons.info,
                  title: t.video_rss_empty_title,
                  message: t.video_rss_empty_hint,
                ),
              ),
            for (int index = 0; index < _sites.length; index++)
              FushiStaggeredEntrance(
                key: ValueKey<String>('video-rss-site-${_sites[index].id}'),
                index: index,
                child: _card(index),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: FushiPressScale(
                child: FushiFilledButton.tonalIcon(
                  key: const ValueKey<String>('video-rss-add'),
                  onPressed: () => unawaited(_edit(null)),
                  icon: const FushiIcon(FushiIcons.add),
                  label: Text(t.video_rss_add),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _card(int index) {
    final RssSearchSiteConfig site = _sites[index];
    final _TestState? test = _tests[site.id];
    final String host =
        Uri.tryParse(site.buildSearchUri('q').toString())?.host ?? '';
    final String domains = <String>[
      for (final RssSearchDomain domain in RssSearchDomain.values)
        if (site.domains.contains(domain)) rssSearchDomainLabel(domain),
    ].join(' · ');
    return FushiCard(
      variant: FushiCardVariant.outlined,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              FushiListLeadingIcon(
                FushiIcons.travelExplore,
                shape: FushiLeadingShape.square,
                tone: site.enabled
                    ? FushiCardTone.primary
                    : FushiCardTone.secondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FushiSwitchListTile.adaptive(
                  key: ValueKey<String>('video-rss-$index-enabled'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    site.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    domains.isEmpty ? host : '$host · $domains',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  value: site.enabled,
                  onChanged: (bool value) =>
                      _replace(index, site.copyWith(enabled: value)),
                ),
              ),
              FushiIconButtonControl(
                key: ValueKey<String>('video-rss-$index-edit'),
                tooltip: t.dialog_edit,
                onPressed: () => unawaited(_edit(index)),
                icon: const FushiIcon(FushiIcons.edit),
              ),
              FushiIconButtonControl(
                key: ValueKey<String>('video-rss-$index-remove'),
                tooltip: t.video_external_remove,
                onPressed: () {
                  setState(() {
                    _tests.remove(site.id);
                    _sites.removeAt(index);
                  });
                  unawaited(_save());
                },
                icon: const FushiIcon(FushiIcons.delete),
              ),
            ],
          ),
          Row(
            children: <Widget>[
              FushiOutlinedButton.icon(
                key: ValueKey<String>('video-rss-$index-test'),
                onPressed: test?.running == true
                    ? null
                    : () => unawaited(_test(site)),
                icon: test?.running == true
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: FushiCircularProgressIndicator(strokeWidth: 2),
                      )
                    : const FushiIcon(FushiIcons.search),
                label: Text(t.video_rss_test),
              ),
              if (test != null && !test.running) ...<Widget>[
                const SizedBox(width: 12),
                Expanded(
                  child: FushiInlineNotice(
                    key: ValueKey<String>('video-rss-$index-test-result'),
                    severity: test.ok
                        ? FushiNoticeSeverity.success
                        : FushiNoticeSeverity.error,
                    message: test.message,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  void _replace(int index, RssSearchSiteConfig next) {
    setState(() {
      _sites[index] = next;
      _tests.remove(next.id);
    });
    unawaited(_save());
  }

  Future<void> _save() {
    final RssSearchSiteSettingsStore? store = _store;
    if (store == null) return Future<void>.value();
    final List<RssSearchSiteConfig> snapshot =
        List<RssSearchSiteConfig>.unmodifiable(_sites);
    _saveTail = _saveTail.then((_) async {
      try {
        await store.saveSites(snapshot);
        if (mounted && _saveFailed) setState(() => _saveFailed = false);
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'RssSearchSiteSettings.save',
          error,
          stack,
        );
        if (mounted) setState(() => _saveFailed = true);
      }
    });
    return _saveTail;
  }

  /// [index] null = 新增。对话框返回 null = 取消。
  Future<void> _edit(int? index) async {
    final RssSearchSiteConfig? original = index == null ? null : _sites[index];
    final RssSearchSiteConfig? result =
        await showAppDialog<RssSearchSiteConfig>(
          context: context,
          builder: (_) => RssSearchSiteDialog(
            initial: original,
            newId: 'rss-${DateTime.now().microsecondsSinceEpoch}',
          ),
        );
    if (result == null || !mounted) return;
    setState(() {
      if (index == null) {
        _sites.add(result);
      } else {
        _sites[index] = result;
      }
      _tests.remove(result.id);
    });
    await _save();
  }

  /// 真搜自检：问一组关键词，用它搜第一页，报条数或脱敏后的失败原因。模板
  /// 拼错、站点要 Cloudflare 验证、passkey 失效，表现全是「搜不到东西」，没有
  /// 自检用户无从分辨。
  Future<void> _test(RssSearchSiteConfig site) async {
    final RssSearchSiteSettingsStore? store = _store;
    if (store == null) return;
    final String? query = await showFushiTextInputDialog(
      context: context,
      title: t.video_rss_test,
      labelText: t.video_rss_test_query,
      icon: FushiIcons.search,
    );
    if (query == null || query.isEmpty || !mounted) return;
    setState(() => _tests[site.id] = const _TestState.running());
    _TestState result;
    try {
      final int count = await store.testSite(site, query);
      result = _TestState.done(
        ok: true,
        message: t.video_rss_test_result(n: count),
      );
    } on ExternalProviderFailure catch (failure) {
      result = _TestState.done(
        ok: false,
        message: t.video_rss_test_failed(reason: _failureReason(failure)),
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('RssSearchSiteSettings.test', error, stack);
      result = _TestState.done(
        ok: false,
        message: t.video_rss_test_failed(
          reason: t.video_resource_failure_other,
        ),
      );
    }
    if (!mounted) return;
    setState(() => _tests[site.id] = result);
  }

  static String _failureReason(ExternalProviderFailure failure) {
    final String reason = switch (failure.kind) {
      ExternalProviderFailureKind.timeout => t.video_resource_failure_timeout,
      ExternalProviderFailureKind.network => t.video_resource_failure_network,
      ExternalProviderFailureKind.rateLimited ||
      ExternalProviderFailureKind.quotaExceeded =>
        t.video_resource_failure_rate_limited,
      _ => t.video_resource_failure_other,
    };
    final int? status = failure.statusCode;
    return status == null ? reason : '$reason · HTTP $status';
  }
}

/// 新增 / 编辑一个 RSS 搜索站：名称、URL 模板（实时校验）、适用媒体域多选、
/// 「允许不安全 HTTP」。确认返回合法配置，取消返回 null。
class RssSearchSiteDialog extends StatefulWidget {
  const RssSearchSiteDialog({super.key, this.initial, required this.newId});

  /// null = 新增。
  final RssSearchSiteConfig? initial;

  /// 新增时用的 id。
  final String newId;

  @override
  State<RssSearchSiteDialog> createState() => _RssSearchSiteDialogState();
}

class _RssSearchSiteDialogState extends State<RssSearchSiteDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.initial?.name ?? '',
  );
  late final TextEditingController _url = TextEditingController(
    text: widget.initial?.urlTemplate ?? '',
  );
  late Set<RssSearchDomain> _domains = <RssSearchDomain>{
    ...?widget.initial?.domains,
  };
  late bool _allowInsecureHttp = widget.initial?.allowInsecureHttp ?? false;

  @override
  void initState() {
    super.initState();
    _name.addListener(_changed);
    _url.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    super.dispose();
  }

  String? get _urlError => _url.text.trim().isEmpty
      ? null
      : rssSearchUrlTemplateError(
          _url.text,
          allowInsecureHttp: _allowInsecureHttp,
        );

  RssSearchSiteConfig? get _result {
    if (_name.text.trim().isEmpty || _domains.isEmpty) return null;
    try {
      final RssSearchSiteConfig? initial = widget.initial;
      return initial == null
          ? RssSearchSiteConfig(
              id: widget.newId,
              name: _name.text.trim(),
              urlTemplate: _url.text,
              domains: _domains,
              allowInsecureHttp: _allowInsecureHttp,
            )
          : initial.copyWith(
              name: _name.text.trim(),
              urlTemplate: _url.text,
              domains: _domains,
              allowInsecureHttp: _allowInsecureHttp,
            );
    } on ArgumentError {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final RssSearchSiteConfig? result = _result;
    final ThemeData theme = Theme.of(context);
    return FushiAlertDialog(
      icon: const FushiDialogHeroIcon(icon: FushiIcons.travelExplore),
      title: Text(
        widget.initial == null ? t.video_rss_add : t.video_rss_edit_title,
      ),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FushiTextFieldControl(
            key: const ValueKey<String>('video-rss-dialog-name'),
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              labelText: t.video_rss_name,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FushiTextFieldControl(
            key: const ValueKey<String>('video-rss-dialog-url'),
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: t.video_rss_url_template,
              hintText: kRssSearchUrlTemplateExample,
              helperText: t.video_rss_url_template_hint,
              helperMaxLines: 3,
              errorText: _urlError,
              errorMaxLines: 3,
              border: const OutlineInputBorder(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Text(t.video_rss_domains, style: theme.textTheme.labelLarge),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              for (final RssSearchDomain domain in RssSearchDomain.values)
                FushiFilterChip(
                  key: ValueKey<String>(
                    'video-rss-dialog-domain-${domain.name}',
                  ),
                  label: Text(rssSearchDomainLabel(domain)),
                  selected: _domains.contains(domain),
                  onSelected: (bool selected) => setState(() {
                    _domains = <RssSearchDomain>{..._domains};
                    if (selected) {
                      _domains.add(domain);
                    } else {
                      _domains.remove(domain);
                    }
                  }),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              _domains.isEmpty
                  ? t.video_rss_domains_required
                  : t.video_rss_domains_hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: _domains.isEmpty
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          FushiSwitchListTile.adaptive(
            key: const ValueKey<String>('video-rss-dialog-insecure-http'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(t.video_external_insecure_http),
            subtitle: Text(t.video_external_insecure_http_hint),
            value: _allowInsecureHttp,
            onChanged: (bool value) =>
                setState(() => _allowInsecureHttp = value),
          ),
        ],
      ),
      actions: <Widget>[
        FushiDialogAction(
          label: t.dialog_cancel,
          onPressed: () => Navigator.of(context).pop(),
        ),
        FushiDialogAction(
          key: const ValueKey<String>('video-rss-dialog-save'),
          label: t.dialog_save,
          kind: FushiDialogActionKind.primary,
          onPressed: result == null
              ? null
              : () => Navigator.of(context).pop(result),
        ),
      ],
    );
  }
}

class _TestState {
  const _TestState.running() : running = true, ok = false, message = '';

  const _TestState.done({required this.ok, required this.message})
    : running = false;

  final bool running;
  final bool ok;
  final String message;
}
