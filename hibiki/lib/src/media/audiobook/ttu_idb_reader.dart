import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';

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
    const out = [];
    for (let i = 0; i < sectionsMeta.length; i++) {
      const s = sectionsMeta[i];
      const ref = s && s.reference;
      if (!ref) continue;
      const el = doc.getElementById(ref);
      const text = el ? stripRuby(el) : '';
      out.push({ index: i, href: ref, label: s.label || '', text: text });
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
        url: WebUri('http://localhost:$serverPort/'),
      ),
      initialSettings: InAppWebViewSettings(
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
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
}
