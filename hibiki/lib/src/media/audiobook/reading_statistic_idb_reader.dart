import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'reading_statistic_model.dart';

/// 从 ttu IndexedDB `books` 库的 `statistic` object store 批量读取统计记录。
///
/// 复用 [TtuIdbReader] 相同的 HeadlessInAppWebView + console.log JSON 模式。
class ReadingStatisticIdbReader {
  static Future<List<ReadingStatistic>> readAll({
    required int serverPort,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    const String js = r'''
(async function() {
  try {
    const db = await new Promise((resolve, reject) => {
      const req = indexedDB.open('books');
      req.onsuccess = (ev) => resolve(ev.target.result);
      req.onerror = (e) => reject(String(e.target.error));
    });
    if (!db.objectStoreNames.contains('statistic')) {
      console.log(JSON.stringify({messageType:'stat_read_ok', records:[]}));
      return;
    }
    const tx = db.transaction(['statistic'], 'readonly');
    const all = await new Promise((resolve, reject) => {
      const req = tx.objectStore('statistic').getAll();
      req.onsuccess = (e) => resolve(e.target.result);
      req.onerror = (e) => reject(String(e.target.error));
    });
    const out = (all || []).map(r => ({
      title: r.title || '',
      dateKey: r.dateKey || '',
      charactersRead: r.charactersRead || 0,
      readingTime: r.readingTime || 0,
      lastStatisticModified: r.lastStatisticModified || 0,
    }));
    console.log(JSON.stringify({messageType:'stat_read_ok', records: out}));
  } catch(e) {
    console.log(JSON.stringify({messageType:'stat_read_err', error: String(e)}));
  }
})();
''';

    final Completer<List<ReadingStatistic>> completer =
        Completer<List<ReadingStatistic>>();
    bool jsDispatched = false;

    HeadlessInAppWebView? webView;
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
        if (completer.isCompleted) return;
        try {
          final Map<String, dynamic> msg =
              jsonDecode(message.message) as Map<String, dynamic>;
          final String type = msg['messageType'] as String? ?? '';
          if (type == 'stat_read_ok') {
            final List<dynamic> raw = msg['records'] as List<dynamic>;
            final List<ReadingStatistic> results = raw.map((dynamic e) {
              final Map<String, dynamic> m = e as Map<String, dynamic>;
              final stat = ReadingStatistic()
                ..title = m['title'] as String? ?? ''
                ..dateKey = m['dateKey'] as String? ?? ''
                ..charactersRead = (m['charactersRead'] as num?)?.toInt() ?? 0
                ..readingTimeMs = ((m['readingTime'] as num?)?.toInt() ?? 0) * 1000
                ..lastStatisticModified =
                    (m['lastStatisticModified'] as num?)?.toInt() ?? 0;
              return stat;
            }).toList();
            completer.complete(results);
          } else if (type == 'stat_read_err') {
            completer.completeError(
              StateError('stat_read_err: ${msg['error']}'),
            );
          }
        } catch (e) {
          debugPrint('ReadingStatisticIdbReader console decode error: $e');
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
