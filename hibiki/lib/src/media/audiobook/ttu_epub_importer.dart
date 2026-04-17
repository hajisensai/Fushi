import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

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
    Duration timeout = const Duration(seconds: 60),
  }) async {
    final String b64 = base64Encode(bytes);
    final Completer<int> completer = Completer<int>();
    HeadlessInAppWebView? webView;

    final String js = _buildDriverJs(b64: b64, filename: filename);

    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$serverPort/manage.html'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      ),
      onLoadStop: (controller, url) async {
        // Manage page may lazy-mount its input; give Svelte a tick.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await controller.evaluateJavascript(source: js);
      },
      onConsoleMessage: (controller, message) {
        try {
          final Map<String, dynamic> msg =
              jsonDecode(message.message) as Map<String, dynamic>;
          if (completer.isCompleted) return;
          switch (msg['messageType']) {
            case 'ttu_import_ok':
              completer.complete((msg['id'] as num).toInt());
              break;
            case 'ttu_import_err':
              completer.completeError(
                  msg['error']?.toString() ?? 'ttu_import_err');
              break;
          }
        } catch (_) {
          // Ignore non-JSON console noise from ttu.
        }
      },
    );

    try {
      await webView.run();
      return await completer.future.timeout(timeout);
    } finally {
      await webView.dispose();
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
  try {
    // ── 1. Decode base64 payload ─────────────────────────────────────────
    const b64 = "$b64";
    const bin = atob(b64);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    const file = new File([bytes], "$safeName",
        { type: 'application/epub+zip' });

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

    // ── 4. Drop the File into the input and fire 'change' ────────────────
    const dt = new DataTransfer();
    dt.items.add(file);
    input.files = dt.files;
    input.dispatchEvent(new Event('change', { bubbles: true }));

    // ── 5. Poll IndexedDB for the new row ────────────────────────────────
    const pollDeadline = Date.now() + 55000;
    while (Date.now() < pollDeadline) {
      await new Promise(r => setTimeout(r, 500));
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
      if (newId > maxBefore) {
        post({messageType: 'ttu_import_ok', id: newId});
        return;
      }
    }
    post({messageType: 'ttu_import_err', error: 'import_timeout'});
  } catch (err) {
    post({messageType: 'ttu_import_err', error: String(err)});
  }
})();
''';
  }

}
