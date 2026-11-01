/// 复习（SRS）给不在 Riverpod 图里的宿主（app 外查词窗的 deferred 桥、Fushi API
/// 服务器的 `/api/srs/*`）用的入口。
///
/// [SrsAppHost.current] 只在复习模块开着时由 `srs_app_runtime.dart` 装上，模块关着时
/// 为 null——调用方据此直接回 null / 404，不打开任何数据库。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_remote_review.dart';
import 'package:fushi_srs/fushi_srs.dart' show SrsTermQuery;
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/srs/srs_term_status_bridge.dart';
import 'package:fushi/src/sync/fushi_api_server.dart' show SrsExtensionApi;
import 'package:fushi/utils.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';

class SrsAppHost implements SrsExtensionApi {
  SrsAppHost({
    required this.readStore,
    required this.openNote,
    required this.openBrowse,
    this.remoteReview,
  });

  /// 当前（复习模块开着时装上的）宿主入口；null = 模块关着。
  static SrsAppHost? current;

  /// 当前 profile 的 SRS 副本（打开失败时为 null）。
  final Future<SrsDbStore?> Function() readStore;

  /// 打开一条笔记的编辑页；导航器不可用时返回 false。
  final Future<bool> Function(String noteId) openNote;

  /// 打开浏览页。
  final Future<bool> Function() openBrowse;

  /// 互联 host 的复习远程刷卡（`/api/srs/review/*`，docs/specs/2026-11-01-srs-remote-review-design.md）。
  /// 只有 [current] 那份带它；按配置给浏览器扩展建的实例不带（null）。
  final SrsRemoteReviewService? remoteReview;

  /// 弹窗 / 扩展的词状态回包（见 srs_term_status_bridge.dart）。
  @override
  Future<Map<String, Object?>?> termStatus(
    String expression,
    String reading,
  ) async => srsLookupTermStatusPayload(
    await readStore(),
    expression: expression,
    reading: reading,
  );

  /// 批量词状态（一轮可见批次一次）：回包与 [terms] 等长同序。
  @override
  Future<List<Map<String, Object?>?>> termStatuses(
    List<SrsTermQuery> terms,
  ) async => srsLookupTermStatusPayloads(await readStore(), terms);

  /// 点复习标记：按 noteId（缺失时由 cardId 反查）打开笔记编辑页。
  @override
  Future<bool> openCard({required String cardId, String? noteId}) async {
    String? id = noteId == null || noteId.isEmpty ? null : noteId;
    if (id == null && cardId.isNotEmpty) {
      final SrsDbStore? store = await readStore();
      if (store != null) id = await srsNoteIdForCard(store, cardId);
    }
    if (id == null) return false;
    return openNote(id);
  }
}

/// 已压栈（含正在压）的笔记编辑页对应的笔记 id。
///
/// 防重入：查词弹窗的复习标记 / ↗、浏览器扩展、AnkiConnect `guiEditNote` 都经
/// [srsPushNoteEditor] 打开编辑页，而桥调用在 push 发出后就返回（不等页面加载完），
/// 弹窗按钮自己的 busy 守卫只挡得住同一次桥往返——连点同一个词会叠出好几页同一条
/// 笔记的编辑页，每页各自跑一遍加载。同一条笔记的编辑页还开着时再请求打开，直接视为
/// 已打开（回 true），不再叠页；页面出栈后摘掉登记。
final Set<String> _srsOpenNoteEditors = <String>{};

/// 测试用：清掉防重入登记（测试之间不共享进程级状态）。
@visibleForTesting
void debugResetSrsNoteEditorLock() => _srsOpenNoteEditors.clear();

/// 在 [navigator] 上压一页笔记编辑（弹窗 / 外部工具打开卡片）。同一条笔记的编辑页
/// 已经开着时不再叠页（见 [_srsOpenNoteEditors]）。
///
/// [overrides]：编辑页按别的配置的复习副本工作时（浏览器扩展所选的非激活配置，见
/// [srsProfileScopeOverrides]），页面套一层带这些覆盖的 [ProviderScope]；编辑页再打开的
/// 页面 / 抽屉经 [srsInheritProviderScope] 沿用同一层。空 = App 激活配置的复习（原样）。
///
/// [pageBuilder] 只给测试换页面用；缺省 = [SrsNoteEditorPage]。
Future<bool> srsPushNoteEditor(
  NavigatorState? navigator,
  String noteId, {
  List<Override> overrides = const <Override>[],
  @visibleForTesting Widget Function(String noteId)? pageBuilder,
}) async {
  if (navigator == null || !navigator.mounted) return false;
  if (!_srsOpenNoteEditors.add(noteId)) return true;
  final Widget Function(String) build =
      pageBuilder ?? (String id) => SrsNoteEditorPage(noteId: id);
  unawaited(
    navigator
        .push<void>(
          adaptivePageRoute<void>(
            context: navigator.context,
            builder: (BuildContext context) => overrides.isEmpty
                ? build(noteId)
                : ProviderScope(overrides: overrides, child: build(noteId)),
          ),
        )
        .whenComplete(() {
          _srsOpenNoteEditors.remove(noteId);
        }),
  );
  return true;
}

/// 让编辑页按 [miner] 那份配置的复习副本与媒体目录工作的覆盖（[srsPushNoteEditor] 的
/// overrides）：编辑页读复习副本 / 媒体目录只经这两个 provider。
List<Override> srsProfileScopeOverrides(SrsMiner miner) => <Override>[
  srsStoreProvider.overrideWith((Ref ref) async => miner.store),
  srsMediaStoreProvider.overrideWith((Ref ref) async => miner.media),
];

/// 从 [from] 所在的 provider 作用域再压页面 / 抽屉时，把同一个作用域带过去：路由建在导航器的
/// overlay 里，不在 [from] 的子树下，不带的话会落回根作用域（App 激活配置的复习）。
/// [from] 就在根作用域里时这层包装是透明的。
Widget srsInheritProviderScope(BuildContext from, Widget child) =>
    UncontrolledProviderScope(
      container: ProviderScope.containerOf(from, listen: false),
      child: child,
    );

/// 在复习里打开 [miner] 那份配置的笔记 [noteId]（浏览器扩展所选的非激活配置）。
Future<bool> srsPushProfileNoteEditor(
  NavigatorState? navigator,
  SrsMiner miner,
  String noteId,
) => srsPushNoteEditor(
  navigator,
  noteId,
  overrides: srsProfileScopeOverrides(miner),
);

/// 在 [navigator] 上压一页浏览，可带上初始查询（AnkiConnect guiBrowse）。
Future<bool> srsPushBrowse(NavigatorState? navigator, {String? query}) async {
  if (navigator == null || !navigator.mounted) return false;
  unawaited(
    navigator.push<void>(
      adaptivePageRoute<void>(
        context: navigator.context,
        builder: (BuildContext context) => SrsBrowsePage(
          initialQuery: query,
          onChangeNoteType: showSrsChangeNoteTypeFlow,
          onMigrateToFushiCard: srsMigrateNotesToFushiCard,
        ),
      ),
    ),
  );
  return true;
}

/// popup.js `srsTermStatus` 桥（app 内弹窗与 app 外查词窗共用）：[host] 为 null（复习
/// 模块关着）或参数不对时回 null。
Future<Map<String, Object?>?> srsHandleTermStatusBridge(
  List<dynamic> args,
  SrsAppHost? host,
) async {
  if (host == null || args.isEmpty || args.first is! Map) return null;
  final Map<dynamic, dynamic> data = args.first as Map<dynamic, dynamic>;
  final String expression = data['expression']?.toString() ?? '';
  if (expression.trim().isEmpty) return null;
  return host.termStatus(expression, data['reading']?.toString() ?? '');
}

/// 桥参数里的词表（`[{expression, reading}, …]`）→ 查询；形状不对回 null，超过
/// [kSrsTermStatusBatchMax] 也回 null（宿主不替 JS 把整页隐藏词条一次查完）。
List<SrsTermQuery>? srsTermQueriesFromWire(Object? raw) {
  if (raw is! List || raw.length > kSrsTermStatusBatchMax) return null;
  final List<SrsTermQuery> out = <SrsTermQuery>[];
  for (final Object? item in raw) {
    if (item is! Map) return null;
    final String reading = item['reading']?.toString() ?? '';
    out.add(
      SrsTermQuery(
        item['expression']?.toString() ?? '',
        reading.trim().isEmpty ? null : reading,
      ),
    );
  }
  return out;
}

/// popup.js `srsTermStatusBatch` 桥（app 内弹窗与 app 外查词窗共用）：参数
/// `{terms: [{expression, reading}, …]}` → `{statuses: [null | {...}, …]}`（与 terms 等长
/// 同序）。[host] 为 null 或参数不对时回 null，popup.js 据此退回逐条 `srsTermStatus`。
Future<Map<String, Object?>?> srsHandleTermStatusBatchBridge(
  List<dynamic> args,
  SrsAppHost? host,
) async {
  if (host == null || args.isEmpty || args.first is! Map) return null;
  final List<SrsTermQuery>? terms = srsTermQueriesFromWire(
    (args.first as Map<dynamic, dynamic>)['terms'],
  );
  if (terms == null) return null;
  return <String, Object?>{'statuses': await host.termStatuses(terms)};
}

/// popup.js `srsOpenCard` 桥：打开那张卡的笔记编辑页；模块关着 / 参数不对时回 false。
Future<bool> srsHandleOpenCardBridge(
  List<dynamic> args,
  SrsAppHost? host,
) async {
  if (host == null || args.isEmpty || args.first is! Map) return false;
  final Map<dynamic, dynamic> data = args.first as Map<dynamic, dynamic>;
  final String cardId = data['cardId']?.toString() ?? '';
  if (cardId.isEmpty) return false;
  return host.openCard(cardId: cardId, noteId: data['noteId']?.toString());
}
