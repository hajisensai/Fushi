import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/mining/galgame_library.dart';

/// galgame 游戏库（首页「游戏」tab）纯函数守卫：名称推导 / 新条目默认 / JSON 编解码
/// 往返 + 容错。持久化走偏好表单一 JSON key，故这些纯函数是列表持久化的根契约。
void main() {
  group('galgameNameFromExe', () {
    test('去掉路径与扩展名', () {
      expect(galgameNameFromExe(r'D:\games\Sakura\sakura.exe'), 'sakura');
      expect(galgameNameFromExe('/opt/games/muv/muvluv.exe'), 'muvluv');
      expect(galgameNameFromExe('bare.exe'), 'bare');
    });

    test('无扩展名回退整文件名', () {
      expect(galgameNameFromExe(r'C:\g\launcher'), 'launcher');
    });
  });

  group('newGalgameEntryFromExe', () {
    test('默认名取文件名去扩展名，workdir 取 exe 目录，id 非空', () {
      final DateTime now = DateTime.fromMillisecondsSinceEpoch(1700000000000);
      final GalgameEntry e =
          newGalgameEntryFromExe(r'D:\games\Sakura\sakura.exe', now: now);
      expect(e.name, 'sakura');
      expect(e.workdir, r'D:\games\Sakura');
      expect(e.exePath, r'D:\games\Sakura\sakura.exe');
      expect(e.id, isNotEmpty);
      expect(e.addedAt, now);
      expect(e.coverPath, isNull);
    });

    test('显式 name 覆盖默认', () {
      final GalgameEntry e = newGalgameEntryFromExe(
        r'D:\g\a.exe',
        name: '樱之诗',
      );
      expect(e.name, '樱之诗');
    });
  });

  group('encode/decode round-trip', () {
    test('空列表编码为空串，空串解码为空列表', () {
      expect(encodeGalgameLibrary(const <GalgameEntry>[]), '');
      expect(decodeGalgameLibrary(''), isEmpty);
    });

    test('往返保真', () {
      final List<GalgameEntry> games = <GalgameEntry>[
        newGalgameEntryFromExe(
          r'D:\g\a.exe',
          now: DateTime.fromMillisecondsSinceEpoch(1000),
        ),
        newGalgameEntryFromExe(
          r'E:\g2\b.exe',
          now: DateTime.fromMillisecondsSinceEpoch(2000),
          name: 'Beta',
        ),
      ];
      final List<GalgameEntry> back =
          decodeGalgameLibrary(encodeGalgameLibrary(games));
      expect(back.length, 2);
      expect(back[0].exePath, r'D:\g\a.exe');
      expect(back[0].name, 'a');
      expect(back[1].name, 'Beta');
      expect(back[1].workdir, r'E:\g2');
      expect(back[1].addedAt.millisecondsSinceEpoch, 2000);
    });

    test('坏数据（非数组 / 缺关键字段）容错回退', () {
      expect(decodeGalgameLibrary('not json'), isEmpty);
      expect(decodeGalgameLibrary('{"a":1}'), isEmpty);
      // 数组里缺 exePath 的条目被跳过，合法条目保留。
      const String raw =
          '[{"id":"1","name":"x"},{"id":"2","name":"y","exePath":"D:/g/y.exe"}]';
      final List<GalgameEntry> out = decodeGalgameLibrary(raw);
      expect(out.length, 1);
      expect(out.single.exePath, 'D:/g/y.exe');
    });
  });
}
