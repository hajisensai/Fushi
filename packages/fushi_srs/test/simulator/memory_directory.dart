import 'dart:math';
import 'dart:typed_data';

import 'package:fushi_srs/fushi_srs.dart';

/// 模拟的云盘目录：服务器时间由测试控制；可模拟列表延迟（新写的文件暂时不可见）与写入截断。
class MemorySyncDirectory implements SrsSyncDirectory {
  MemorySyncDirectory({required this.serverNow, Random? random})
    : _random = random;

  int Function() serverNow;
  final Random? _random;

  /// 列表延迟概率：新文件在被列出之前要「沉淀」一轮。
  double listDelay = 0;

  final Map<String, Map<String, Uint8List>> files =
      <String, Map<String, Uint8List>>{};
  final Set<String> _settling = <String>{};

  @override
  Future<List<String>> listWriters() async => files.keys.toList()..sort();

  @override
  Future<List<String>?> listFiles(String writerId) async {
    final Map<String, Uint8List>? d = files[writerId];
    if (d == null) return null;
    final List<String> out = <String>[];
    for (final String name in d.keys) {
      final String k = '$writerId/$name';
      if (_settling.remove(k)) continue;
      out.add(name);
    }
    return out..sort();
  }

  @override
  Future<Uint8List?> read(String writerId, String name) async =>
      files[writerId]?[name];

  @override
  Future<void> write(String writerId, String name, Uint8List bytes) async {
    (files[writerId] ??= <String, Uint8List>{})[name] = bytes;
    final Random? r = _random;
    if (r != null && listDelay > 0 && r.nextDouble() < listDelay) {
      _settling.add('$writerId/$name');
    }
  }

  @override
  Future<void> delete(String writerId, String name) async {
    files[writerId]?.remove(name);
  }

  @override
  Future<void> deleteWriter(String writerId) async {
    files.remove(writerId);
  }

  @override
  Future<int?> serverTime(String writerId) async {
    await write(writerId, srsProbeName, Uint8List(0));
    return serverNow();
  }
}
