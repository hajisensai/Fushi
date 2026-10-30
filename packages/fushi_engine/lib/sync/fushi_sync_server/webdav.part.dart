part of '../fushi_sync_server.dart';

/// WebDAV 域（B3 按域拆出）：按路径串行写闸门、PROPFIND / GET / PUT / MKCOL / DELETE / HEAD。
/// 方法分发在 [FushiSyncServer._handleRequest]；方法逐字搬自 FushiSyncServer。
extension _FushiSyncServerWebDav on FushiSyncServer {
  /// BUG-908(d)：把 [action] 串到 [fsPath] 的写链尾部——同一路径上的写严格 FIFO 串行，
  /// 不同路径互不阻塞。实现是「每路径一条链式 future」：新写先取当前链尾 [prev]，把自己
  /// 的完成 future 挂成新链尾，await [prev] 后再执行 [action]，最后 complete 自己让后继
  /// 继续。永远只 await 单一路径上的前驱、绝不在持有一把锁时去取另一把，故不会死锁；
  /// 收尾时若自己仍是链尾就从 map 摘除，避免闲置路径无界堆积。
  Future<T> _serializeDavWrite<T>(
    String fsPath,
    Future<T> Function() action,
  ) async {
    final Future<void> prev = _davWriteChain[fsPath] ?? Future<void>.value();
    final Completer<void> done = Completer<void>();
    _davWriteChain[fsPath] = done.future;
    try {
      // 等前一次同路径写完成后再动手。前驱失败也不应连累后继，故吞掉其异常。
      await prev.catchError((Object _) {});
      return await action();
    } finally {
      done.complete();
      // 若期间没有后继把链尾替换掉，说明该路径已空闲，摘除以防 map 无界增长。
      if (identical(_davWriteChain[fsPath], done.future)) {
        _davWriteChain.remove(fsPath);
      }
    }
  }

  Future<shelf.Response> _handlePropfind(
    shelf.Request request,
    String davPath,
    String fsPath,
  ) async {
    final depth = request.headers['depth'] ?? '1';
    // BUG-908(b)：逐项 stat 一律异步，避免在事件循环上做阻塞式系统调用（大目录
    // PROPFIND 会串起成百上千次同步 stat，卡住整个 server）。
    final entity = await FileSystemEntity.type(fsPath);

    if (entity == FileSystemEntityType.notFound) {
      return shelf.Response.notFound('Not found');
    }

    final entries = <_DavEntry>[];
    final normPath = davPath.endsWith('/') ? davPath : '$davPath/';

    if (entity == FileSystemEntityType.directory) {
      entries.add(
        _DavEntry(
          href: normPath,
          isCollection: true,
          displayName: p.basename(fsPath),
          contentLength: 0,
        ),
      );

      if (depth == '1') {
        await _appendDavChildren(entries, fsPath, normPath);
      } else if (depth.trim().toLowerCase() == 'infinity') {
        // BUG-3743：同步根树列举。**有界**——只往下列 [kDavTreeListingMaxLevels]
        // 层（同步根布局只有「根 / 书文件夹或命名空间 / 文件」两层），绝不无限递归。
        // 能力经 `/api/capabilities` 的 `webdav.treeListingLevels` 公布；client 只在
        // 看到该能力后才发 infinity（老 host 把 infinity 当 Depth 0 只回根自身）。
        final List<_DavEntry> children = <_DavEntry>[];
        await _appendDavChildren(children, fsPath, normPath);
        final String canonicalRoot = p.canonicalize(syncDataDir);
        for (final _DavEntry child in children) {
          entries.add(child);
          if (!child.isCollection) continue;
          final String childFsPath = p.join(fsPath, child.displayName);
          // 与逐个 PROPFIND 同一道路径围栏：符号链接解析到同步根之外的子目录，
          // 单独 PROPFIND 会被 403 拒绝，这里也不下钻（不把根外内容列出去）。
          final String canonicalChild = p.canonicalize(childFsPath);
          if (!canonicalChild.startsWith('$canonicalRoot${p.separator}')) {
            continue;
          }
          await _appendDavChildren(entries, childFsPath, child.href);
        }
      }
    } else {
      final file = File(fsPath);
      // BUG-908(b)：单文件长度也用异步 stat。
      final FileStat st = await file.stat();
      entries.add(
        _DavEntry(
          href: davPath,
          isCollection: false,
          displayName: p.basename(fsPath),
          contentLength: st.size,
          modified: st.modified,
        ),
      );
    }

    final xml = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n')
      ..write('<d:multistatus xmlns:d="DAV:">\n');
    for (final entry in entries) {
      xml
        ..write('<d:response>\n')
        ..write('<d:href>${_xmlEscape(_encodeDavHref(entry.href))}</d:href>\n')
        ..write('<d:propstat>\n')
        ..write('<d:prop>\n')
        ..write(
          '<d:displayname>${_xmlEscape(entry.displayName)}</d:displayname>\n',
        )
        ..write('<d:resourcetype>')
        ..write(entry.isCollection ? '<d:collection/>' : '')
        ..write('</d:resourcetype>\n');
      if (!entry.isCollection) {
        xml.write(
          '<d:getcontentlength>${entry.contentLength}</d:getcontentlength>\n',
        );
      }
      final DateTime? modified = entry.modified;
      if (modified != null) {
        // RFC 1123（HttpDate.format 总是输出 GMT）。
        xml.write(
          '<d:getlastmodified>${HttpDate.format(modified)}</d:getlastmodified>\n',
        );
      }
      xml
        ..write('</d:prop>\n')
        ..write('<d:status>HTTP/1.1 200 OK</d:status>\n')
        ..write('</d:propstat>\n')
        ..write('</d:response>\n');
    }
    xml.write('</d:multistatus>');

    return shelf.Response(
      207,
      body: xml.toString(),
      headers: {'Content-Type': 'application/xml; charset=utf-8'},
    );
  }

  /// 把目录 [dirFsPath] 的直接子项按 PROPFIND Depth 1 的形状追加进 [out]。
  /// [dirHref] 是该目录的 dav href（以 `/` 结尾）；子项 href = `dirHref + 名字`，与
  /// 直接对该目录发 Depth 1 时逐字相同（树列举与逐本列举给出同一批 id）。
  Future<void> _appendDavChildren(
    List<_DavEntry> out,
    String dirFsPath,
    String dirHref,
  ) async {
    final dir = Directory(dirFsPath);
    await for (final child in dir.list()) {
      final childName = p.basename(child.path);
      // 写到一半的 PUT 临时文件（见 _handlePut）不列出去。
      if (childName.contains(_kPutTempMarker)) continue;
      final isDir = child is Directory;
      final childHref = '$dirHref$childName${isDir ? '/' : ''}';
      // BUG-908(b)：文件长度用异步 stat（await for 循环里安全 await，不打乱 XML
      // 组装顺序）；目录不必取长度。
      // 修改时间与长度取自同一次 stat：客户端（SRS 同步）拿它当服务器时间。
      final FileStat? st = isDir ? null : await (child as File).stat();
      out.add(
        _DavEntry(
          href: childHref,
          isCollection: isDir,
          displayName: childName,
          contentLength: st?.size ?? 0,
          modified: st?.modified,
        ),
      );
    }
  }

  // GET / PUT / MKCOL / DELETE / HEAD 一律 async IO：同步根可能落在网络盘上，host 又跑在
  // app 主 isolate 上，同步 stat 冷目录时会冻结全部端点与 UI（BUG-3756）。
  Future<shelf.Response> _handleGet(String fsPath) async {
    final file = File(fsPath);
    final int? length = await _regularFileLength(file);
    if (length == null) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': _guessContentType(fsPath),
        'Content-Length': '$length',
      },
    );
  }

  /// PUT 临时文件名里的标记（`.<名字>.fushi-put-<微秒>`）。
  static const String _kPutTempMarker = '.fushi-put-';

  Future<shelf.Response> _handlePut(
    shelf.Request request,
    String fsPath,
  ) async {
    final parent = Directory(p.dirname(fsPath));
    if (!await parent.exists()) await parent.create(recursive: true);
    final file = File(fsPath);
    final existed = await file.exists();
    // 先写同目录的临时文件、写完再改名（原子替换）：以前直接 openWrite 目标，请求体传到一半时别的客户端就能
    // 列到 / 读到半截文件（SRS 迁移按名字判「新副本已在」，会因此删掉唯一的原件）。临时名不出现在 PROPFIND 里。
    final File tmp = File(
      p.join(
        parent.path,
        '.${p.basename(fsPath)}$_kPutTempMarker'
        '${DateTime.now().microsecondsSinceEpoch}',
      ),
    );
    final sink = tmp.openWrite();
    try {
      await request.read().forEach(sink.add);
      await sink.close();
      await tmp.rename(fsPath);
    } catch (e) {
      // The request stream errored mid-body (or the rename failed). Close the
      // sink and remove the temp file — the target is never left truncated
      // (HBK-AUDIT-029).
      try {
        await sink.close();
      } catch (_) {
        /* best-effort: failure is non-critical here */
      }
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {
          /* best-effort: failure is non-critical here */
        }
      }
      return shelf.Response(500, body: 'Write failed');
    }
    return shelf.Response(existed ? 204 : 201);
  }

  Future<shelf.Response> _handleMkcol(String fsPath) async {
    final dir = Directory(fsPath);
    if (await dir.exists()) return shelf.Response(405);
    await dir.create(recursive: true);
    return shelf.Response(201);
  }

  Future<shelf.Response> _handleDelete(String fsPath) async {
    final type = await FileSystemEntity.type(fsPath);
    if (type == FileSystemEntityType.notFound) {
      return shelf.Response.notFound('Not found');
    }
    if (type == FileSystemEntityType.directory) {
      await Directory(fsPath).delete(recursive: true);
    } else {
      await File(fsPath).delete();
    }
    return shelf.Response(204);
  }

  Future<shelf.Response> _handleHead(String fsPath) async {
    final int? length = await _regularFileLength(File(fsPath));
    if (length == null) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      null,
      headers: {
        'Content-Type': _guessContentType(fsPath),
        'Content-Length': '$length',
      },
    );
  }
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

String _xmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/// PROPFIND 的 href 逐段 percent-encode。`Uri.encodeFull` 不编码 `#` / `?`，名字里带它们的条目
/// （复习同步写入者目录 `<deviceId>#<化身号>`）会被客户端当成 URL 片段 / 查询截掉（BUG-3576）。
String _encodeDavHref(String href) =>
    href.split('/').map(Uri.encodeComponent).join('/');
