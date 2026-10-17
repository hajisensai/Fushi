/// 复习（SRS）给不在 Riverpod 图里的宿主（app 外查词窗的 deferred 桥、Fushi API
/// 服务器的 `/api/srs/*`）用的入口。
///
/// [SrsAppHost.current] 只在复习模块开着时由 `srs_app_runtime.dart` 装上，模块关着时
/// 为 null——调用方据此直接回 null / 404，不打开任何数据库。
library;

import 'dart:async';

import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/pages/implementations/srs/srs_browse_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_note_editor_page.dart';
import 'package:fushi/src/srs/srs_term_status_bridge.dart';
import 'package:fushi/src/sync/fushi_api_server.dart' show SrsExtensionApi;
import 'package:fushi/utils.dart';
import 'package:fushi/src/srs/srs_change_note_type.dart';

class SrsAppHost implements SrsExtensionApi {
  SrsAppHost({
    required this.readStore,
    required this.openNote,
    required this.openBrowse,
  });

  /// 当前（复习模块开着时装上的）宿主入口；null = 模块关着。
  static SrsAppHost? current;

  /// 当前 profile 的 SRS 副本（打开失败时为 null）。
  final Future<SrsDbStore?> Function() readStore;

  /// 打开一条笔记的编辑页；导航器不可用时返回 false。
  final Future<bool> Function(String noteId) openNote;

  /// 打开浏览页。
  final Future<bool> Function() openBrowse;

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

/// 在 [navigator] 上压一页笔记编辑（弹窗 / 外部工具打开卡片）。
Future<bool> srsPushNoteEditor(NavigatorState? navigator, String noteId) async {
  if (navigator == null || !navigator.mounted) return false;
  unawaited(
    navigator.push<void>(
      adaptivePageRoute<void>(
        context: navigator.context,
        builder: (BuildContext context) => SrsNoteEditorPage(noteId: noteId),
      ),
    ),
  );
  return true;
}

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
