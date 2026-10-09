import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/sync/hidden_remote_books.dart';
import 'package:fushi/src/sync/remote_book_client.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_settings_schema.dart' show syncBackendLabel;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteBookInfo;
import 'package:fushi_engine/sync/sync_backend_type.dart';

/// 「已从本机移除的远端书」找回列表（反馈 nvlhtczbro，所有者 2026-10-10 拍板）。
///
/// 数据来自偏好 `hidden_remote_books`（[PreferencesRepository.hiddenRemoteBooks]），
/// 按来源分组。每行「恢复」= 从隐藏清单删掉这条，书架订阅了偏好变更，占位卡随即
/// 回来；「清除记录」= 同样删掉这条（远端那本书已经不存在时用它收拾）。页头「全部
/// 恢复」清空整张清单。
///
/// [remoteClientLoader] 非空时会问一次当前远端来源的书目：来源对得上、书目里已
/// 没有这本的行标「远端已不存在」。拉取失败 / 来源不是当前来源时不下结论。
class HiddenRemoteBooksPage extends StatefulWidget {
  const HiddenRemoteBooksPage({
    required this.prefs,
    this.remoteClientLoader,
    super.key,
  });

  final PreferencesRepository prefs;
  final Future<RemoteBookClient?> Function()? remoteClientLoader;

  @override
  State<HiddenRemoteBooksPage> createState() => _HiddenRemoteBooksPageState();
}

class _HiddenRemoteBooksPageState extends State<HiddenRemoteBooksPage> {
  /// 当前远端来源及其书目里的身份键；null = 未知（没有来源 / 拉取失败）。
  String? _liveSourceId;
  Set<String>? _liveRemoteIds;

  @override
  void initState() {
    super.initState();
    widget.prefs.addListener(_onPrefs);
    _probeRemote();
  }

  @override
  void dispose() {
    widget.prefs.removeListener(_onPrefs);
    super.dispose();
  }

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  Future<void> _probeRemote() async {
    final Future<RemoteBookClient?> Function()? loader =
        widget.remoteClientLoader;
    if (loader == null) return;
    try {
      final RemoteBookClient? client = await loader();
      if (client == null) return;
      final List<RemoteBookInfo> books = await client.listRemoteBooks();
      if (!mounted) return;
      setState(() {
        _liveSourceId = client.remoteLibrarySourceId;
        _liveRemoteIds = <String>{
          for (final RemoteBookInfo b in books) b.downloadId,
        };
      });
    } catch (e) {
      debugPrint('[hidden-remote-books] remote probe failed: $e');
    }
  }

  bool _isMissing(HiddenRemoteBook book) =>
      _liveSourceId == book.sourceId &&
      _liveRemoteIds != null &&
      !_liveRemoteIds!.contains(book.remoteId);

  Future<void> _drop(Set<String> keys) =>
      widget.prefs.setHiddenRemoteBooks(<HiddenRemoteBook>[
        for (final HiddenRemoteBook h in widget.prefs.hiddenRemoteBooks)
          if (!keys.contains(h.key)) h,
      ]);

  String _sourceTitle(List<HiddenRemoteBook> group) {
    final HiddenRemoteBook first = group.first;
    if (first.sourceId == kInterconnectRemoteLibrarySourceId) {
      final String? host = first.sourceLabel;
      return t.remote_hidden_books_source_interconnect(
        name: host ?? t.sync_backend_fushi_server,
      );
    }
    const String cloudPrefix = 'cloud:';
    if (first.sourceId.startsWith(cloudPrefix)) {
      final String name = first.sourceId.substring(cloudPrefix.length);
      final SyncBackendType? type = SyncBackendType.values
          .where((SyncBackendType v) => v.name == name)
          .firstOrNull;
      return t.remote_hidden_books_source_cloud(
        name: type == null ? name : syncBackendLabel(type),
      );
    }
    return first.sourceLabel ?? first.sourceId;
  }

  @override
  Widget build(BuildContext context) {
    final List<HiddenRemoteBook> all = widget.prefs.hiddenRemoteBooks;
    final Map<String, List<HiddenRemoteBook>> groups =
        <String, List<HiddenRemoteBook>>{};
    for (final HiddenRemoteBook h in all) {
      (groups[h.sourceId] ??= <HiddenRemoteBook>[]).add(h);
    }
    return SettingsKitScaffold(
      title: t.remote_hidden_books_title,
      leadingIcon: FushiIcons.visibilityOff,
      leadingTone: SettingsIconTone.gray,
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) {
            final double top = MediaQuery.paddingOf(context).top;
            if (all.isEmpty) {
              return ListView(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, top, 12, 12),
                children: <Widget>[
                  SettingsEmptyState(
                    key: const ValueKey<String>('hidden_remote_books_empty'),
                    icon: FushiIcons.books,
                    title: t.remote_hidden_books_empty_title,
                    message: t.remote_hidden_books_empty_message,
                  ),
                ],
              );
            }
            final List<Widget> children = <Widget>[];
            for (final List<HiddenRemoteBook> group in groups.values) {
              children.add(SettingsSectionHeader(_sourceTitle(group)));
              for (int i = 0; i < group.length; i++) {
                children.add(_row(group[i], i, group.length));
              }
            }
            children.add(
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Center(
                  child: FushiFilledButton.tonalIcon(
                    key: const ValueKey<String>(
                      'hidden_remote_books_restore_all_button',
                    ),
                    onPressed: () => widget.prefs.setHiddenRemoteBooks(
                      const <HiddenRemoteBook>[],
                    ),
                    icon: const FushiIcon(FushiIcons.undo),
                    label: Text(t.remote_hidden_books_restore_all),
                  ),
                ),
              ),
            );
            return FushiEntranceScope(
              child: ListView.builder(
                controller: controller,
                padding: EdgeInsets.fromLTRB(12, top, 12, 24),
                itemCount: children.length,
                itemBuilder: fushiStaggeredItemBuilder(
                  (BuildContext context, int index) => children[index],
                ),
              ),
            );
          },
    );
  }

  Widget _row(HiddenRemoteBook book, int index, int count) {
    final bool missing = _isMissing(book);
    final String safe = book.key.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    return FushiGroupedListItem(
      key: ValueKey<String>('hidden_remote_book_$safe'),
      index: index,
      count: count,
      child: FushiListItem(
        leading: FushiListLeadingIcon(
          missing ? FushiIcons.cloudOff : FushiIcons.books,
          shape: FushiLeadingShape.square,
          tone: missing ? FushiCardTone.error : FushiCardTone.secondary,
        ),
        title: Text(book.title),
        subtitle: missing ? Text(t.remote_hidden_books_missing) : null,
        // 两个动作效果都是把这条移出隐藏清单，按语境只给一个：书还在（或不知道）
        // → 「恢复」，占位卡回到书架；远端已没有 → 「清除记录」，只是收拾清单。
        trailing: missing
            ? FushiTextButton(
                key: ValueKey<String>('hidden_remote_book_forget_$safe'),
                onPressed: () => _drop(<String>{book.key}),
                child: Text(t.remote_hidden_books_forget),
              )
            : FushiTextButton(
                key: ValueKey<String>('hidden_remote_book_restore_$safe'),
                onPressed: () => _drop(<String>{book.key}),
                child: Text(t.remote_hidden_books_restore),
              ),
      ),
    );
  }
}
