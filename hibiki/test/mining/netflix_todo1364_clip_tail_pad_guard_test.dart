import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TODO-1364 / BUG-681 守卫：Netflix 逐句回放录制的**尾段音频完整性**。
///
/// 根因：回放录制循环在「字幕文本变成别句/清空」（= Netflix 字幕 display end）时立即
/// pause+endClip 停录，录制侧只保头部 200ms 提前量、从不补尾；而字幕 display end 常早于本句
/// 语音 end，入队窗的 200ms 尾部预留（q.endV = cueEnd+200）在回放路径也从未被消费 → 句子音频
/// 尾段被截（用户报「音频少了后面一段」）。
///
/// 修复：检测到句末后不立即停录，先记录目标停录视频时间 endAtSec = 句末 + kNfClipTailPadSec
/// （尾部余量，与 200ms 头部提前量对称、略放宽），再录到 currentTime >= endAtSec 才停。
///
/// 源码扫描守卫（不依赖真机/真浏览器），两份扩展镜像（随 app 打包的 assets/ 与真源 tools/）都守。
/// flutter test cwd 是 hibiki 包根。
void main() {
  final List<File> contents = <File>[
    File('assets/browser_extension/content.js'),
    File('../tools/browser-extension/content.js'),
  ];

  group('TODO-1364 Netflix 录制尾段音频完整性守卫', () {
    for (final File content in contents) {
      group('content.js ${content.path}', () {
        test('存在尾部余量常量 kNfClipTailPadSec（> 0）', () {
          final String src = content.readAsStringSync();
          final RegExp re = RegExp(r'const kNfClipTailPadSec = ([0-9.]+);');
          final Match? m = re.firstMatch(src);
          expect(m, isNotNull,
              reason: '${content.path} 缺尾部余量常量 kNfClipTailPadSec');
          final double pad = double.parse(m!.group(1)!);
          expect(pad, greaterThan(0),
              reason: '${content.path} 尾部余量必须 > 0（否则又是句末即停、截尾）');
        });

        test('句末后记录 endAtSec 再录尾部余量，而非立即 break', () {
          final String src = content.readAsStringSync();
          // 句末检测到后设 endAtSec = 当前视频时间 + 尾部余量。
          expect(src.contains('endAtSec = v.currentTime + kNfClipTailPadSec'),
              isTrue,
              reason: '${content.path} 句末未记录 endAtSec（应 = currentTime + 尾部余量）');
          // 真正停录门是「录到 endAtSec」，不是句末立即 break。
          expect(src.contains('if (v.currentTime >= endAtSec) break;'), isTrue,
              reason: '${content.path} 缺「录满尾部余量才停」的停录门');
          // 旧的截尾写法（句末立即 break）不得残留。
          expect(src.contains('if (nowText !== ref) break; // 字幕变成别句 = 本句结束'),
              isFalse,
              reason: '${content.path} 仍残留「句末立即 break」的截尾停录（回归 BUG-681）');
        });
      });
    }

    test('两份镜像逐字节一致（content.js）', () {
      expect(contents[0].readAsBytesSync(), contents[1].readAsBytesSync(),
          reason: 'content.js 两份镜像不一致');
    });
  });
}
