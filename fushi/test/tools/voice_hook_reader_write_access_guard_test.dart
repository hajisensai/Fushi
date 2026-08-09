// 守卫：galgame 共享内存的**读端必须保留写权限**，不许被"顺手收紧成只读"。
//
// 为什么（BUG-1225）——这条理由必须具体到能阻止再犯，写"需要写权限"没有用：
//
//   `VoiceHookReader::SelectTextThread`（`fushi/windows/runner/voice_hook_reader.cpp:446`）
//   会对**映射内**的 `SharedHeader::selected_text_thread_id`
//   （`fushi/windows/runner/voice_hook_ipc.h:162`，`volatile uint64_t`）做一次
//   `InterlockedExchange64` 原子写。那不是普通赋值、也不是 memcpy，所以按 `=` 或
//   `memcpy` 搜"读端写不写共享内存"会**搜不到它**——本守卫的存在就是因为有人（作者本人）
//   正是这样漏检的，差点把 `FILE_MAP_WRITE` 去掉。
//
//   去掉写权限的后果不是"功能失效"而是**崩溃**：以 `FILE_MAP_READ` 映射的页是
//   PAGE_READONLY，往上面做原子写触发 ACCESS_VIOLATION，而 `SelectTextThread` 周围没有
//   SEH。这条路径还在**自动**流程上（`gal_hook_session_controller.dart:2199` 自动挑选文本
//   线程，不需要用户手动点），所以是常规 galgame 文本 hook 一跑就崩。
//
//   `selected_text_thread_id` 是一条真实的**读端 → 注入端控制通道**，注入端确实读它：
//   `native/galgame_hook/hook/adapters/kirikiri_adapter.inc:114`、
//   `native/galgame_hook/include/luna_text_selector.h`、
//   `native/galgame_hook/injector/injector_main.cpp:764`。
//
// 本守卫**把要求绑在成因上**而不是把 `FILE_MAP_WRITE` 永久钉死：先断言那处原子写还在，
// 再要求打开标志带写权限。哪天 `SelectTextThread` 真的改走别的通道、读端不再写共享内存，
// 第一条断言会先失败并指明"前提没了，本守卫可以连同写权限一起撤"——守卫自己会退休，
// 不会变成一条没人敢动的化石。
//
// 🔴 这条守卫只到**源码扫描**这一层。`fushi/windows/runner/voice_hook_reader.cpp` 由
// `fushi/windows/runner/CMakeLists.txt` 编译进 Flutter Windows runner，与
// `native/galgame_hook/` 那套 ctest **不是同一个构建单元**，那 22 条 ctest 一行都跑不到它。
// 所以它证明不了运行时行为，只能保证"这两处源码事实同时成立或同时不成立"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../helpers/source_guard.dart';

/// 从当前 cwd 向上找含 `fushi/windows/runner` 的仓库根。
Directory _repoRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (Directory('${dir.path}/fushi/windows/runner').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 fushi/windows/runner 的仓库根（从 ${Directory.current.path} 向上）');
}

/// 剥掉 `//` 行注释与 `/* */` 块注释再匹配。
///
/// 源码扫描守卫最经典的假绿：真代码改掉、注释里还留着同一串字面量，守卫照绿。本文件上面
/// 的说明里就反复出现 `FILE_MAP_WRITE` 和 `InterlockedExchange64`，剥完不该再被任何断言看见。
String _stripComments(String source) => maskComments(source);

/// 取 [source] 中从 [signature] 起到该函数结尾（列 0 的 `}`）的函数体。
String _functionBody(String source, String signature) {
  final int at = source.indexOf(signature);
  expect(at, greaterThan(0), reason: '扫不到 $signature —— 判红，别让空集假绿');
  final int end = source.indexOf('\n}', at);
  expect(end, greaterThan(at), reason: '扫不到 $signature 的函数体结尾 —— 判红');
  return source.substring(at, end);
}

void main() {
  final Directory root = _repoRoot();
  final String readerPath =
      '${root.path}/fushi/windows/runner/voice_hook_reader.cpp';
  // 契约只有一份真相源：host 读侧的手抄副本已删除，直接读 native 头
  // （守卫见 test/mining/gal_ipc_contract_single_source_test.dart）。
  final String ipcPath =
      '${root.path}/native/galgame_hook/include/voice_hook_ipc.h';

  test('前提：读端仍然会对映射内的 selected_text_thread_id 做原子写', () {
    final String ipc = _stripComments(File(ipcPath).readAsStringSync());
    expect(
      ipc,
      contains('selected_text_thread_id'),
      reason: 'selected_text_thread_id 必须仍是共享内存 SharedHeader 的字段；'
          '它要是搬出映射了，写权限的前提就变了',
    );

    final String reader = _stripComments(File(readerPath).readAsStringSync());
    final String body =
        _functionBody(reader, 'bool VoiceHookReader::SelectTextThread');
    expect(
      body,
      contains('InterlockedExchange64'),
      reason: '前提消失：SelectTextThread 不再对共享内存做原子写。'
          '若确实改走了别的通道，请连同本守卫与 FILE_MAP_WRITE 一起撤，而不是只删这条断言',
    );
    expect(
      body,
      contains('selected_text_thread_id'),
      reason: '前提消失：写的目标已不是映射内的 selected_text_thread_id',
    );
  });

  test('因此：Open 打开共享内存时必须带 FILE_MAP_WRITE（去掉会 ACCESS_VIOLATION 崩溃）', () {
    final String reader = _stripComments(File(readerPath).readAsStringSync());
    final String body =
        _functionBody(reader, 'VoiceHookOpenResult VoiceHookReader::Open');

    // 判据落在**这两个调用各自的实参上**，不是"整个函数体里出现过 FILE_MAP_WRITE"——
    // 后者会被"一处保留、另一处改成只读"骗过，而两处任缺其一都同样让原子写落在只读页上。
    for (final String call in <String>['OpenFileMappingW', 'MapViewOfFile']) {
      final int at = body.indexOf(call);
      expect(at, greaterThan(0), reason: 'Open 里扫不到 $call —— 判红');
      final int close = body.indexOf(')', at);
      expect(close, greaterThan(at), reason: '$call 的实参列表扫不到结尾 —— 判红');
      final String args = body.substring(at, close);
      expect(
        args,
        contains('FILE_MAP_WRITE'),
        reason:
            '$call 少了 FILE_MAP_WRITE：SelectTextThread 的 InterlockedExchange64 '
            '会写到 PAGE_READONLY 页上，触发 ACCESS_VIOLATION 且无 SEH——'
            'galgame 文本 hook 的自动选线程路径一跑就崩，不是"功能降级"',
      );
    }
  });
}
