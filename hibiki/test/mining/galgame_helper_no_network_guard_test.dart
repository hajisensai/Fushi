import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// 复用同款字符级注释剥除器，避免文档/行/块注释里的示例文字污染静态守卫。
import '../sync/desktop_lookup_foreground_guard_static_test.dart'
    show stripDartComments;

/// BUG-1196 静态守卫：**galgame helper 安装器不得联网**。
///
/// 这个文件原本守的是反向不变式（BUG-1076：把 helper 自更新从「点启动游戏」那一刻挪到
/// app 启动后台）。BUG-1196 把整条网络路径连根删掉之后，那条不变式没有了守的对象 ——
/// 两架构 zip 随 Windows 主包发布，helper 版本与 app 版本强绑定。
///
/// 为什么改成守「不许联网」而不是直接删掉本文件：helper 装的是 injector exe + 会被注入
/// 用户游戏进程的 hook DLL，一条「后台静默从网上取原生代码」的通道就是 BUG-1103 记的那个
/// 攻击面。删掉容易、被顺手加回来更容易，所以留一条会红的守卫，逼后来者先读这段说明。
///
/// 用源码守卫而不是行为测试的原因同旧版：`ensureInjector` 首行 `if (!Platform.isWindows)`
/// 早退，CI 测试宿主根本进不了真实路径。
void main() {
  const String installer = 'lib/src/mining/galgame_helper_installer.dart';
  const String mainDart = 'lib/main.dart';

  String readStripped(String path) =>
      stripDartComments(File(path).readAsStringSync());

  group('helper 安装器不得联网', () {
    test('安装器源码里没有任何 HTTP 客户端 / 下载入口', () {
      final String src = readStripped(installer);
      for (final String needle in <String>[
        'HttpClient',
        'applyUpdateProxy',
        'ResumableDownload',
        'https://',
      ]) {
        expect(
          src.contains(needle),
          isFalse,
          reason: 'helper 随主包发布，安装器不该出现「$needle」——'
              '它注入用户游戏进程的原生代码，联网取包即 BUG-1103 的攻击面',
        );
      }
    });

    test('后台静默自更新已删除，且 main.dart 不再调用', () {
      expect(
        readStripped(installer).contains('updateInstalledHelpersInBackground'),
        isFalse,
        reason: 'helper 版本与 app 版本强绑定：要新 helper 就更新 app',
      );
      expect(
        readStripped(mainDart).contains('updateInstalledHelpersInBackground'),
        isFalse,
      );
    });

    test('随包归档仍是唯一来源，且校验一步都不能省', () {
      final String src = readStripped(installer);
      expect(src.contains('_installBundledHelper'), isTrue);
      // 摘要校验与清单复检是随包路径仅剩的两道门，删任何一道都等于「文件在就装」。
      expect(src.contains('galgameHelperRequireVerifiedSha'), isTrue);
      expect(src.contains('galgameHelperMissingFiles'), isTrue);
    });

    test('Magpie 也只认随包归档，内置组件不恢复下载兜底', () {
      final String magpie =
          readStripped('lib/src/mining/magpie_installer.dart');
      for (final String needle in <String>[
        'HttpClient',
        'ResumableDownload',
        'https://',
        'updateInstalledMagpieInBackground',
      ]) {
        expect(magpie.contains(needle), isFalse, reason: needle);
      }
      expect(magpie.contains('_installBundledMagpie'), isTrue);
    });
  });
}
