import 'package:flutter_test/flutter_test.dart';

import '../helpers/part_corpus_disk_guard.dart';
import 'fushi_sync_server_source_corpus.dart';

/// 互联 HTTP 服务器「合并语料」自身的守卫。
///
/// 这份语料喂的是一台**对外监听的服务器**的安全守卫：路径穿越闸门只能有一处实现、
/// PIN 不得明文、共享 handler 壳不得被抄回本地、WebDAV 写链串行。它们大多是负向
/// 断言，而负向断言少读一个文件就静默真空通过。
///
/// 生产侧 [partCorpusFiles] 按 `*.part.dart` 后缀过滤：将来谁在
/// `lib/src/sync/fushi_sync_server/` 下加一个 `part of` 了但没按 `.part.dart` 命名的
/// 文件（同步域里 `fushi_manga_ocr_host.dart` 这种「另开一个文件」很常见），它会被
/// 静默跳过，而上面那批负向断言对它全部失明。该 helper 的基准刻意放宽成全部
/// `.dart` 就是为了堵这条。
///
/// 还有一条隐式依赖也归这里守：`fushi_sync_server_hardening_test` 的
/// `case 'PUT':` → `case 'HEAD':` 切片，在拆分后语料里另有 6 处 `case 'PUT':`
/// （library / sync_state / video 三个 part），切片正确**完全依赖「主壳恒在语料
/// 首位」**——而那正是 [expectPartManifestMatchesDisk] 的第一行断言。
///
/// 路径字面量在这里**故意再写一遍**，不从语料文件 import——守卫和被守对象共用同一个
/// 枚举时，那个枚举的缺陷会让双方在同一处同时失明。
void main() {
  group('互联服务器合并语料覆盖磁盘上的全部 part', () {
    test('主壳 + 每个 part 都在清单里、顺序确定（漏登记 = 负向断言真空通过）', () {
      expectPartManifestMatchesDisk(
        manifest: fushiSyncServerFiles(),
        shellPath: 'lib/src/sync/fushi_sync_server.dart',
        partDirPath: 'lib/src/sync/fushi_sync_server',
      );
    });

    test('每个 part 的内容真的进了语料（不只是路径进了清单）', () {
      expectPartContentsInCorpus(
        manifest: fushiSyncServerFiles(),
        corpus: readFushiSyncServerSource(),
      );
    });
  });
}
