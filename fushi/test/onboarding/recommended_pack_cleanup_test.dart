import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/onboarding/recommended_pack.dart';

import '../helpers/source_guard.dart';

/// BUG-2109：推荐包（9.5 GB zip）导入后的收尾删除。
///
/// 判据（包目录里的 `imported.flag`）从来没错，错的是**挂在哪儿**：收尾一度只挂
/// 在新手引导页的 initState 上，而推荐包本身是一份含 settings 类目的备份，导入时
/// `preferences` 表被整层替换、`onboarding_completed` 变成 true（该键缺省值也是
/// true），于是导入后的那次重启首页不再自动弹引导页——清理入口结构上永远等不到
/// 执行。用户实测：存储页词典类目 11.3 GB，展开的词典明细只有 583 MB。
void main() {
  late Directory tempRoot;
  late Directory packDir;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('recommended_pack_cleanup');
    packDir = Directory(p.join(tempRoot.path, 'recommended_pack'));
  });

  tearDown(() {
    try {
      tempRoot.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 偶发句柄延迟释放：留给系统临时目录清理。
    }
  });

  void writePack(int bytes) {
    final File f = File(p.join(packDir.path, 'fushi_recommended_pack.zip'));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(List<int>.filled(bytes, 0x61));
  }

  group('cleanupIfImported', () {
    test('导入过（flag 在）：整个包目录连同 zip 一起删掉', () async {
      writePack(4096);
      await RecommendedPackDownloader.markImportStarted(packDir);
      expect(packDir.existsSync(), isTrue);

      await RecommendedPackDownloader.cleanupIfImported(packDir);

      expect(packDir.existsSync(), isFalse);
    });

    test('只下载过、没导入（flag 不在）：包原样保留，续传不被作废', () async {
      writePack(4096);

      await RecommendedPackDownloader.cleanupIfImported(packDir);

      expect(
          File(p.join(packDir.path, 'fushi_recommended_pack.zip')).existsSync(),
          isTrue);
    });

    test('包目录压根不存在：不抛（启动路径上跑，抛了就是启动失败）', () async {
      await RecommendedPackDownloader.cleanupIfImported(packDir);
      expect(packDir.existsSync(), isFalse);
    });
  });

  group('BUG-2109 守卫：收尾必须挂在启动必经路径上', () {
    final File appModel = File('lib/src/models/app_model.dart');
    final File controller =
        File('lib/src/onboarding/recommended_pack_download_controller.dart');
    final File wizard =
        File('lib/src/pages/implementations/onboarding_wizard_page.dart');

    test('AppModel 初始化持有包目录收尾调用', () {
      expect(appModel.existsSync(), isTrue, reason: '守卫锚点文件不在了，先修锚点再改断言');
      // 布尔断言而非 contains matcher：后者失败时会把整份 app_model.dart
      // （5000+ 行）打进失败信息，淹没掉 reason。
      //
      // 收尾**不再**由 AppModel 直接调 cleanupIfImported：它现在走 controller 的
      // prepareDiskState()（删残包 + 搬旧命名半截文件 + 对齐下载阶段三件一起做，
      // 且不能挂进 `_guardInitIo` 那批 12s 硬超时的启动关键 IO —— 删 9.5 GB 超时
      // 就把启动干成错误屏）。所以判据是**两段链**，不是单点字面量：
      //   ① AppModel 初始化里调了 prepareDiskState()
      //   ② prepareDiskState 的方法体里确实做了 cleanupIfImported
      // 少断言任一段，「调用还在但里面已经不删了」这种退化就漏过去了。
      expect(
        containsCodeLine(
          appModel.readAsStringSync(),
          'recommendedPackDownloadController',
        ),
        isTrue,
        reason: '推荐包收尾删除必须挂在启动必经路径（AppModel 初始化）上；'
            '任何「只在某个页面打开时才清理」的挂法都会被 onboarding_completed '
            '在导入时被整层替换成 true 而永不执行',
      );
      expect(
        containsCodeLine(appModel.readAsStringSync(), '.prepareDiskState()'),
        isTrue,
        reason: '包目录收尾（含 cleanupIfImported）由 prepareDiskState 承担，'
            'AppModel 初始化必须调它',
      );
    });

    test('prepareDiskState 里确实做了收尾删除（链条第二段）', () {
      expect(controller.existsSync(), isTrue, reason: '守卫锚点文件不在了，先修锚点再改断言');
      final String body = methodBody(
        controller.readAsStringSync(),
        'Future<void> prepareDiskState() async {',
      );
      expect(
        containsCodeLine(body, 'RecommendedPackDownloader.cleanupIfImported('),
        isTrue,
        reason: 'prepareDiskState 是启动路径上唯一的收尾入口；它不删，'
            '9.5 GB 就永久留在盘上',
      );
    });

    test('新手引导页不再是清理入口（导入后它根本不会再打开）', () {
      expect(wizard.existsSync(), isTrue, reason: '守卫锚点文件不在了，先修锚点再改断言');
      // 注释里提到函数名是允许的（本次修复就留了指向说明），红线是**调用**。
      // 注释掩码统一走 source_guard 的 containsCodeLine：
      // 手写的 startsWith 剥不掉块注释，也剥不掉行尾注释。
      expect(
        containsCodeLine(wizard.readAsStringSync(), 'cleanupIfImported('),
        isFalse,
        reason: '引导页在导入后的那次启动不会再打开，清理挂这儿等于永不执行',
      );
    });
  });
}
