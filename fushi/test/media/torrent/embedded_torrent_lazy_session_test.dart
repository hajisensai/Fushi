// BUG-1053：Hibiki 桌面版一启动就无条件创建 libtorrent session（绑 6881 TCP+UDP、
// DHT 默认开），哪怕用户一个下载任务都没有、也没配过 qBittorrent。持续的全球 DHT
// 小包把家用路由器 NAT/conntrack 表撑爆 → 整机网络周期性高延迟，关掉 Hibiki 即恢复。
//
// 实测取证（2026-07-24，用户机上运行中的 hibiki.exe）：
//   TCP Listen  0.0.0.0:6881 / 192.168.1.30:6881 / 127.0.0.1:6881
//   UDP Listen  同上（UDP 6881 = DHT）
//
// 修复把「能力探测」与「真实会话」拆开：探测只加载 DLL 不碰网络，session 留到第一次
// 真的要用下载后端时才懒建。本测试用源码守卫锁死这条不变量——真会话的行为层验证需要
// 本地做种夹具 + DLL（见 embedded_torrent_host_test.dart，CI 上多半 skip），守不住
// 「启动时不许开 session」这件事，故必须在源码层守。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

String _read(String relPath) => File(relPath).readAsStringSync();

/// 取以 `=>` 表达式体收尾的成员声明（如 `bool get isEmbeddedTorrentReady => …;`）。
///
/// 右边界是终止该表达式的**顶层分号**（括号/方括号/花括号深度归零处），与行数无关。
/// 不能用 [methodBody]：表达式体成员根本没有花括号体，配对扫描会一路配到后面某个
/// 真方法上去，窗口静默指向错误对象。
String _expressionBodyMember(String src, String signature) {
  final String structural = maskCommentsAndStrings(src);
  final int start = structural.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到成员声明：$signature');
  int depth = 0;
  for (int i = start; i < structural.length; i++) {
    final String c = structural[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (c == ';' && depth == 0) return src.substring(start, i + 1);
  }
  fail('表达式体成员没有收尾分号：$signature');
}

void main() {
  group('BUG-1053 内置 torrent 会话必须懒建（空闲用户不得跑 DHT）', () {
    late String appModel;
    late String host;

    setUpAll(() {
      appModel = _read('lib/src/models/app_model.dart');
      host = _read('lib/src/media/torrent/embedded_torrent_host.dart');
    });

    test('startAnimeDownloadService 不得创建 libtorrent session', () {
      // 窗口=方法体（花括号配对）。原 `_memberBody` 是「找下一个 `\n  }`，找不到就退
      // 定长 2500」：`\n  }` 这半赌的是方法体里不出现同样 2 空格缩进的闭合行，退定长
      // 那半更是假绿温床——本方法体实测 3605 字符，一旦 `\n  }` 匹配失败，下面这条
      // isFalse 断言就只扫前 2500 字符、后面 1100 字符里出现 open() 也照样绿。
      final String body =
          methodBody(appModel, 'Future<void> startAnimeDownloadService()');
      expect(body.contains('EmbeddedTorrentHost.open('), isFalse,
          reason: 'BUG-1053 回归：启动即建 session = 空闲也在跑 DHT/占 6881');
      // 只记保存路径（TODO-1961 起是活动根 + 历史根集合），真会话交给懒建入口。
      expect(body.contains('_embeddedTorrentSaveRoots'), isTrue);
    });

    test('后端工厂在真要用时才懒建（且仅内置后端路径）', () {
      final String body =
          methodBody(appModel, 'TorrentBackend _torrentBackendFor(');
      expect(body.contains('_ensureEmbeddedTorrentHost()'), isTrue,
          reason: 'BUG-1053：内置后端路径必须走懒建入口');
      expect(
          appModel
              .contains('EmbeddedTorrentHost? _ensureEmbeddedTorrentHost()'),
          isTrue);
    });

    test('就绪判定走能力探测，不再等价于「已开 session」', () {
      // 窗口=该表达式体成员的完整声明（顶层分号收口），不是 `+400` 定长窗口：
      // getter 一旦多包一层三元或换行，probeAvailable 就漂出窗口、断言凭空变假。
      final String body =
          _expressionBodyMember(appModel, 'bool get isEmbeddedTorrentReady');
      expect(body.contains('EmbeddedTorrentHost.probeAvailable()'), isTrue,
          reason: 'BUG-1053：就绪判定若仍要求 session 存在，启动就又得开 session');
    });

    test('probeAvailable 只加载引擎，绝不创建 session', () {
      // 窗口=方法体（花括号配对）。原写法是「找下一个 `\n  }`，找不到就退定长 1200」：
      // 前半赌方法体里不出现同缩进闭合行，后半的静默兜底更是假绿温床——探测体一长，
      // 下面两条 isFalse 就只扫前 1200 字符，后面真写了 session.open( 也照样绿。
      final String body = methodBody(host, 'static bool probeAvailable(');
      expect(body.contains('EmbeddedTorrentEngine.open('), isTrue);
      expect(body.contains('EmbeddedTorrentSession.open('), isFalse,
          reason: 'BUG-1053：探测里建 session 就等于没修');
      // 探测不该需要保存路径（不落盘、不下载）。
      expect(body.contains('baseSavePath'), isFalse);
    });

    test('只有 open() 建 session，且它只被懒建入口调用', () {
      // 全仓（lib 下）对 EmbeddedTorrentHost.open 的调用点应当只剩懒建入口一处。
      final Iterable<Match> hits =
          RegExp(r'EmbeddedTorrentHost\.open\(').allMatches(appModel);
      expect(hits.length, 1,
          reason:
              'BUG-1053：AppModel 里 open() 只应出现在 _ensureEmbeddedTorrentHost');
      final String ensure = methodBody(
          appModel, 'EmbeddedTorrentHost? _ensureEmbeddedTorrentHost()');
      expect(ensure.contains('EmbeddedTorrentHost.open('), isTrue);
    });

    test('懒建 host 时 session 初始 DHT 必须显式关闭', () {
      final String ensure = methodBody(
          appModel, 'EmbeddedTorrentHost? _ensureEmbeddedTorrentHost()');
      final String structural = maskCommentsAndStrings(ensure);
      expect(
        RegExp(
          r'EmbeddedTorrentHost\.open\([\s\S]*?enableDht\s*:\s*false',
        ).hasMatch(structural),
        isTrue,
        reason: 'BUG-1647：resume 恢复阶段若先开 DHT，门控接管前仍会产生空闲流量',
      );
    });
  });
}
