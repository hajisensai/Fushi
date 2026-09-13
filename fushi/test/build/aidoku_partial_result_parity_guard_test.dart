import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-2262：macOS 上 Aidoku 作品页的章节列表恒为空，且不报任何错。
///
/// aidoku-rs 的源不是在 `get_manga_update` 的返回值里给章节列表的——它把章节
/// 通过 `env.send_partial_result` 单独推出来（搜索的补充条目同理）。iOS 那侧
/// （`embedded.rs`）自己实现了这个 import 并在拿到最终结果后合并 partial；
/// 桌面那侧（`main.rs`）直接用了上游 `aidoku-test-runner` 的 import object，
/// 而上游把 `send_partial_result` 注册成**显式空实现**（源码注释原话：
/// "leaving this function unimplemented for now since the test runner doesn't
/// use partial results"）。于是整份章节列表被丢进黑洞：搜索正常、详情正常、
/// 章节恒为空，`chaptersOf()` 拿到 null 就静静返回空列表，UI 连错误横幅都不挂。
///
/// 这组守卫钉的不变式是：**两个 runtime 对 partial result 的处理必须对等**。
/// 只在 iOS 侧加一种 partial 用法、桌面侧忘了跟，就是这个 bug 的复发形态，
/// 所以每条断言都成对检查 `embedded.rs` 与 `main.rs`。
void main() {
  String readCode(String path) {
    final File file = File(path);
    expect(
      file.existsSync(),
      isTrue,
      reason: 'expected file at ${file.absolute.path}',
    );
    // 掩注释再折叠空白：本文件里每条 needle 都同时出现在解释性注释中，不掩就
    // 会拿注释假绿；折叠空白是为了不被 rustfmt 的换行位置绑死。
    return compactCode(maskComments(file.readAsStringSync()));
  }

  late final String desktop = readCode('../native/aidoku_runtime/src/main.rs');
  late final String embedded = readCode(
    '../native/aidoku_runtime/src/embedded.rs',
  );

  test('桌面 runtime 自己实现 env.send_partial_result，不吃上游的空实现', () {
    expect(
      desktop,
      contains('import_object.define("env","send_partial_result",'),
      reason: 'imports::generate_imports() 给的是上游的 no-op。不覆盖它，'
          '源推出来的章节列表就整份丢失（BUG-2262）。',
    );
    expect(
      desktop,
      contains('fnhost_send_partial_result('),
      reason: '覆盖必须指向真正读 wasm 内存的 host 函数，不能又是个空壳。',
    );
    expect(
      embedded,
      contains('"send_partial_result",'),
      reason: 'iOS 侧一直实现着它；这条掉了说明两侧一起塌了。',
    );
  });

  test('两侧都把 partial 里的章节合并进 details 结果', () {
    for (final MapEntry<String, String> runtime in <String, String>{
      'main.rs': desktop,
      'embedded.rs': embedded,
    }.entries) {
      expect(
        runtime.value,
        contains('result.chapters=partial.chapters;'),
        reason: '${runtime.key} 没有合并 partial 章节。get_manga_update 的返回值里'
            'chapters 往往是 None，不合并就等于作品页永远没有章节。',
      );
      expect(
        runtime.value,
        contains('postcard::from_bytes::<Manga>(&bytes)'),
        reason: '${runtime.key} 必须按 Manga 解码 partial 负载。',
      );
    }
  });

  test('两侧都把 partial 里的补充条目合并进搜索结果', () {
    for (final MapEntry<String, String> runtime in <String, String>{
      'main.rs': desktop,
      'embedded.rs': embedded,
    }.entries) {
      expect(
        runtime.value,
        contains('result.entries.push(partial);'),
        reason: '${runtime.key} 丢掉了以 partial 形式补发的搜索条目。',
      );
      expect(
        runtime.value,
        contains('!result.entries.iter().any(|manga|manga.key==partial.key)'),
        reason: '${runtime.key} 合并搜索条目时必须按 key 去重，否则会出现重复卡片。',
      );
    }
  });

  test('桌面 runtime 每次调用后清空 partial 缓冲，不跨调用串味', () {
    expect(
      desktop,
      contains('fntake_partials(&mutself)->Vec<Vec<u8>>'),
      reason: '取用必须是「取走」语义。',
    );
    expect(
      desktop,
      contains(
        'std::mem::take(&mutself.partials.as_mut(&mutself.store).buffers)',
      ),
      reason: '留着不清，下一次调用会把上一次的章节当成自己的结果——'
          '一个进程一条命令时看不出来，但 runtime 是可复用的。',
    );
  });

  test('partial 负载长度按 8 字节头解析，短于头的一律丢弃', () {
    expect(
      desktop,
      contains('fnpartial_result_payload_length(header:[u8;4])->Option<usize>'),
      reason: '线格式由 aidoku-rs 定死，解析必须是可单测的独立函数。',
    );
    expect(
      desktop,
      contains('iflength<8{'),
      reason: '头本身占 8 字节，小于 8 的长度不是合法 partial。',
    );
  });

  test('Dart 侧仍然只从 details 的 chapters 键里取章节', () {
    final String adapter = readCode(
      'lib/src/media/manga/library/online_manga_runtime_adapter.dart',
    );

    expect(
      adapter,
      contains("details['chapters']"),
      reason: 'Rust 侧的合并结果就是喂给这里的。消费口一旦改名，上面所有断言就'
          '变成在守一份没人读的数据。',
    );
  });
}
