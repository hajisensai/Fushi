/// SRS 媒体同步（第三期「传输」：媒体按内容哈希存，只传对方没有的文件，文件名就是哈希）。
///
/// 布局：`<namespace fushi-srs>/<profileUid>/<writerId>/media/<sha1.ext>`——媒体也只由上传它的写入者写
/// （单写者规则）；读方从任意写入者的 media 目录取。
///
/// 每轮（事件同步之后）：
/// 1. 收集本 profile 全部笔记字段里引用的媒体文件名（`<img src>` / `[sound:]` 等，
///    以及释义样式去重换出来的共享样式文件）。
/// 2. 本机缺的 → 从任一写入者的 media 目录下载。
/// 3. 本机有、但所有现存写入者的 media 目录里都没有的 → 上传到本写入者自己的 media 目录。
///    退役写入者的目录被清理后，下一台仍持有该文件的活跃设备会在下一轮把它补传回来，
///    所以只要还有任一活跃设备有这个文件，它就不会从同步目录里消失。
/// 媒体删除不跨设备传播（Anki 的媒体删除会传播、误删后全线丢图）；无引用文件的回收留在本机。
library;

import 'dart:io';

import 'package:fushi_engine/srs/apkg/srs_apkg_common.dart';
import 'package:fushi_engine/srs/srs_asset_store_directory.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:path/path.dart' as p;

const String kSrsMediaFolder = 'media';

/// 一轮媒体同步的结果。
class SrsMediaSyncReport {
  int uploaded = 0;
  int downloaded = 0;

  /// 引用了但同步目录与本机都没有的文件（等持有它的设备上线）。
  final Set<String> missing = <String>{};
}

/// 本 profile 全部笔记（含模板正文里下划线开头的静态文件）引用的媒体文件名。
Future<Set<String>> srsReferencedMedia(SrsDbStore store) async {
  final Set<String> out = <String>{};
  for (final SrsNoteView n in await store.allNoteViews()) {
    if (n.deletedAt != null) continue;
    for (final String v in n.fields.values) {
      out.addAll(srsMediaRefsIn(v));
      // 释义样式去重的共享样式文件（`_fushi_style_<sha1>.css`，见 srs_style_store.dart）。
      out.addAll(srsStyleRefsIn(v));
    }
  }
  for (final SrsNoteTypeView t in await store.noteTypes()) {
    for (final SrsTemplateDef tpl in t.templates) {
      out.addAll(srsMediaRefsIn(tpl.front, includeStatic: true));
      out.addAll(srsMediaRefsIn(tpl.back, includeStatic: true));
    }
    out.addAll(srsMediaRefsIn(t.css, includeStatic: true));
  }
  return out.where(_isBareName).toSet();
}

bool _isBareName(String n) =>
    n.isNotEmpty &&
    !n.contains('/') &&
    !n.contains(r'\') &&
    n != '.' &&
    n != '..';

/// 跑一轮媒体同步。[mediaRoot] 是本 profile 的本机媒体目录。
Future<SrsMediaSyncReport> srsSyncMedia({
  required SyncAssetStore backend,
  required SrsDbStore store,
  required Directory mediaRoot,
}) async {
  final SrsMediaSyncReport report = SrsMediaSyncReport();
  final Set<String> wanted = await srsReferencedMedia(store);
  if (wanted.isEmpty) return report;

  final String ns = await backend.ensureNamespace(kSrsSyncNamespace);
  final String profileFolder = await backend.ensureFolder(ns, store.profileUid);
  // 每个写入者 media 目录里有什么：文件名 → 资产 ID。
  final Map<String, String> remote = <String, String>{};
  String? ownMedia;
  for (final AssetEntry w in await backend.listChildren(profileFolder)) {
    if (!w.isFolder) continue;
    String? mediaId;
    for (final AssetEntry e in await backend.listChildren(w.id)) {
      if (e.isFolder && e.name == kSrsMediaFolder) mediaId = e.id;
    }
    if (w.name == store.writerId) ownMedia = mediaId;
    if (mediaId == null) continue;
    for (final AssetEntry f in await backend.listChildren(mediaId)) {
      if (!f.isFolder) remote.putIfAbsent(f.name, () => f.id);
    }
  }

  for (final String name in wanted) {
    final File local = File(p.join(mediaRoot.path, name));
    final bool haveLocal = local.existsSync();
    final String? remoteId = remote[name];
    if (!haveLocal && remoteId != null) {
      await mediaRoot.create(recursive: true);
      final File tmp = File('${local.path}.download');
      try {
        await backend.getAsset(remoteId, tmp);
        await tmp.rename(local.path);
        report.downloaded++;
      } on Object {
        if (tmp.existsSync()) await tmp.delete();
      }
    } else if (haveLocal && remoteId == null) {
      if (ownMedia == null) {
        final String writerFolder = await backend.ensureFolder(
          profileFolder,
          store.writerId,
        );
        ownMedia = await backend.ensureFolder(writerFolder, kSrsMediaFolder);
      }
      await backend.putAsset(ownMedia, name, local);
      report.uploaded++;
    } else if (!haveLocal) {
      report.missing.add(name);
    }
  }
  return report;
}
