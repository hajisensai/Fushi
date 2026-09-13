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
      String fsPath, Future<T> Function() action) async {
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
      shelf.Request request, String davPath, String fsPath) async {
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
      entries.add(_DavEntry(
        href: normPath,
        isCollection: true,
        displayName: p.basename(fsPath),
        contentLength: 0,
      ));

      if (depth == '1') {
        final dir = Directory(fsPath);
        await for (final child in dir.list()) {
          final childName = p.basename(child.path);
          final isDir = child is Directory;
          final childHref = '$normPath$childName${isDir ? '/' : ''}';
          // BUG-908(b)：文件长度用异步 stat（await for 循环里安全 await，不打乱 XML
          // 组装顺序）；目录不必取长度。
          final length = isDir ? 0 : (await (child as File).stat()).size;
          entries.add(_DavEntry(
            href: childHref,
            isCollection: isDir,
            displayName: childName,
            contentLength: length,
          ));
        }
      }
    } else {
      final file = File(fsPath);
      // BUG-908(b)：单文件长度也用异步 stat。
      final int fileLength = (await file.stat()).size;
      entries.add(_DavEntry(
        href: davPath,
        isCollection: false,
        displayName: p.basename(fsPath),
        contentLength: fileLength,
      ));
    }

    final xml = StringBuffer('<?xml version="1.0" encoding="utf-8"?>\n')
      ..write('<d:multistatus xmlns:d="DAV:">\n');
    for (final entry in entries) {
      xml
        ..write('<d:response>\n')
        ..write('<d:href>${_xmlEscape(Uri.encodeFull(entry.href))}</d:href>\n')
        ..write('<d:propstat>\n')
        ..write('<d:prop>\n')
        ..write(
            '<d:displayname>${_xmlEscape(entry.displayName)}</d:displayname>\n')
        ..write('<d:resourcetype>')
        ..write(entry.isCollection ? '<d:collection/>' : '')
        ..write('</d:resourcetype>\n');
      if (!entry.isCollection) {
        xml.write(
            '<d:getcontentlength>${entry.contentLength}</d:getcontentlength>\n');
      }
      xml
        ..write('</d:prop>\n')
        ..write('<d:status>HTTP/1.1 200 OK</d:status>\n')
        ..write('</d:propstat>\n')
        ..write('</d:response>\n');
    }
    xml.write('</d:multistatus>');

    return shelf.Response(207,
        body: xml.toString(),
        headers: {'Content-Type': 'application/xml; charset=utf-8'});
  }

  Future<shelf.Response> _handleGet(String fsPath) async {
    final file = File(fsPath);
    if (!file.existsSync()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(
      file.openRead(),
      headers: {
        'Content-Type': _guessContentType(fsPath),
        'Content-Length': '${file.lengthSync()}',
      },
    );
  }

  Future<shelf.Response> _handlePut(
      shelf.Request request, String fsPath) async {
    final parent = Directory(p.dirname(fsPath));
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final file = File(fsPath);
    final existed = file.existsSync();
    final sink = file.openWrite();
    try {
      await request.read().forEach(sink.add);
      await sink.close();
    } catch (e) {
      // The request stream errored mid-body. Close the sink and remove the
      // truncated file rather than leaving a corrupt file behind a 201/204
      // response — matching the download paths' cleanup (HBK-AUDIT-029).
      try {
        await sink.close();
      } catch (_) {/* best-effort: failure is non-critical here */}
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } catch (_) {/* best-effort: failure is non-critical here */}
      }
      return shelf.Response(500, body: 'Write failed');
    }
    return shelf.Response(existed ? 204 : 201);
  }

  Future<shelf.Response> _handleMkcol(String fsPath) async {
    final dir = Directory(fsPath);
    if (dir.existsSync()) return shelf.Response(405);
    dir.createSync(recursive: true);
    return shelf.Response(201);
  }

  Future<shelf.Response> _handleDelete(String fsPath) async {
    final type = FileSystemEntity.typeSync(fsPath);
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
    final file = File(fsPath);
    if (!file.existsSync()) return shelf.Response.notFound('Not found');
    return shelf.Response.ok(null, headers: {
      'Content-Type': _guessContentType(fsPath),
      'Content-Length': '${file.lengthSync()}',
    });
  }
}

// ── 本域私有的顶层 helper（原 FushiSyncServer 的 private static；extension 体内看不到
//    宿主类的 static，故提到库顶层）。

String _xmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');
