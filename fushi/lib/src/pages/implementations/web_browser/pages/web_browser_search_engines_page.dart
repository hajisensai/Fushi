import 'dart:async';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/web_browser/pages/web_browser_page_common.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/web_browser/web_browser_sites.dart';
import 'package:fushi/utils.dart';

/// 搜索引擎：选默认；增删改自定义引擎（内置三家不可删改）。
class WebBrowserSearchEnginesPage extends StatefulWidget {
  const WebBrowserSearchEnginesPage({required this.prefs, super.key});

  final PrefStore prefs;

  @override
  State<WebBrowserSearchEnginesPage> createState() =>
      _WebBrowserSearchEnginesPageState();
}

enum _EngineAction { edit, delete }

class _WebBrowserSearchEnginesPageState
    extends State<WebBrowserSearchEnginesPage> {
  late List<WebBrowserCustomSearchEngine> _customs =
      readWebBrowserCustomSearchEngines(widget.prefs);
  late WebBrowserSearchProvider _selected = readWebBrowserSearchProvider(
    widget.prefs,
  );

  void _refresh() => setState(() {
    _customs = readWebBrowserCustomSearchEngines(widget.prefs);
    _selected = readWebBrowserSearchProvider(widget.prefs);
  });

  Future<void> _select(WebBrowserSearchProvider provider) async {
    await writeWebBrowserSearchProvider(widget.prefs, provider);
    if (mounted) _refresh();
  }

  String? _templateError(String v) => isValidWebBrowserSearchTemplate(v)
      ? null
      : t.web_browser_search_engine_template_invalid;

  Future<void> _edit([WebBrowserCustomSearchEngine? existing]) async {
    final List<String>? values = await showWebBrowserFormDialog(
      context: context,
      title: existing == null
          ? t.web_browser_search_engine_add
          : t.web_browser_search_engine_edit,
      icon: FushiIcons.search,
      fields: <WebBrowserFormField>[
        WebBrowserFormField(label: t.name, initialValue: existing?.name ?? ''),
        WebBrowserFormField(
          label: t.web_browser_search_engine_template,
          initialValue: existing?.searchTemplate ?? '',
          hintText: 'https://example.com/search?q=%s',
          keyboardType: TextInputType.url,
          validator: _templateError,
        ),
        WebBrowserFormField(
          label: t.web_browser_search_engine_suggest_template,
          initialValue: existing?.suggestTemplate ?? '',
          optional: true,
          keyboardType: TextInputType.url,
          validator: _templateError,
        ),
      ],
    );
    if (values == null) return;
    final WebBrowserCustomSearchEngine engine = WebBrowserCustomSearchEngine(
      id: existing?.id ?? newWebBrowserCustomSearchEngineId(_customs),
      name: values[0],
      searchTemplate: values[1],
      suggestTemplate: values[2].isEmpty ? null : values[2],
    );
    await upsertWebBrowserCustomSearchEngine(widget.prefs, engine);
    if (mounted) _refresh();
  }

  Future<void> _delete(WebBrowserCustomSearchEngine engine) async {
    final bool ok = await showFushiConfirmDialog(
      context: context,
      title: t.web_browser_search_engine_delete_confirm(name: engine.name),
      icon: FushiIcons.delete,
      confirmLabel: t.options_delete,
      destructive: true,
    );
    if (!ok) return;
    await removeWebBrowserCustomSearchEngine(widget.prefs, engine.id);
    if (mounted) _refresh();
  }

  Widget _tile(WebBrowserSearchProvider provider, {Widget? menu}) {
    final bool selected = provider.prefValue == _selected.prefValue;
    final String? subtitle = provider is WebBrowserCustomSearchEngine
        ? provider.searchTemplate
        : null;
    return FushiListItem(
      key: ValueKey<String>('web_browser_search_engine_${provider.prefValue}'),
      selected: selected,
      leading: FushiListLeadingIcon(
        selected ? FushiIcons.check : FushiIcons.search,
      ),
      title: Text(provider.label),
      subtitle: subtitle == null ? null : Text(subtitle),
      subtitleMaxLines: 1,
      onTap: () => unawaited(_select(provider)),
      trailing: menu,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FushiPageScaffold(
      title: t.web_browser_search_engine,
      actions: <Widget>[
        FushiIconButton(
          key: const ValueKey<String>('web_browser_search_engine_add'),
          icon: FushiIcons.add,
          tooltip: t.web_browser_search_engine_add,
          alwaysVisible: true,
          onTap: () => unawaited(_edit()),
        ),
      ],
      body: webBrowserPageListView(
        replayKey: 0,
        key: const ValueKey<String>('web_browser_search_engines_list'),
        children: <Widget>[
          FushiSectionTitle.group(
            t.web_browser_search_engine_builtin,
            padding: const EdgeInsets.fromLTRB(32, 8, 32, 6),
          ),
          FushiStaggeredEntrance(
            index: 0,
            child: FushiGroupedList(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: <Widget>[
                for (final WebBrowserSearchEngine e
                    in WebBrowserSearchEngine.values)
                  _tile(e),
              ],
            ),
          ),
          if (_customs.isNotEmpty) ...<Widget>[
            FushiSectionTitle.group(
              t.web_browser_search_engine_custom,
              padding: const EdgeInsets.fromLTRB(32, 16, 32, 6),
            ),
            FushiStaggeredEntrance(
              index: 1,
              child: FushiGroupedList(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: <Widget>[
                  for (final WebBrowserCustomSearchEngine e in _customs)
                    _tile(
                      e,
                      menu: FushiOverflowMenu<_EngineAction>(
                        key: ValueKey<String>(
                          'web_browser_search_engine_menu_${e.id}',
                        ),
                        tooltip: t.common_more_actions,
                        onSelected: (_EngineAction a) => unawaited(
                          a == _EngineAction.edit ? _edit(e) : _delete(e),
                        ),
                        items: <PopupMenuEntry<_EngineAction>>[
                          FushiPopupMenuItem<_EngineAction>(
                            value: _EngineAction.edit,
                            label: t.options_edit,
                            icon: FushiIcons.edit,
                          ),
                          FushiPopupMenuItem<_EngineAction>(
                            value: _EngineAction.delete,
                            label: t.options_delete,
                            icon: FushiIcons.delete,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
