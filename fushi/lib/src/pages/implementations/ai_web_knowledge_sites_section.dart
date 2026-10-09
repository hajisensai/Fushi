/// 「设置 › AI › 联网资料」里的自定义 MediaWiki 站点列表：每站一行（启用开关 +
/// 删除），末尾「添加 MediaWiki 站点」弹窗填名称与 `api.php` 地址。
///
/// 内置站是 schema 里的声明式开关；自定义站是可增删的记录列表，schema 的 item 树
/// 表达不了条数变化，所以挂在多行的 `SettingsCustomItem.rows` 上：每条记录仍是
/// 分组里的独立一行。
/// 启用状态与内置站共用同一个偏好（`ai_web_knowledge_sources`），开关逻辑只有
/// [setWebKnowledgeSiteEnabled] 一份。
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
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

/// 自定义站点的设置行：每站一行（整行切换启用 + 开关 + 删除），末尾「添加」行。
///
/// 返回的是**行列表**而不是一整块：schema 里经 `SettingsCustomItem.rows` 挂进
/// 「联网资料」分组，由渲染器拆成与同组内置站开关行并列的独立行（MD3 分段卡 /
/// Apple inset 分隔线都由共享分组画，本文件不再手画分隔线）。记录增删、开关后
/// 调 [refresh] 重建。
List<Widget> buildAiWebKnowledgeCustomSiteRows(
  BuildContext context,
  PreferencesRepository prefs,
  VoidCallback refresh,
) {
  final List<WebKnowledgeSite> sites = prefs.aiWebKnowledgeCustomSites;
  final Set<String> enabled = prefs.aiWebKnowledgeEnabledSiteIds;
  void setEnabled(WebKnowledgeSite site, {required bool value}) {
    unawaited(
      setWebKnowledgeSiteEnabled(
        prefs,
        site.id,
        enabled: value,
      ).then((_) => refresh()),
    );
  }

  return <Widget>[
    for (final WebKnowledgeSite site in sites)
      AdaptiveSettingsRow(
        key: ValueKey<String>('ai-web-knowledge-site-${site.id}'),
        icon: FushiIcons.travelExplore,
        showIcon: true,
        title: site.label,
        subtitle: site.endpoint.toString(),
        subtitleMaxLines: 1,
        // 整行 Enter / 点击 = 切换启用，焦点遍历不必再单独停在开关上。
        onTap: () => setEnabled(site, value: !enabled.contains(site.id)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ExcludeFocus(
              child: KeyedSubtree(
                key: ValueKey<String>(
                  'ai-web-knowledge-site-${site.id}-enabled',
                ),
                // 与 AdaptiveSettingsSwitchRow 同一枚开关：Apple 下是设置页
                // 的小号系统开关，MD3 下是 adaptive 开关。
                child: isGlassDesign(context)
                    ? glassSettingsSwitch(
                        context: context,
                        value: enabled.contains(site.id),
                        onChanged: (bool value) =>
                            setEnabled(site, value: value),
                      )
                    : FushiSwitch.adaptive(
                        value: enabled.contains(site.id),
                        onChanged: (bool value) =>
                            setEnabled(site, value: value),
                      ),
              ),
            ),
            FushiIconButtonControl(
              key: ValueKey<String>(
                'ai-web-knowledge-site-${site.id}-remove',
              ),
              tooltip: t.ai_web_knowledge_custom_remove,
              icon: const FushiIcon(FushiIcons.delete),
              onPressed: () => unawaited(
                _removeWebKnowledgeSite(prefs, site).then((_) => refresh()),
              ),
            ),
          ],
        ),
      ),
    AdaptiveSettingsRow(
      key: const ValueKey<String>('ai-web-knowledge-custom-add'),
      icon: FushiIcons.add,
      showIcon: true,
      title: t.ai_web_knowledge_custom_add,
      onTap: () => unawaited(_addWebKnowledgeSite(context, prefs, refresh)),
    ),
  ];
}

/// 独立宿主（测试 / schema 之外的页面）用的自定义站点块：同一组行放进一个共享
/// 设置分组，分段 / 分隔线与 schema 渲染一致。schema 里不经过它，直接挂
/// [buildAiWebKnowledgeCustomSiteRows]。
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
    return AdaptiveSettingsSection(
      key: const ValueKey<String>('ai-web-knowledge-custom-sites'),
      children: buildAiWebKnowledgeCustomSiteRows(
        context,
        appModel.prefsRepo,
        _refresh,
      ),
    );
  }

  void _refresh() {
    if (mounted) setState(() {});
  }
}

Future<void> _removeWebKnowledgeSite(
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
}

Future<void> _addWebKnowledgeSite(
  BuildContext context,
  PreferencesRepository prefs,
  VoidCallback refresh,
) async {
  final WebKnowledgeSite? site = await showAppDialog<WebKnowledgeSite>(
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
  refresh();
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    // 走共享弹窗骨架（FushiModalSheetFrame：标题行 + 正文 + 底部操作区），与
    // name_input_dialog 等同族弹窗同一几何；不再手排 titleMedium 标题 + 裸 Row。
    return FushiDialogFrame(
      maxWidth: 480,
      scrollable: false,
      child: FushiModalSheetFrame(
        key: const ValueKey<String>('ai-web-knowledge-custom-dialog'),
        title: t.ai_web_knowledge_custom_add,
        leadingIcon: FushiIcons.travelExplore,
        scrollable: true,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
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
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            FushiTextButton(
              key: const ValueKey<String>('ai-web-knowledge-custom-cancel'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(t.dialog_cancel),
            ),
            FushiFilledButton(
              key: const ValueKey<String>('ai-web-knowledge-custom-confirm'),
              onPressed: _submit,
              child: Text(t.dialog_add),
            ),
          ],
        ),
      ),
    );
  }
}
