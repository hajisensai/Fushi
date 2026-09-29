import 'dart:convert';
import 'dart:io';

/// 仓库根：从当前目录（flutter test 时是包目录）向上找含 services/leaderboard 的目录。
Directory leaderboardRepoRoot() {
  Directory dir = Directory.current.absolute;
  while (true) {
    if (Directory('${dir.path}/services/leaderboard').existsSync()) return dir;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('repo root with services/leaderboard not found');
    }
    dir = parent;
  }
}

Directory leaderboardVectorDir() => Directory(
  '${leaderboardRepoRoot().path}/services/leaderboard/test/vectors',
);

Map<String, dynamic> readVector(String name) =>
    (jsonDecode(File('${leaderboardVectorDir().path}/$name').readAsStringSync())
            as Map<Object?, Object?>)
        .cast<String, dynamic>();
