// WebUI 设计系统共享库（web_kit.g.dart）必须与真源 tools/browser-extension/ 逐字一致：
// 改了扩展的 theme.css / material.css / … 却没跑 sync-mirrors.mjs，这里就红。
import 'dart:io';

import 'package:fushi_server/src/admin/web_kit.dart';
import 'package:fushi_server/src/admin/web_kit.g.dart';
import 'package:test/test.dart';

void main() {
  final Directory source = Directory('../../tools/browser-extension');

  test('kWebKitFiles 与 tools/browser-extension 真源逐字一致', () {
    expect(source.existsSync(), isTrue, reason: '找不到真源目录 ${source.path}');
    for (final MapEntry<String, String> e in kWebKitFiles.entries) {
      final File f = File('${source.path}/${e.key}');
      expect(f.existsSync(), isTrue, reason: e.key);
      expect(
        e.value,
        f.readAsStringSync(),
        reason:
            '${e.key} 漂移：跑 `node tools/browser-extension/scripts/sync-mirrors.mjs` 重生成',
      );
    }
  });

  test('/kit/ 地址带内容哈希版本号，未知文件 404', () async {
    expect(
      webKitUrl('theme.css'),
      matches(RegExp(r'^/kit/theme\.css\?v=[0-9a-f]{12}$')),
    );
    expect(() => webKitUrl('nope.js'), throwsArgumentError);
    expect(serveWebKitFile('nope.js').statusCode, 404);
    final response = serveWebKitFile('material.css');
    expect(response.statusCode, 200);
    expect(response.headers['content-type'], startsWith('text/css'));
    expect(response.headers['cache-control'], contains('immutable'));
    expect(await response.readAsString(), kWebKitFiles['material.css']);
  });
}
