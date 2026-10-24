/// 「我库里的例句」的开关与设置项（设置 → 查词）。
library;

import 'dart:async';

import 'package:fushi/src/corpus/library_corpus_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';
import 'package:material_ui/material_ui.dart';

/// 开关当前值（D-L2：默认开，全在本机、不上传）。
bool librarySentencesEnabledOf(AppModel app) => app.librarySentencesEnabled;

Future<void> setLibrarySentencesEnabled(AppModel app, bool value) async {
  await app.prefsRepo.setPref(kLibrarySentencesEnabledPrefKey, value);
  LibraryCorpusService.instance.onEnabledChanged();
}

/// 设置页状态行：建索引中显示进度，否则显示已索引的规模（还没打开索引时不显示）。
String? librarySentencesStatusText() {
  final LibraryCorpusProgress p = LibraryCorpusService.instance.progress.value;
  if (p.running) {
    return t.lookup_library_sentences_indexing(
      done: '${p.done}',
      total: '${p.total}',
    );
  }
  final int? sentences = p.sentences;
  final int? documents = p.documents;
  if (sentences == null || documents == null) return null;
  return t.lookup_library_sentences_status(
    sentences: '$sentences',
    documents: '$documents',
  );
}

/// 设置 → 查词 →「我库里的例句」分组的两项：开关 + 重建索引。
List<SettingsItem> librarySentencesSettingsItems() => <SettingsItem>[
  SettingsSwitchItem(
    id: 'lookup.library_sentences',
    title: t.lookup_library_sentences_enabled,
    subtitle: t.lookup_library_sentences_enabled_hint,
    icon: Icons.format_quote_outlined,
    value: (SettingsContext c) => librarySentencesEnabledOf(c.appModel),
    onChanged: (SettingsContext c, bool value) async {
      await setLibrarySentencesEnabled(c.appModel, value);
      c.refresh();
    },
    defaultValue: true,
  ),
  SettingsActionItem(
    id: 'lookup.library_sentences_rebuild',
    title: t.lookup_library_sentences_rebuild,
    subtitle: t.lookup_library_sentences_rebuild_hint,
    subtitleBuilder: (SettingsContext c) => librarySentencesStatusText(),
    icon: Icons.manage_history_outlined,
    visible: (SettingsContext c) => librarySentencesEnabledOf(c.appModel),
    cli: SettingsCliAction(
      run: (SettingsContext c, Map<String, String> args) async {
        unawaited(LibraryCorpusService.instance.rebuild());
        return <String, Object?>{'started': true};
      },
    ),
    onTap: (SettingsContext c) async {
      // 重建排在喂入队列里跑（可能要几分钟），这里不等它。
      unawaited(LibraryCorpusService.instance.rebuild());
      final BuildContext ctx = c.context;
      if (ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          FushiSnackBar(
            content: Text(t.lookup_library_sentences_rebuild_started),
          ),
        );
      }
      c.refresh();
    },
  ),
];
