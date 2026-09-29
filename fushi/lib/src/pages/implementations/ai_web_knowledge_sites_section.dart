/// 「设置 › AI › 联网资料」里的自定义 MediaWiki 站点列表：每站一行（启用开关 +
/// 删除），末尾「添加 MediaWiki 站点」弹窗填名称与 `api.php` 地址。
///
/// 内置站是 schema 里的声明式开关；自定义站是可增删的记录列表，schema 的 item 树
/// 表达不了，所以挂在 `SettingsCustomItem` 上（与 AI 提供商列表同一条切法）。
/// 启用状态与内置站共用同一个偏好（`ai_web_knowledge_sources`），开关逻辑只有
/// [setWebKnowledgeSiteEnabled] 一份。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/ai/web_knowledge.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/utils.dart';

/// 站点在界面上的名字：内置站按 id 取 i18n（语种用母语写，不随界面语言变），
/// 自定义站用用户填的名称。
String webKnowledgeSiteDisplayLabel(WebKnowledgeSite site) => switch (site.id) {
  'wikipedia_zh' => t.ai_web_knowledge_wikipedia_zh,
  'wikipedia_ja' => t.ai_web_knowledge_wikipedia_ja,
  'wikipedia_en' => t.ai_web_knowledge_wikipedia_en,
  'moegirl' => t.ai_web_knowledge_moegirl,
  'ann' => t.ai_web_knowledge_ann,
  'tvmaze' => t.ai_web_knowledge_tvmaze,
  _ => site.label,
};

/// 开 / 关一个站点（内置或自定义）。读当前启用集（从未写过时即全开）再改一位写回，
/// 所以第一次关掉某站时其它站保持开着。
Future<void> setWebKnowledgeSiteEnabled(
  PreferencesRepository prefs,
  String siteId, {
  required bool enabled,
}) {
  final Set<String> next = prefs.aiWebKnowledgeEnabledSiteIds;
  if (enabled) {
    next.add(siteId);
  } else {
    next.remove(siteId);
  }
  return prefs.setAiWebKnowledgeEnabledSiteIds(next);
}

class AiWebKnowledgeCustomSitesSection extends ConsumerStatefulWidget {
  const AiWebKnowledgeCustomSitesSection({super.key});

  @override
  ConsumerState<AiWebKnowledgeCustomSitesSection> createState() =>
      _AiWebKnowledgeCustomSitesSectionState();
}

class _AiWebKnowledgeCustomSitesSectionState
    extends ConsumerState<AiWebKnowledgeCustomSitesSection> {
  @override
  Widget build(BuildContext context) {
    final AppModel appModel = ref.watch(appProvider);
    if (!appModel.isPreferencesReady) return const SizedBox.shrink();
    final PreferencesRepository prefs = appModel.prefsRepo;
    final List<WebKnowledgeSite> sites = prefs.aiWebKnowledgeCustomSites;
    final Set<String> enabled = prefs.aiWebKnowledgeEnabledSiteIds;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: FushiDesignTokens.of(context).spacing.rowHorizontal,
      ),
      child: Column(
        key: const ValueKey<String>('ai-web-knowledge-custom-sites'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final WebKnowledgeSite site in sites)
            FushiListItem(
              key: ValueKey<String>('ai-web-knowledge-site-${site.id}'),
              leading: const Icon(Icons.travel_explore),
              title: Text(site.label),
              subtitle: Text(
                site.endpoint.toString(),
                overflow: TextOverflow.ellipsis,
              ),
              // 整行 Enter / 点击 = 切换启用，焦点遍历不必再单独停在开关上。
              onTap: () =>
                  _setEnabled(prefs, site, enabled: !enabled.contains(site.id)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  ExcludeFocus(
                    child: Switch.adaptive(
                      key: ValueKey<String>(
                        'ai-web-knowledge-site-${site.id}-enabled',
                      ),
                      value: enabled.contains(site.id),
                      onChanged: (bool value) =>
                          _setEnabled(prefs, site, enabled: value),
                    ),
                  ),
                  IconButton(
                    key: ValueKey<String>(
                      'ai-web-knowledge-site-${site.id}-remove',
                    ),
                    tooltip: t.ai_web_knowledge_custom_remove,
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () => unawaited(_remove(prefs, site)),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              key: const ValueKey<String>('ai-web-knowledge-custom-add'),
              onPressed: () => unawaited(_add(prefs)),
              icon: const Icon(Icons.add),
              label: Text(t.ai_web_knowledge_custom_add),
            ),
          ),
        ],
      ),
    );
  }

  void _setEnabled(
    PreferencesRepository prefs,
    WebKnowledgeSite site, {
    required bool enabled,
  }) {
    unawaited(
      setWebKnowledgeSiteEnabled(
        prefs,
        site.id,
        enabled: enabled,
      ).then((_) => _refresh()),
    );
  }

  Future<void> _remove(
    PreferencesRepository prefs,
    WebKnowledgeSite site,
  ) async {
    // 先拿删之前的启用集：删掉站点后再写启用集时，已不存在的 id 会被顺手清掉。
    final Set<String> enabled = prefs.aiWebKnowledgeEnabledSiteIds;
    await prefs.setAiWebKnowledgeCustomSites(<WebKnowledgeSite>[
      for (final WebKnowledgeSite other in prefs.aiWebKnowledgeCustomSites)
        if (other.id != site.id) other,
    ]);
    await prefs.setAiWebKnowledgeEnabledSiteIds(enabled..remove(site.id));
    _refresh();
  }

  Future<void> _add(PreferencesRepository prefs) async {
    final WebKnowledgeSite? site = await showDialog<WebKnowledgeSite>(
      context: context,
      builder: (BuildContext dialogContext) => const _AddSiteDialog(),
    );
    if (site == null) return;
    // 新站默认启用：启用集写过（用户动过开关）时要显式加进去，否则它进了列表却是关的。
    final Set<String> enabled = prefs.aiWebKnowledgeEnabledSiteIds;
    await prefs.setAiWebKnowledgeCustomSites(<WebKnowledgeSite>[
      ...prefs.aiWebKnowledgeCustomSites,
      site,
    ]);
    await prefs.setAiWebKnowledgeEnabledSiteIds(enabled..add(site.id));
    _refresh();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }
}

class _AddSiteDialog extends StatefulWidget {
  const _AddSiteDialog();

  @override
  State<_AddSiteDialog> createState() => _AddSiteDialogState();
}

class _AddSiteDialogState extends State<_AddSiteDialog> {
  String _label = '';
  String _endpoint = '';
  bool _showError = false;

  void _submit() {
    final WebKnowledgeSite? site = WebKnowledgeSite.custom(
      id: '$kWebKnowledgeCustomIdPrefix${DateTime.now().microsecondsSinceEpoch}',
      label: _label,
      endpoint: _endpoint,
    );
    if (site == null) {
      setState(() => _showError = true);
      return;
    }
    Navigator.of(context).pop(site);
  }

  @override
  Widget build(BuildContext context) {
    return FushiDialogFrame(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
      child: Column(
        key: const ValueKey<String>('ai-web-knowledge-custom-dialog'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              t.ai_web_knowledge_custom_add,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          SettingsFormField(
            key: const ValueKey<String>('ai-web-knowledge-custom-name'),
            label: t.ai_web_knowledge_custom_name,
            helperText: t.ai_web_knowledge_custom_name_hint,
            onChanged: (String value) => _label = value,
          ),
          SettingsFormField(
            key: const ValueKey<String>('ai-web-knowledge-custom-endpoint'),
            label: t.ai_web_knowledge_custom_endpoint,
            helperText: t.ai_web_knowledge_custom_endpoint_hint,
            keyboardType: TextInputType.url,
            errorText: _showError
                ? t.ai_web_knowledge_custom_endpoint_invalid
                : null,
            onChanged: (String value) => setState(() {
              _endpoint = value;
              _showError = false;
            }),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                key: const ValueKey<String>('ai-web-knowledge-custom-cancel'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(t.dialog_cancel),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey<String>('ai-web-knowledge-custom-confirm'),
                onPressed: _submit,
                child: Text(t.dialog_add),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
