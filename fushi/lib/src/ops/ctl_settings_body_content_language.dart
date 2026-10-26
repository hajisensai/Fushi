import 'package:flutter/widgets.dart';
import 'package:fushi/src/lookup/lookup_ime_channel.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/ops/ctl_library_entries.dart';
import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// 内容语言选择器（[showContentLanguagePicker]）在设置里的两处全局用法在控制
/// 通道上的条目：外观 › 默认内容语言、查词 › 查词输入法语言。
///
/// 写入调对话框 `onSelected` 里同一组偏好 setter 与副作用（阅读器实时刷新 /
/// 原生查词输入框持久化）。条目级的内容语言（词典 / 游戏）走 `fushi_cli dict` /
/// `game` 已有命令。
const String kCtlContentLanguageUnset = 'none';

/// 可写的取值：[kCtlContentLanguageUnset] + 选择器的全部 BCP-47 标签。
List<String> ctlContentLanguageOptions() => <String>[
  kCtlContentLanguageUnset,
  for (final ({String? tag, String label}) option in kContentLanguageOptions)
    if (option.tag != null) option.tag!,
];

/// CLI 写法 → 偏好值（空串 = 未设置）。不在选择器清单里的抛 [ArgumentError]。
String parseCtlContentLanguage(String raw) {
  final String value = raw.trim();
  if (value.isEmpty || value.toLowerCase() == kCtlContentLanguageUnset) {
    return '';
  }
  for (final String option in ctlContentLanguageOptions()) {
    if (option.toLowerCase() == value.toLowerCase()) return option;
  }
  throw ArgumentError(
    '不认识的内容语言「$raw」；可选：${ctlContentLanguageOptions().join(' / ')}',
  );
}

String _shown(String stored) =>
    stored.isEmpty ? kCtlContentLanguageUnset : stored;

String get _help =>
    '${ctlContentLanguageOptions().join(' / ')}（$kCtlContentLanguageUnset = 未设置）';

List<CtlBodyPage> buildCtlContentLanguageBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: t.settings_destination_appearance,
    items: <SettingsItem>[
      SettingsCustomItem(
        id: 'appearance.content_language.cli.value',
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.settings_content_language_title,
        cliValue: SettingsCliValue(
          read: (SettingsContext c) =>
              _shown(c.appModel.prefsRepo.defaultContentLanguage),
          write: (SettingsContext c, String raw) async {
            await c.appModel.prefsRepo.setDefaultContentLanguage(
              parseCtlContentLanguage(raw),
            );
            // 与设置页同一个副作用（notifyReaderSettingsChanged）：活着的阅读器
            // 按新语言重选字体链。
            ReaderFushiSource.onSettingsChangedLive?.call();
            c.refresh();
          },
          help: _help,
          options: (SettingsContext _) => ctlContentLanguageOptions(),
        ),
      ),
      SettingsActionItem(
        id: kCtlItemLanguageId,
        title: t.book_language_action,
        subtitle: t.book_language_description,
        cli: SettingsCliAction(
          run: _itemLanguage,
          params: <SettingsCliParam>[
            const SettingsCliParam(
              'key',
              help:
                  '条目键 book:<bookKey> / srt:<uid> / video:<bookUid>（library ls）',
            ),
            SettingsCliParam(
              'language',
              help:
                  '${ctlContentLanguageOptions().where((String o) => o != kCtlContentLanguageUnset).join(' / ')}'
                  ' 或 $kCtlItemLanguageAuto（恢复自动）；省略 = 只查询',
              required: false,
            ),
          ],
        ),
        // 逃生口条目不进设置页渲染；界面入口是书架 / 视频库条目菜单。
        onTap: (SettingsContext _) =>
            throw UnsupportedError('$kCtlItemLanguageId 只经控制通道执行'),
      ),
    ],
  ),
  CtlBodyPage(
    breadcrumb: t.settings_destination_lookup,
    items: <SettingsItem>[
      SettingsCustomItem(
        id: 'lookup.ime_language.cli.value',
        builder: (SettingsContext _) => const SizedBox.shrink(),
        searchTitle: t.settings_lookup_ime_language_title,
        cliValue: SettingsCliValue(
          read: (SettingsContext c) =>
              _shown(c.appModel.prefsRepo.lookupImeLanguage),
          write: (SettingsContext c, String raw) async {
            final String tag = parseCtlContentLanguage(raw);
            await c.appModel.prefsRepo.setLookupImeLanguage(tag);
            // 原生查词界面（Android 悬浮 / 弹窗词典的 EditText）读这份持久化值。
            await LookupImeChannel.persistForNativeSurfaces(
              tag.isEmpty ? null : tag,
            );
            c.refresh();
          },
          help: _help,
          options: (SettingsContext _) => ctlContentLanguageOptions(),
        ),
      ),
      SettingsActionItem(
        id: 'lookup.ime_language.cli.check',
        title: '${t.settings_lookup_ime_language_title} · check',
        subtitle: '查询当前设定的输入法语言在系统里是否有可用输入法',
        cli: const SettingsCliAction(run: _checkImeLanguage),
        onTap: (SettingsContext c) =>
            _checkImeLanguage(c, const <String, String>{}),
      ),
    ],
  ),
];

/// 条目级内容语言：书架 / 视频库条目右键「内容语言」（[showContentLanguagePicker]
/// 的 `onSelected`）写的同一列。`key` 与 `fushi_cli library ls` 的条目键同形。
const String kCtlItemLanguageId = 'library.content_language.cli.item';

/// 条目语言里「清除手动指定、恢复自动」的写法（列写回 null）。
const String kCtlItemLanguageAuto = 'auto';

Future<Object?> _itemLanguage(
  SettingsContext c,
  Map<String, String> args,
) async {
  final LibraryCtlKey? key = LibraryCtlKey.tryParse(args['key']!.trim());
  if (key == null || key.store == LibraryCtlStore.game) {
    throw ArgumentError(
      'key 写成 book:<bookKey> / srt:<uid> / video:<bookUid>'
      '（library ls 的条目键；游戏用 fushi_cli game 的 language 选项）',
    );
  }
  final FushiDatabase db = c.appModel.database;
  Future<String?> current() async => switch (key.store) {
    LibraryCtlStore.book => (await db.getEpubBook(key.id))?.language,
    LibraryCtlStore.srt => (await db.getSrtBookByUid(key.id))?.language,
    LibraryCtlStore.video => (await db.getVideoBookByBookUid(key.id))?.language,
    LibraryCtlStore.game => throw StateError('unreachable'),
  };
  final bool exists = switch (key.store) {
    LibraryCtlStore.book => await db.getEpubBook(key.id) != null,
    LibraryCtlStore.srt => await db.getSrtBookByUid(key.id) != null,
    LibraryCtlStore.video => await db.getVideoBookByBookUid(key.id) != null,
    LibraryCtlStore.game => false,
  };
  if (!exists) throw ArgumentError('没有条目「${key.wire}」');
  final String? raw = args['language']?.trim();
  if (raw != null && raw.isNotEmpty) {
    final String? tag = raw.toLowerCase() == kCtlItemLanguageAuto
        ? null
        : _requireItemTag(raw);
    switch (key.store) {
      case LibraryCtlStore.book:
        await db.updateEpubBookLanguage(key.id, tag);
      case LibraryCtlStore.srt:
        await db.updateSrtBookLanguage(key.id, tag);
      case LibraryCtlStore.video:
        await db.updateVideoBookLanguage(key.id, tag);
      case LibraryCtlStore.game:
        break;
    }
  }
  return <String, Object?>{
    'key': key.wire,
    'language': await current() ?? kCtlItemLanguageAuto,
  };
}

String _requireItemTag(String raw) {
  final String tag = parseCtlContentLanguage(raw);
  if (tag.isEmpty) {
    throw ArgumentError('条目语言用 $kCtlItemLanguageAuto 恢复自动，不收「$raw」');
  }
  return tag;
}

Future<Object?> _checkImeLanguage(
  SettingsContext c,
  Map<String, String> _,
) async {
  final String tag = c.appModel.prefsRepo.lookupImeLanguage;
  return <String, Object?>{
    'language': _shown(tag),
    // 与设置页选完后的提示同一判据：系统里没装这个输入法时设了也没反应。
    'available': await LookupImeChannel.isLanguageAvailable(tag),
  };
}
