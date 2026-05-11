import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

/// ttu IDB 里一本书的基本元数据（当前只暴露 title + 章节文本）。
class TtuBookRecord {
  const TtuBookRecord({required this.title, required this.sections});

  final String title;
  final List<EpubSection> sections;
}

/// 从 ッツ Ebook Reader 的 IndexedDB `books` store 读取一本书的元数据与
/// 章节纯文本。
///
/// 原本 readTitle + readSections 各自开一个 HeadlessInAppWebView（每个都要走
/// 完整的 ttu SPA 启动，含 service-worker 预缓存），在 EPUB+字幕 导入路径上
/// 连续新建多个 WebView 容易触发 ANR。合并成一次 IDB.get(id) 调用后，title
/// 与 sections 一起返回。
class TtuIdbReader {
  /// 读取 `ttuBookId` 对应 books 记录的 title + 章节文本。
  ///
  /// 返回按 ttu 顺序（`sections` 字段）的 [EpubSection] 列表；若该 id 不存在
  /// 抛 `StateError`。
  static Future<TtuBookRecord> readBookRecord({
    required int ttuBookId,
    required int serverPort,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    if (ttuBookId <= 0) {
      throw ArgumentError('ttuBookId must be > 0');
    }

    final String js = '''
(async function() {
  try {
    const record = await new Promise((resolve, reject) => {
      const req = indexedDB.open('books');
      req.onupgradeneeded = (e) => {
        e.target.transaction.abort();
        reject('db_not_initialized');
      };
      req.onsuccess = (ev) => {
        const db = ev.target.result;
        if (!db.objectStoreNames.contains('data')) {
          db.close();
          reject('data_store_missing'); return;
        }
        const tx = db.transaction(['data'], 'readonly');
        const get = tx.objectStore('data').get($ttuBookId);
        get.onsuccess = (e) => resolve(e.target.result);
        get.onerror = (e) => reject(String(e.target.error));
      };
      req.onerror = (e) => reject(String(e.target.error));
    });
    if (!record) {
      console.log(JSON.stringify({messageType: 'ttu_read_err', error: 'not_found'}));
      return;
    }
    const title = typeof record.title === 'string' ? record.title : '';
    const html = record.elementHtml || '';
    const sectionsMeta = Array.isArray(record.sections) ? record.sections : [];
    const parser = new DOMParser();
    const doc = parser.parseFromString('<div>' + html + '</div>', 'text/html');
    // 日文 EPUB 常用 <ruby><rt>假名</rt></ruby> 标注振假名；textContent 会把 rt
    // 里的读音和底字拼接成 "魔ま法ほう"，而 SRT 是纯文本 "魔法"，bigram 匹配
    // 会被稀释到 0.2~0.3，导致整本匹配率崩到个位数。抽文本前统一剥掉 rt/rp。
    function stripRuby(el) {
      const clone = el.cloneNode(true);
      const rts = clone.querySelectorAll('rt, rp');
      for (let j = 0; j < rts.length; j++) rts[j].remove();
      return clone.textContent || '';
    }
    // 与 audiobook_bridge 的 __hoshiLoadSasayakiRefs 必须用**同一份 section
    // 列表**：JS 侧无条件遍历 record.sections，所以这里也不能过滤掉无
    // reference 的封面/目录页等。否则 matcher 写回的 sectionIndex 是"过滤后
    // 列表的位置"，而 JS 的 starts[sectionIndex] 是"完整列表的位置"，错位
    // 一帧就会让高亮跳到上一章/封面，外层却显示 90%+ 匹配率（matcher 在
    // 拼接 big string 上 indexOf 仍然成功）。
    // 无 ref 的 stub 段 text='' 不向 normalize 字符串贡献内容，对匹配算法
    // 透明；只是占位让后面真章节的索引 == ttu IDB 原始 index。
    const out = [];
    for (let i = 0; i < sectionsMeta.length; i++) {
      const s = sectionsMeta[i];
      const ref = (s && s.reference) || '';
      const el = ref ? doc.getElementById(ref) : null;
      const text = el ? stripRuby(el) : '';
      out.push({ index: i, href: ref, label: (s && s.label) || '', text: text });
    }
    if (out.length === 0) {
      const body = doc.body.firstChild;
      const text = body ? stripRuby(body) : '';
      out.push({ index: 0, href: 'ttu-body', label: '', text: text });
    }
    console.log(JSON.stringify({
      messageType: 'ttu_read_ok',
      title: title,
      sections: out,
    }));
  } catch (e) {
    console.log(JSON.stringify({messageType: 'ttu_read_err', error: String(e)}));
  }
})();
''';

    final Completer<TtuBookRecord> completer = Completer<TtuBookRecord>();
    HeadlessInAppWebView? webView;
    // ttu 是 SPA，service-worker 激活等过程会让 onLoadStop 多次触发；不去重
    // 会让 IDB get + DOMParser 重复执行，堆在主线程上触发 ANR。
    bool jsDispatched = false;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$serverPort/_hibiki_idb.html'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      onLoadStop: (controller, url) async {
        if (jsDispatched) return;
        jsDispatched = true;
        await controller.evaluateJavascript(source: js);
      },
      onConsoleMessage: (controller, message) {
        if (completer.isCompleted) {
          return;
        }
        try {
          final Map<String, dynamic> msg =
              jsonDecode(message.message) as Map<String, dynamic>;
          final String type = msg['messageType'] as String? ?? '';
          if (type == 'ttu_read_ok') {
            final String title = msg['title'] as String? ?? '';
            final List<dynamic> raw = msg['sections'] as List<dynamic>;
            final List<EpubSection> sections = raw.map((dynamic e) {
              final Map<String, dynamic> m = e as Map<String, dynamic>;
              return EpubSection(
                index: (m['index'] as num).toInt(),
                href: m['href'] as String? ?? '',
                text: m['text'] as String? ?? '',
              );
            }).toList();
            completer.complete(
              TtuBookRecord(title: title, sections: sections),
            );
          } else if (type == 'ttu_read_err') {
            completer.completeError(
              StateError('ttu_read_err: ${msg['error']}'),
            );
          }
        } catch (e, stack) {
          ErrorLogService.instance.log('TtuIdbReader.consoleDecode', e, stack);
          debugPrint('TtuIdbReader console decode error: $e');
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

  /// Returns list of all book IDs in the ttu IndexedDB 'data' store.
  /// Returns null on IDB access failure (distinguishes from empty library).
  static Future<List<int>?> readAllBookIds(int serverPort) async {
    final Completer<List<int>?> completer = Completer<List<int>?>();
    bool jsDispatched = false;
    HeadlessInAppWebView? webView;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$serverPort/_hibiki_idb.html'),
      ),
      initialSettings: InAppWebViewSettings(
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      onLoadStop: (controller, url) async {
        if (jsDispatched) return;
        jsDispatched = true;
        await controller.evaluateJavascript(source: '''
(async function() {
  try {
    const db = await new Promise((resolve, reject) => {
      const req = indexedDB.open('books');
      req.onupgradeneeded = (e) => {
        e.target.transaction.abort();
        reject('db_not_initialized');
      };
      req.onsuccess = (ev) => {
        const db = ev.target.result;
        if (!db.objectStoreNames.contains('data')) {
          db.close();
          reject('data_store_missing');
          return;
        }
        resolve(db);
      };
      req.onerror = (e) => reject(String(e.target.error));
    });
    const tx = db.transaction('data', 'readonly');
    const store = tx.objectStore('data');
    const keys = await new Promise((resolve, reject) => {
      const req = store.getAllKeys();
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    db.close();
    console.log(JSON.stringify({messageType: 'ttu_keys_ok', keys: keys}));
  } catch (e) {
    console.log(JSON.stringify({messageType: 'ttu_keys_err', error: String(e)}));
  }
})();
        ''');
      },
      onConsoleMessage: (controller, message) {
        if (completer.isCompleted) return;
        try {
          final Map<String, dynamic> msg =
              jsonDecode(message.message) as Map<String, dynamic>;
          switch (msg['messageType']) {
            case 'ttu_keys_ok':
              completer.complete(
                (msg['keys'] as List<dynamic>).cast<int>(),
              );
              break;
            case 'ttu_keys_err':
              debugPrint(
                  'TtuIdbReader.readAllBookIds error: ${msg['error']}');
              completer.complete(null);
              break;
          }
        } catch (e, stack) {
          ErrorLogService.instance.log('TtuIdbReader.readAllBookIds', e, stack);
          debugPrint('TtuIdbReader.readAllBookIds decode error: $e');
        }
      },
    );

    try {
      await webView.run();
      return await completer.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () => null,
      );
    } finally {
      await webView.dispose();
    }
  }

  /// Read a book's full data for migration: title, elementHtml, sections
  /// metadata, coverImage. Returns null if book not found or IDB access fails.
  ///
  /// Uses callHandler instead of console.log to avoid message truncation
  /// for large books.
  static Future<Map<String, dynamic>?> readBookForMigration({
    required int ttuBookId,
    required int serverPort,
  }) async {
    final Completer<Map<String, dynamic>?> completer =
        Completer<Map<String, dynamic>?>();
    bool jsDispatched = false;

    final String js = '''
(async function() {
  try {
    const db = await new Promise((resolve, reject) => {
      const req = indexedDB.open('books');
      req.onupgradeneeded = (e) => {
        e.target.transaction.abort();
        reject('db_not_initialized');
      };
      req.onsuccess = (ev) => {
        const d = ev.target.result;
        if (!d.objectStoreNames.contains('data')) {
          d.close();
          reject('data_store_missing'); return;
        }
        resolve(d);
      };
      req.onerror = (e) => reject(String(e.target.error));
    });

    const record = await new Promise((resolve, reject) => {
      const tx = db.transaction(['data'], 'readonly');
      const get = tx.objectStore('data').get($ttuBookId);
      get.onsuccess = (e) => resolve(e.target.result);
      get.onerror = (e) => reject(String(e.target.error));
    });

    if (!record) {
      db.close();
      window.flutter_inappwebview.callHandler('migResult', null);
      return;
    }

    const title = typeof record.title === 'string' ? record.title : '';
    const html = record.elementHtml || '';
    const sectionsMeta = Array.isArray(record.sections) ? record.sections : [];
    const sections = Array.from(sectionsMeta.map(s => ({
      reference: (s && s.reference) || '',
      label: (s && s.label) || '',
      characters: (s && s.characters) || 0,
      parentChapter: (s && s.parentChapter) || '',
    })));

    const progress = typeof record.progress === 'number' ? record.progress : 0;
    const lastSectionIndex = typeof record.lastSectionIndex === 'number'
        ? record.lastSectionIndex : -1;
    const characters = typeof record.characters === 'number' ? record.characters : 0;

    let coverBase64 = null;
    if (record.coverImage instanceof Blob) {
      coverBase64 = await new Promise((resolve) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result.split(',')[1]);
        reader.onerror = () => resolve(null);
        reader.readAsDataURL(record.coverImage);
      });
    }

    let bookmarkData = null;
    if (db.objectStoreNames.contains('bookmark')) {
      try {
        bookmarkData = await new Promise((resolve) => {
          const tx = db.transaction(['bookmark'], 'readonly');
          const get = tx.objectStore('bookmark').get($ttuBookId);
          get.onsuccess = (e) => resolve(e.target.result || null);
          get.onerror = () => resolve(null);
        });
      } catch (e) {}
    }

    // Extract illustration blobs as base64
    const blobsBase64 = {};
    let blobTotal = 0;
    let blobFailed = 0;
    if (record.blobs && typeof record.blobs === 'object') {
      const entries = Object.entries(record.blobs);
      for (let i = 0; i < entries.length; i++) {
        const [key, blob] = entries[i];
        if (!(blob instanceof Blob)) continue;
        try {
          const b64 = await new Promise((resolve) => {
            const reader = new FileReader();
            reader.onload = () => resolve(reader.result.split(',')[1]);
            reader.onerror = () => {
              console.warn('[ttu-migration] blob read failed: ' + key);
              resolve(null);
            };
            reader.readAsDataURL(blob);
          });
          if (b64) {
            blobsBase64[key] = b64;
            blobTotal += blob.size;
          } else {
            blobFailed++;
          }
        } catch (e) {
          console.warn('[ttu-migration] blob error: ' + key + ' ' + e);
          blobFailed++;
        }
      }
    }
    if (blobFailed > 0) {
      console.warn('[ttu-migration] ' + blobFailed + ' blobs failed to convert');
    }

    db.close();

    window.flutter_inappwebview.callHandler('migResult', {
      title: title,
      elementHtml: html,
      sections: sections,
      coverImageBase64: coverBase64,
      blobsBase64: blobsBase64,
      blobTotalBytes: blobTotal,
      progress: progress,
      lastSectionIndex: lastSectionIndex,
      characters: characters,
      bookmarkData: bookmarkData,
    });
  } catch (e) {
    window.flutter_inappwebview.callHandler('migError', String(e));
  }
})();
''';

    HeadlessInAppWebView? webView;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$serverPort/_hibiki_idb.html'),
      ),
      initialSettings: InAppWebViewSettings(
        databaseEnabled: true,
        domStorageEnabled: true,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        controller.addJavaScriptHandler(
          handlerName: 'migResult',
          callback: (List<dynamic> args) {
            if (completer.isCompleted) return;
            if (args.isEmpty || args[0] == null) {
              completer.complete(null);
            } else {
              completer.complete(args[0] as Map<String, dynamic>);
            }
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'migError',
          callback: (List<dynamic> args) {
            if (completer.isCompleted) return;
            debugPrint(
              'TtuIdbReader.readBookForMigration error: '
              '${args.isNotEmpty ? args[0] : "unknown"}',
            );
            completer.complete(null);
          },
        );
      },
      onLoadStop: (controller, url) async {
        if (jsDispatched) return;
        jsDispatched = true;
        await controller.evaluateJavascript(source: js);
      },
    );

    try {
      await webView.run();
      return await completer.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => null,
      );
    } finally {
      await webView.dispose();
    }
  }
}
