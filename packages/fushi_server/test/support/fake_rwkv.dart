// 服务端测试用的 RWKV 替身：后台 runtime 换成按卡给定 R 的假后端，权重「已就绪」不碰网络。
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_rwkv_attach.dart';
import 'package:fushi_engine/srs/srs_rwkv_models.dart';
import 'package:fushi_engine/srs/srs_rwkv_service.dart';

/// 不碰网络的 HTTP 客户端工厂：下载 RWKV 权重当场失败（服务转「出错」）。
HttpClient noNetworkHttpClient() =>
    throw const SocketException('network disabled in tests');

/// 让 [support] 下的 RWKV 权重看起来「已下载并校验过」（替身后端不读它，只要长度与校验标记对得上）。
void markRwkvWeightsReady(Directory support) {
  final Directory dir = srsRwkvModelsDir(support)..createSync(recursive: true);
  final File weights = SrsRwkvModels(dir: dir).weightsFile
    ..writeAsBytesSync(Uint8List(kSrsRwkvSmallWeightsBytes));
  File(
    '${weights.path}.verified',
  ).writeAsStringSync(kSrsRwkvSmallWeightsSha256);
}

/// 假后端：查询按卡的数字 id 给 [r]（没设的给 [defaultR]）。撤销日志与分数表照原生契约模拟到编排用得着的程度。
class FakeRwkvBackend implements SrsRwkvBackend {
  final Map<int, double> r = <int, double>{};
  double defaultR = 0.5;
  int replayedRows = 0;
  int appendedRows = 0;
  bool closed = false;
  final List<String> snapshotPaths = <String>[];
  final List<(int tag, int at)> _journal = <(int, int)>[];
  final Map<int, (int, double)> _scores = <int, (int, double)>{};

  double _r(int card) => r[card] ?? defaultR;

  @override
  Future<void> replay(RwkvRows rows) async {
    replayedRows += rows.length;
    _journal.clear();
    _scores.clear();
  }

  @override
  Future<bool> append(RwkvRows rows, List<int> tags, List<int> ats) async {
    appendedRows += rows.length;
    for (int i = 0; i < rows.length; i++) {
      _journal.add((tags[i], ats[i]));
      _scores.remove(rows.cardIdAt(i));
    }
    return true;
  }

  @override
  Future<bool> unappend(int tag) async {
    if (_journal.isEmpty || _journal.last.$1 != tag) return false;
    _journal.removeLast();
    return true;
  }

  @override
  Future<int?> rewindFrom(int atMs, int floorMs) async {
    if (floorMs >= atMs) return null;
    int n = 0;
    while (_journal.isNotEmpty && _journal.last.$2 >= atMs) {
      _journal.removeLast();
      n++;
    }
    return n;
  }

  @override
  Future<Float32List> query(RwkvRows rows) async => Float32List.fromList(
    <double>[for (int i = 0; i < rows.length; i++) _r(rows.cardIdAt(i))],
  );

  @override
  Future<void> clearScores() async => _scores.clear();

  @override
  Future<RwkvScoreLookup> lookupScores(
    Int64List cardIds,
    Uint64List versions,
  ) async {
    final Float32List out = Float32List(cardIds.length);
    final Uint8List found = Uint8List(cardIds.length);
    for (int i = 0; i < cardIds.length; i++) {
      final (int, double)? e = _scores[cardIds[i]];
      if (e != null && e.$1 == versions[i]) {
        out[i] = e.$2;
        found[i] = 1;
      } else {
        out[i] = double.nan;
      }
    }
    return RwkvScoreLookup(out, found);
  }

  @override
  Future<Float32List> updateScores(
    RwkvRows rows,
    Uint64List versions,
    Int64List anchorsMs,
  ) async {
    final Float32List out = Float32List(rows.length);
    for (int i = 0; i < rows.length; i++) {
      out[i] = _r(rows.cardIdAt(i));
      _scores[rows.cardIdAt(i)] = (versions[i], out[i]);
    }
    return out;
  }

  @override
  Future<int> requeryScores(int today, int nowMs) async {
    for (final int card in _scores.keys.toList()) {
      _scores[card] = (_scores[card]!.$1, _r(card));
    }
    return _scores.length;
  }

  @override
  Future<int> removeScores(Int64List cardIds) async {
    int n = 0;
    for (final int id in cardIds) {
      if (_scores.remove(id) != null) n++;
    }
    return n;
  }

  @override
  Future<Uint8List> snapshot() async => Uint8List(0);

  @override
  Future<void> restore(Uint8List snapshot) async {
    _journal.clear();
    _scores.clear();
  }

  @override
  Future<void> snapshotToFile(String path) async {
    snapshotPaths.add(path);
    await File(path).writeAsBytes(const <int>[1]);
  }

  @override
  Future<void> restoreFromFile(String path) async {
    _journal.clear();
    _scores.clear();
  }

  @override
  Future<void> reset() async {
    _journal.clear();
    _scores.clear();
  }

  @override
  Future<void> close() async => closed = true;
}
