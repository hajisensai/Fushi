import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/ttu_idb_schema.dart';

/// Drives the ッツ Ebook Reader's own EPUB import pipeline by simulating a
/// file-select event on its hidden `<input type="file">` on the `/manage`
/// page. Returns the auto-incremented IndexedDB `data` store key assigned to
/// the new book.
///
/// Using ttu's own importer (rather than hand-crafting a payload) means the
/// IndexedDB entry is always shape-compatible with whatever ttu version is
/// bundled, including chapters, images (blobs), styleSheet, sections etc.
class TtuEpubImporter {
  /// Imports [bytes] as an EPUB into the ttu reader served at localhost
  /// [serverPort]. [filename] must end with `.epub` — ttu rejects anything
  /// else. Throws on timeout or runtime error.
  static Future<int> import({
    required Uint8List bytes,
    required String filename,
    required int serverPort,
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final Stopwatch sw = Stopwatch()..start();
    void log(String stage, [String? extra]) {
      final String s = extra == null
          ? '[ttu-import ${sw.elapsedMilliseconds}ms] $stage'
          : '[ttu-import ${sw.elapsedMilliseconds}ms] $stage | $extra';
      debugPrint(s);
    }

    log('start', 'file="$filename" bytes=${bytes.length}');

    // 某些 EPUB（例如 calibre 2.0 导出）的 manifest 用 media-type="text/html"
    // 而非 "application/xhtml+xml"；ttu 的 ah() 里构造 id→href 映射时只认
    // xhtml+xml，结果整个 map 是空的，下游 zt.dirname(undefined) 直接抛
    // "Path must be a string"。导入前把 OPF 里的 text/html 改写成
    // xhtml+xml，再喂给 ttu。
    final Uint8List normalised = _rewriteHtmlMediaType(bytes, log);

    final String b64 = base64Encode(normalised);
    log('b64-encoded', 'b64_len=${b64.length}');

    final Completer<int> completer = Completer<int>();
    HeadlessInAppWebView? webView;

    final String js = _buildDriverJs(b64: b64, filename: filename);
    log('js-built', 'js_len=${js.length}');

    // ttu 是 SPA，onLoadStop 会多次触发（navigation / service-worker 激活等）；
    // 重复执行会把同一份 13MB base64 再塞一次 JS 源码 + 再开一次 ttu 导入，
    // 既浪费主线程也可能造出重复的 IDB row。
    // ttu 在模块加载时把 `console.error` 的引用捕获成常量
    // （`et = {3: console.error, ...}`），我们等 onLoadStop 再包装就太晚了。
    // 在 document-start 阶段就注入包装，保证 ttu 捕获到的是我们的版本。
    const String preloadHook = '''
(function() {
  const post = (obj) => console.log(JSON.stringify(obj));
  const safeLog = (stage, extra) => {
    try {
      post({messageType: 'ttu_import_log', stage: stage,
            extra: String(extra).slice(0, 4000)});
    } catch (_) {}
  };

  // ── 1. console.error wrapper — 即便只拿到 e.message 也能标注时间。
  const origErr = console.error;
  console.error = function(...args) {
    try {
      const payload = args.map(a => {
        if (a && a.stack) return String(a) + '\\n' + a.stack;
        if (a && typeof a === 'object') {
          try { return JSON.stringify(a); } catch (_) { return String(a); }
        }
        return String(a);
      }).join(' | ');
      safeLog('preload:console.error', payload);
    } catch (_) {}
    return origErr.apply(this, args);
  };

  // ── 2. 把 TypeError 构造包一层，专门抓 "Path must be a string" 的 stack。
  //     ttu 内部 try/catch 把错吞了、调 console.error 时只剩 e.message，
  //     stack 要在 TypeError 构造现场就拍下来。
  const OrigTypeError = globalThis.TypeError;
  const flatten = (s) => String(s == null ? '' : s).replace(/\\n/g, ' || ');
  function PatchedTypeError(message) {
    const err = new OrigTypeError(message);
    try {
      if (typeof message === 'string' &&
          message.indexOf('Path must be a string') === 0) {
        let stack = err.stack;
        // captureStackTrace 在 V8/Chromium 上把当前调用栈挂到对象 .stack 上。
        if ((!stack || stack.length < 40) && OrigTypeError.captureStackTrace) {
          const o = {};
          try { OrigTypeError.captureStackTrace(o, PatchedTypeError); stack = o.stack; }
          catch (_) {}
        }
        // 再不行就靠 throw+catch 拿当前栈。
        if (!stack || stack.length < 40) {
          try { throw new OrigTypeError('probe'); }
          catch (e) { stack = e.stack; }
        }
        safeLog('preload:TypeError-thrown',
            'msg=' + message + ' | stack_len=' +
            (stack ? stack.length : 'null') +
            ' | stack=' + flatten(stack));
      }
    } catch (e) {
      safeLog('preload:TypeError-hook-err', String(e));
    }
    return err;
  }
  PatchedTypeError.prototype = OrigTypeError.prototype;
  Object.setPrototypeOf(PatchedTypeError, OrigTypeError);
  try {
    globalThis.TypeError = PatchedTypeError;
  } catch (_) {}

  // ── 3. 全局 error / unhandledrejection（某些情况下还是有机会抓到）。
  window.addEventListener('error', (e) => {
    safeLog('preload:window.error', (e.error && e.error.stack)
        ? String(e.error) + '\\n' + e.error.stack
        : (e.message || 'unknown'));
  });
  window.addEventListener('unhandledrejection', (e) => {
    const r = e.reason;
    safeLog('preload:unhandled',
        (r && r.stack) ? String(r) + '\\n' + r.stack : String(r));
  });
})();
''';

    bool jsDispatched = false;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$serverPort/manage.html'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source:
              'if(!String.prototype.replaceAll){String.prototype.replaceAll=function(a,b){if(a instanceof RegExp){if(!a.global)throw new TypeError("replaceAll must be called with a global RegExp");return this.replace(a,b)}return this.split(a).join(b)}}',
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
        UserScript(
          source: preloadHook,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onLoadStop: (controller, url) async {
        log('onLoadStop', 'url=$url jsDispatched=$jsDispatched');
        if (jsDispatched) return;
        jsDispatched = true;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        log('evaluateJavascript:begin');
        await controller.evaluateJavascript(source: js);
        log('evaluateJavascript:done');
      },
      onConsoleMessage: (controller, message) {
        final String raw = message.message;
        try {
          final Map<String, dynamic> msg =
              jsonDecode(raw) as Map<String, dynamic>;
          final String? type = msg['messageType']?.toString();
          switch (type) {
            case 'ttu_import_log':
              log('js:${msg['stage']}', msg['extra']?.toString());
              return;
            case 'ttu_import_ok':
              log('ok', 'id=${msg['id']}');
              if (!completer.isCompleted) {
                completer.complete((msg['id'] as num).toInt());
              }
              return;
            case 'ttu_import_err':
              log('err', msg['error']?.toString());
              if (!completer.isCompleted) {
                completer.completeError(
                    msg['error']?.toString() ?? 'ttu_import_err');
              }
              return;
          }
          // Non-matching JSON — surface it so we can see unexpected ttu output.
          log('js:console', raw);
        } catch (_) {
          // ttu 内部也会 console.log 一些非 JSON 的东西，打出来帮定位。
          log('js:console-raw', raw);
        }
      },
    );

    try {
      log('webView.run:begin');
      await webView.run();
      log('webView.run:done');
      final int id = await completer.future.timeout(timeout, onTimeout: () {
        log('dart-timeout', 'limit=${timeout.inSeconds}s');
        throw TimeoutException(
            'ttu import did not complete within ${timeout.inSeconds}s');
      });
      log('return', 'id=$id');
      return id;
    } finally {
      await webView.dispose();
      log('webView.dispose');
    }
  }

  /// Constructs the JS payload: find the book-import file input, feed it a
  /// File assembled from the base64 bytes, dispatch a 'change' event to
  /// trigger ttu's Svelte handler, then poll IndexedDB until a new row
  /// appears in the `data` store.
  static String _buildDriverJs({
    required String b64,
    required String filename,
  }) {
    final String safeName =
        filename.replaceAll('\\', '_').replaceAll('"', '_');
    return '''
(async function() {
  ${TtuIdbSchema.openBooksDbJs}
  const post = (obj) => console.log(JSON.stringify(obj));
  const t0 = Date.now();
  const logStage = (stage, extra) => post({
    messageType: 'ttu_import_log',
    stage: stage,
    extra: (extra == null ? ('+' + (Date.now() - t0) + 'ms')
                          : ('+' + (Date.now() - t0) + 'ms ' + extra)),
  });
  try {
    logStage('driver-start');

    // ── 1. Decode base64 payload ─────────────────────────────────────────
    const b64 = "$b64";
    logStage('atob:begin', 'b64_len=' + b64.length);
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    logStage('atob:done', 'bytes=' + bytes.length);
    const file = new File([bytes], "$safeName",
        { type: 'application/epub+zip' });
    logStage('file-built');

    // ── 2. Record current max id so we can detect the new entry ──────────
    const maxBefore = await new Promise(async (resolve) => {
      try {
        const db = await hibikiOpenBooksDb();
        const tx = db.transaction(['data'], 'readonly');
        const store = tx.objectStore('data');
        const cur = store.openCursor(null, 'prev');
        cur.onsuccess = (ev) => {
          const c = ev.target.result;
          resolve(c ? c.primaryKey : 0);
        };
        cur.onerror = () => resolve(0);
      } catch (_) {
        resolve(0);
      }
    });
    logStage('maxBefore', 'maxBefore=' + maxBefore);

    // ── 3. Wait for __hibikiImportFiles to be exposed by manage page ─────
    const findApi = () => typeof window.__hibikiImportFiles === 'function';
    const deadline = Date.now() + 15000;
    while (!findApi() && Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 200));
    }
    if (!findApi()) { post({messageType: 'ttu_import_err', error: 'no_api'}); return; }
    logStage('api-ready');

    // ── 4. Call ttu's import pipeline directly ───────────────────────────
    window.__hibikiImportFiles([file]);
    logStage('import-called');

    // ── 5. Poll IndexedDB for the new row ────────────────────────────────
    // 大 EPUB（10MB+）在手机上解压 + 解析 + 写入 IDB 常常要一两分钟，
    // 这里给 4.5 分钟余量，与 Dart 侧 5 分钟总 timeout 对齐。
    const pollDeadline = Date.now() + 270000;
    let tick = 0;
    while (Date.now() < pollDeadline) {
      await new Promise(r => setTimeout(r, 500));
      tick++;
      const newId = await new Promise(async (resolve) => {
        try {
          const db = await hibikiOpenBooksDb();
          const tx = db.transaction(['data'], 'readonly');
          const store = tx.objectStore('data');
          const cur = store.openCursor(null, 'prev');
          cur.onsuccess = (ev) => {
            const c = ev.target.result;
            resolve(c ? c.primaryKey : 0);
          };
          cur.onerror = () => resolve(0);
        } catch (_) {
          resolve(0);
        }
      });
      // 每 10 次 tick（~5s）汇报一次，避免刷屏。
      if (tick % 10 === 0) {
        logStage('poll', 'tick=' + tick + ' newId=' + newId + ' maxBefore=' + maxBefore);
      }
      if (newId > maxBefore) {
        logStage('poll-hit', 'id=' + newId + ' after_tick=' + tick);
        post({messageType: 'ttu_import_ok', id: newId});
        return;
      }
    }
    logStage('poll-exhausted', 'ticks=' + tick);
    post({messageType: 'ttu_import_err', error: 'import_timeout'});
  } catch (err) {
    post({messageType: 'ttu_import_err', error: String(err)});
  }
})();
''';
  }

  /// If the EPUB's OPF manifest uses `media-type="text/html"` for xhtml
  /// items, rewrite it to `application/xhtml+xml` and re-zip. Returns the
  /// original [bytes] untouched when no rewrite is needed or when anything
  /// goes wrong (ttu will then fail loudly, which is better than silently
  /// producing a corrupted archive).
  static Uint8List _rewriteHtmlMediaType(
    Uint8List bytes,
    void Function(String stage, [String? extra]) log,
  ) {
    try {
      final Archive archive = ZipDecoder().decodeBytes(bytes);

      // Find container.xml → OPF path.
      final ArchiveFile? container = archive.findFile('META-INF/container.xml');
      if (container == null) {
        log('rewrite:skip', 'no container.xml');
        return bytes;
      }
      final String containerXml = utf8.decode(container.content as List<int>);
      final RegExp fullPathRe =
          RegExp(r'full-path\s*=\s*"([^"]+)"', caseSensitive: false);
      final Match? m = fullPathRe.firstMatch(containerXml);
      if (m == null) {
        log('rewrite:skip', 'no full-path in container');
        return bytes;
      }
      final String opfPath = m.group(1)!;
      final ArchiveFile? opfFile = archive.findFile(opfPath);
      if (opfFile == null) {
        log('rewrite:skip', 'opf not found at $opfPath');
        return bytes;
      }

      final String opfContent = utf8.decode(opfFile.content as List<int>);
      // 只替换 <manifest>…</manifest> 里的 <item … media-type="text/html" …>。
      final RegExp manifestRe =
          RegExp(r'<manifest\b[^>]*>([\s\S]*?)</manifest>', caseSensitive: false);
      final Match? mm = manifestRe.firstMatch(opfContent);
      if (mm == null) {
        log('rewrite:skip', 'no <manifest> in opf');
        return bytes;
      }
      final String manifestBlock = mm.group(0)!;
      final RegExp itemHtmlRe = RegExp(
          r'(<item\b[^>]*\bmedia-type\s*=\s*")text/html(\s*"[^>]*/?>)',
          caseSensitive: false);
      final int hits = itemHtmlRe.allMatches(manifestBlock).length;
      if (hits == 0) {
        log('rewrite:skip', 'opf already xhtml');
        return bytes;
      }
      final String newManifest = manifestBlock.replaceAllMapped(
          itemHtmlRe, (m) => '${m.group(1)}application/xhtml+xml${m.group(2)}');
      final String newOpf = opfContent.replaceFirst(manifestBlock, newManifest);
      log('rewrite:hit', 'items=$hits opf=$opfPath');

      // 替换 archive 里的 OPF 条目（保持其它条目原样）。
      final Archive rebuilt = Archive();
      for (final ArchiveFile f in archive) {
        if (f.name == opfPath) {
          final List<int> newBytes = utf8.encode(newOpf);
          rebuilt.addFile(ArchiveFile(f.name, newBytes.length, newBytes));
        } else {
          rebuilt.addFile(f);
        }
      }

      final List<int>? zipped = ZipEncoder().encode(rebuilt);
      if (zipped == null) {
        log('rewrite:encode-null');
        return bytes;
      }
      log('rewrite:done', 'new_size=${zipped.length}');
      return Uint8List.fromList(zipped);
    } catch (e) {
      log('rewrite:err', e.toString());
      return bytes;
    }
  }
}
