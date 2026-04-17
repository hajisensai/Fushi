import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';

/// 从 ッツ Ebook Reader 的 IndexedDB `books` store 读取一本书的章节纯文本。
///
/// Sasayaki 匹配需要 EPUB 文本，但 fork 没有 Flutter 侧的 EPUB 解析器——书籍
/// 的文本由 ttu 解析后放在 `elementHtml`。这里用 HeadlessInAppWebView 在
/// ttu 源域下打开 IDB，用 `DOMParser` 把 `elementHtml` 拆成章节并取
/// `textContent`，避免在 Dart 侧再写一套 HTML 剥离。
class TtuIdbReader {
  /// 读取 `ttuBookId` 对应 books 记录的章节文本。
  ///
  /// 返回按 ttu 顺序（`sections` 字段）的 [EpubSection] 列表；若该 id 不存在
  /// 抛 `StateError`。
  static Future<List<EpubSection>> readSections({
    required int ttuBookId,
    required int serverPort,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (ttuBookId <= 0) {
      throw ArgumentError('ttuBookId must be > 0');
    }

    final String js = '''
(async function() {
  try {
    const record = await new Promise((resolve, reject) => {
      const req = indexedDB.open('books');
      req.onsuccess = (ev) => {
        const db = ev.target.result;
        if (!db.objectStoreNames.contains('data')) {
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
    const html = record.elementHtml || '';
    const sectionsMeta = Array.isArray(record.sections) ? record.sections : [];
    const parser = new DOMParser();
    const doc = parser.parseFromString('<div>' + html + '</div>', 'text/html');
    const out = [];
    for (let i = 0; i < sectionsMeta.length; i++) {
      const s = sectionsMeta[i];
      const ref = s && s.reference;
      if (!ref) continue;
      const el = doc.getElementById(ref);
      const text = el ? (el.textContent || '') : '';
      out.push({ index: i, href: ref, label: s.label || '', text: text });
    }
    // Fallback: 没有 sections 时，把整份 elementHtml 当一章
    if (out.length === 0) {
      const body = doc.body.firstChild;
      const text = body ? (body.textContent || '') : '';
      out.push({ index: 0, href: 'ttu-body', label: '', text: text });
    }
    console.log(JSON.stringify({messageType: 'ttu_read_ok', sections: out}));
  } catch (e) {
    console.log(JSON.stringify({messageType: 'ttu_read_err', error: String(e)}));
  }
})();
''';

    final Completer<List<EpubSection>> completer =
        Completer<List<EpubSection>>();
    HeadlessInAppWebView? webView;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$serverPort/'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      ),
      onLoadStop: (controller, url) async {
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
            final List<dynamic> raw = msg['sections'] as List<dynamic>;
            final List<EpubSection> sections = raw.map((dynamic e) {
              final Map<String, dynamic> m = e as Map<String, dynamic>;
              return EpubSection(
                index: (m['index'] as num).toInt(),
                href: m['href'] as String? ?? '',
                text: m['text'] as String? ?? '',
              );
            }).toList();
            completer.complete(sections);
          } else if (type == 'ttu_read_err') {
            completer.completeError(
              StateError('ttu_read_err: ${msg['error']}'),
            );
          }
        } catch (e) {
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

  /// 读取 `ttuBookId` 对应 books 记录的 `title` 字段。
  ///
  /// 用于 EPUB 刚被 ttu 导入后、我们需要构造与 `ttuBooksProvider` 一致的
  /// `MediaItem.uniqueKey`（其 mediaIdentifier 形如 `.../b.html?id=X&?title=Y`）。
  /// 未找到或字段缺失时返回空串，调用方自行兜底。
  static Future<String> readTitle({
    required int ttuBookId,
    required int serverPort,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (ttuBookId <= 0) {
      throw ArgumentError('ttuBookId must be > 0');
    }

    final String js = '''
(async function() {
  try {
    const record = await new Promise((resolve, reject) => {
      const req = indexedDB.open('books');
      req.onsuccess = (ev) => {
        const db = ev.target.result;
        if (!db.objectStoreNames.contains('data')) {
          reject('data_store_missing'); return;
        }
        const tx = db.transaction(['data'], 'readonly');
        const get = tx.objectStore('data').get($ttuBookId);
        get.onsuccess = (e) => resolve(e.target.result);
        get.onerror = (e) => reject(String(e.target.error));
      };
      req.onerror = (e) => reject(String(e.target.error));
    });
    const title = record && typeof record.title === 'string' ? record.title : '';
    console.log(JSON.stringify({messageType: 'ttu_title_ok', title: title}));
  } catch (e) {
    console.log(JSON.stringify({messageType: 'ttu_title_err', error: String(e)}));
  }
})();
''';

    final Completer<String> completer = Completer<String>();
    HeadlessInAppWebView? webView;
    webView = HeadlessInAppWebView(
      initialUrlRequest: URLRequest(
        url: WebUri('http://localhost:$serverPort/'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      ),
      onLoadStop: (controller, url) async {
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
          if (type == 'ttu_title_ok') {
            completer.complete(msg['title'] as String? ?? '');
          } else if (type == 'ttu_title_err') {
            completer.completeError(
              StateError('ttu_title_err: ${msg['error']}'),
            );
          }
        } catch (e) {
          debugPrint('TtuIdbReader.readTitle console decode error: $e');
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
}
