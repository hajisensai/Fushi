import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-714 守卫：互联 live 书籍推送（client→host）全部 HTTP 500。
///
/// 历史 bug = `AppModelLibraryHostService` 的 `importBookFromFile` 回调是可选的
/// （null 时 `importBook` 抛 `UnsupportedError`），而 `AppModel` 里唯一的生产
/// 构造点（`libraryServiceFactory`）忘了接线它。于是 host 收到对端 client 的
/// `PUT /api/library/books/<title>` 时，`importBook` 抛 `UnsupportedError`，被
/// 服务端 `catch` 成 `HTTP 500`，互联/自动同步的书籍推送整体失效——`SyncRunReport`
/// 只看得到裸 `HTTP 500`（client 侧丢弃了服务端的 `Import failed: <e>` 响应体）。
///
/// 单元测试无法挡住这个回归：`hibiki_library_host_service_*` 测试都自己注入了
/// `importBookFromFile` 假回调，生产忘了注入照样绿。故在源码级钉死：生产工厂必须
/// 把 `importBookFromFile` 接到真实导入原语 `EpubImporter.importFromPath`。
void main() {
  String read(String relative) {
    final File f = File(relative);
    expect(f.existsSync(), isTrue, reason: 'missing source file: $relative');
    return f.readAsStringSync();
  }

  group('BUG-714 host library service wires book import in production factory',
      () {
    test(
        'AppModel.libraryServiceFactory passes importBookFromFile bound to '
        'EpubImporter.importFromPath', () {
      final String src = read('lib/src/models/app_model.dart');

      // 生产工厂里确实构造了 host service。
      expect(src, contains('AppModelLibraryHostService('),
          reason: 'app_model 必须构造 AppModelLibraryHostService 作为互联 host 服务');

      // 关键接线：importBookFromFile 必须被显式传入（缺则 importBook 抛
      // UnsupportedError → PUT 书籍 500）。
      expect(src, contains('importBookFromFile:'),
          reason: '生产工厂必须接线 importBookFromFile，否则互联书籍推送全部 HTTP 500');

      // 接线的必须是真实导入原语 EpubImporter.importFromPath（不是空实现/桩）。
      expect(src, contains('EpubImporter.importFromPath('),
          reason: 'importBookFromFile 必须接到真实导入原语 EpubImporter.importFromPath');
    });
  });
}
