import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
    final String b64 = base64Encode(bytes);
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
      post({
        messageType: 'ttu_import_log',
        stage: 'preload:console.error',
        extra: payload.slice(0, 2000),
      });
    } catch (_) {}
    return origErr.apply(this, args);
  };
  window.addEventListener('error', (e) => {
    post({
      messageType: 'ttu_import_log',
      stage: 'preload:window.error',
      extra: (e.error && e.error.stack)
          ? String(e.error) + '\\n' + e.error.stack
          : (e.message || 'unknown'),
    });
  });
  window.addEventListener('unhandledrejection', (e) => {
    const r = e.reason;
    post({
      messageType: 'ttu_import_log',
      stage: 'preload:unhandled',
      extra: (r && r.stack) ? String(r) + '\\n' + r.stack : String(r),
    });
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
      ),
      initialUserScripts: UnmodifiableListView<UserScript>([
        UserScript(
          source: preloadHook,
          injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        ),
      ]),
      onLoadStop: (controller, url) async {
        log('onLoadStop', 'url=$url jsDispatched=$jsDispatched');
        if (jsDispatched) return;
        jsDispatched = true;
        // Manage page may lazy-mount its input; give Svelte a tick.
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
    const maxBefore = await new Promise((resolve) => {
      const req = indexedDB.open('books');
      req.onupgradeneeded = (e) => {
        const db = e.target.result;
        if (!db.objectStoreNames.contains('data'))
          db.createObjectStore('data', {autoIncrement: true});
        if (!db.objectStoreNames.contains('bookmark'))
          db.createObjectStore('bookmark', {autoIncrement: true});
        if (!db.objectStoreNames.contains('lastItem'))
          db.createObjectStore('lastItem');
      };
      req.onsuccess = (e) => {
        const db = e.target.result;
        if (!db.objectStoreNames.contains('data')) { resolve(0); return; }
        const tx = db.transaction(['data'], 'readonly');
        const store = tx.objectStore('data');
        const cur = store.openCursor(null, 'prev');
        cur.onsuccess = (ev) => {
          const c = ev.target.result;
          resolve(c ? c.primaryKey : 0);
        };
        cur.onerror = () => resolve(0);
      };
      req.onerror = () => resolve(0);
    });
    logStage('maxBefore', 'maxBefore=' + maxBefore);

    // ── 3. Locate ttu's book-import input on /manage ─────────────────────
    const findInput = () => {
      const all = Array.from(document.querySelectorAll('input[type=file]'));
      // ttu's book-import input has accept attr containing 'epub' / 'htmlz'.
      return all.find(i => (i.getAttribute('accept') || '')
          .toLowerCase().includes('epub'));
    };
    let input = findInput();
    const deadline = Date.now() + 15000;
    while (!input && Date.now() < deadline) {
      await new Promise(r => setTimeout(r, 200));
      input = findInput();
    }
    if (!input) { post({messageType: 'ttu_import_err', error: 'no_input'}); return; }
    logStage('input-found', 'accept=' + input.getAttribute('accept'));

    // ── 4. Drop the File into the input and fire 'change' ────────────────
    const dt = new DataTransfer();
    dt.items.add(file);
    input.files = dt.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));
    logStage('change-dispatched');

    // ── 5. Poll IndexedDB for the new row ────────────────────────────────
    // 大 EPUB（10MB+）在手机上解压 + 解析 + 写入 IDB 常常要一两分钟，
    // 这里给 4.5 分钟余量，与 Dart 侧 5 分钟总 timeout 对齐。
    const pollDeadline = Date.now() + 270000;
    let tick = 0;
    while (Date.now() < pollDeadline) {
      await new Promise(r => setTimeout(r, 500));
      tick++;
      const newId = await new Promise((resolve) => {
        const req = indexedDB.open('books');
        req.onsuccess = (e) => {
          const db = e.target.result;
          if (!db.objectStoreNames.contains('data')) { resolve(0); return; }
          const tx = db.transaction(['data'], 'readonly');
          const store = tx.objectStore('data');
          const cur = store.openCursor(null, 'prev');
          cur.onsuccess = (ev) => {
            const c = ev.target.result;
            resolve(c ? c.primaryKey : 0);
          };
          cur.onerror = () => resolve(0);
        };
        req.onerror = () => resolve(0);
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

}
