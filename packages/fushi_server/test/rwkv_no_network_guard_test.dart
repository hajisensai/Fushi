// 守卫：服务端单元测试不碰外网下 RWKV 权重。`HeadlessHost` / `ServerSrs` 不注入时用真 HTTP 客户端
// （`createAppHttpClient`），库里一有 RWKV 牌组（默认算法就是 RWKV）就去 GitHub 下权重——CI 上它下到一半测试已经
// 收尾、临时目录已删，收尾写校验标记撞上 PathNotFoundException（admin_srs_device_trust_test 的偶发红）。
// 所以 test/ 下每一处构造都必须显式注入（`srsRwkvHttpClient:` / `rwkvHttpClient:`，替身见 support/fake_rwkv.dart）。
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'test/ 下每个 HeadlessHost(...) / ServerSrs(...) 都注入了 RWKV 下载用的 HTTP 客户端',
    () {
      final Directory dir = Directory(p.join(Directory.current.path, 'test'));
      final RegExp host = RegExp(r'(?<![A-Za-z_])HeadlessHost\(');
      final RegExp srs = RegExp(r'(?<![A-Za-z_])ServerSrs\(');
      final List<String> offenders = <String>[];
      int checked = 0;
      for (final FileSystemEntity e in dir.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('_test.dart')) continue;
        if (p.basename(e.path) == 'rwkv_no_network_guard_test.dart') continue;
        final String text = e.readAsStringSync();
        final int hosts = host.allMatches(text).length;
        final int servers = srs.allMatches(text).length;
        if (hosts == 0 && servers == 0) continue;
        checked++;
        final int hostClients = 'srsRwkvHttpClient:'.allMatches(text).length;
        final int srsClients = RegExp(
          r'(?<![A-Za-z_])rwkvHttpClient:',
        ).allMatches(text).length;
        if (hostClients < hosts || srsClients < servers) {
          offenders.add(
            '${p.relative(e.path, from: Directory.current.path)}: '
            'HeadlessHost $hosts / srsRwkvHttpClient $hostClients, '
            'ServerSrs $servers / rwkvHttpClient $srsClients',
          );
        }
      }
      expect(checked, greaterThan(10), reason: '目录枚举没找到构造点，守卫失效');
      expect(offenders, isEmpty);
    },
  );
}
