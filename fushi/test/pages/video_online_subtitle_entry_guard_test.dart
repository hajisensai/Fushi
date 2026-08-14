import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';
import 'video_fushi_page_source_corpus.dart';

/// 播放页「在线获取字幕」入口的静态守卫。
///
/// 背景：OpenSubtitles 早就有完整 provider 实现（`open_subtitles_client.dart`）和设置
/// 表单，但只挂在发现页 / 下载流水线一侧；播放页的字幕菜单是硬编码直连 Jimaku 的，用户
/// 在播放器里根本看不到它。这里锁住补上的那条入口——播放器要 media_kit 真跑起来才能做
/// widget 测试，故按本仓既有范式落静态守卫。
///
/// 全部是「要求型」断言，判据一律剥注释（[containsCodeLine] / [containsIdentifierCall]）：
/// 裸 contains 下「把实现删掉、把字面量留在注释里」是能骗绿的。
void main() {
  final String src = readVideoFushiSource();

  test('字幕菜单里有在线获取入口，且按已配置的源门控', () {
    expect(containsCodeLine(src, 't.video_subtitle_online_fetch'), isTrue,
        reason: '播放页字幕菜单必须有「在线获取字幕」入口，否则 OpenSubtitles 等源在'
            '播放器里永远不可达；注释里写着这句不算实现');
    expect(
      containsCodeLine(
          src, 'appModel.videoSubtitleRegistry?.providers.isNotEmpty'),
      isTrue,
      reason: '入口必须按「真有配置好的在线源」门控，一个源都没配时不该显示',
    );
  });

  test('入口走 registry 而不是再硬编码一个 provider', () {
    final String body =
        methodBody(src, 'Future<void> _openOnlineSubtitleDialog(');
    expect(containsIdentifierCall(body, 'OnlineSubtitleSearchDialog'), isTrue,
        reason: '在线入口必须打开 provider 无关的对话框');
    expect(containsCodeLine(body, 'registry: registry'), isTrue,
        reason: '对话框必须吃 VideoSubtitleRegistry：加新字幕源不该再改播放页');
    expect(containsCodeLine(body, 'videoPath: videoPath'), isTrue,
        reason: '必须把本地视频路径传下去——OpenSubtitles 按文件哈希匹配才能命中该压制'
            '版本的字幕，只按标题搜准度差一个数量级');
  });

  test('Jimaku 与在线两条下载路径共用同一条落地逻辑', () {
    final String jimaku = methodBody(src, 'Future<void> _openJimakuDialog(');
    final String online =
        methodBody(src, 'Future<void> _openOnlineSubtitleDialog(');
    expect(containsIdentifierCall(jimaku, '_applyDownloadedSubtitle'), isTrue,
        reason: 'Jimaku 下载完必须走共用落地路径');
    expect(containsIdentifierCall(online, '_applyDownloadedSubtitle'), isTrue,
        reason: '在线源下载完必须走同一条落地路径：本地/远端分流、并入字幕轨列表、'
            '成功提示都在那里，各写一份迟早漂开');
  });

  test('共用落地路径仍保留远端分流与轨列表登记', () {
    final String body =
        methodBody(src, 'Future<void> _applyDownloadedSubtitle(');
    expect(containsIdentifierCall(body, '_applyRemoteSubtitle'), isTrue,
        reason: '远端视频没有本地 DB 行，必须走只在内存应用的远端链路');
    expect(
        containsIdentifierCall(body, '_registerImportedSubtitleSource'), isTrue,
        reason: 'BUG-1329：下载的新档要当场并入字幕轨列表，且不按 applied 门控');
  });
}
