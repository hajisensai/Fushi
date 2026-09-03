import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// PR#1172 复审前置 ②：`mineImmersion` 的 **bilibili 段**（通用可裁流路径）此前
/// 零覆盖——实测把 `requireAudio` 翻成 false（允许出无声卡）、把封面名换成
/// `netflix_shot.jpg`（把 B 站卡标成 Netflix 来源）在全量 4374 条测试下都全绿放过。
///
/// 这段代码没有可注入的缝（`mineImmersion` 内部 `new` 引擎、读真 `AppModel`、
/// 真 `_bilibiliClipMiner`），源码扫描是能落地的最强层，与
/// `remote_mining_image_mode_test.dart` 的源码守卫同形。
///
/// 钉死五条不变式：
/// 1. `requireAudio: true` —— 这条路有真实音轨（DASH 音频流），缺音频必须中止，
///    不出只有一张图的无声卡；
/// 2. 零/负长度窗在**进引擎之前**就 `remoteMineError` 返回 —— 引擎的
///    `requireAudio` 在 `hasRange == false` 时不会中止（见
///    `immersion_mining_engine.dart` 的 `viaProvidedBytes` 分支），少了这道前置门
///    就会静默降级成无声卡；
/// 3. 封面文件名前缀是 `web_shot.jpg` 而不是任何 netflix 前缀 —— 媒体库里要一眼
///    看得出这张图来自网页解码帧那条路，不是 Netflix 录制片段；
/// 4. `mediaSource: null` —— 封面走扩展给的原始解码帧，不再解析一路视频轨
///    （未登录只拿得到 480P 视频轨，且会带上弹幕/UI 层）；
/// 5. 本段**不得**出现动图格式 / 「动图 vs 静态帧」两个参数。它们在这条路上恒不
///    生效（`mediaSource` 为 null ⇒ 抽动图与抽起点帧的前置守卫都失败；服务端路径
///    无 `stillFallback` ⇒ 抽当前帧也失败；且 `providedCoverBytes` 非空时封面在
///    `if (coverPath == null)` 之前就已写好，整段阶梯不被求值）。
///    真正的危害不是死代码：`remote_mining_image_mode_test.dart` 用
///    「`mineImmersion` 开头 → `ImmersionCaptureResult cap =`」切出 YouTube 段，
///    bilibili 段正夹在中间，本段每多一份同名字面量，就把那条守卫稀释一次
///    ——删掉 YouTube 那份**真正生效**的透传，守卫照样绿（实测存活变异 D4）。
void main() {
  /// 剥掉注释再扫。本段注释里为解释这几条不变式必然写出同样的符号名，
  /// 让散文把守卫喂绿是假阳性；判据只应落在真实代码上。
  String codeOnly(String src) => maskComments(src);

  /// 切出 `mineImmersion` 里的 bilibili 段：`clipSourceKind == 'bilibili'` 起，
  /// 到 Netflix 捕获段的锚点 `ImmersionCaptureResult cap =` 止。
  String bilibiliSegment() {
    final String src = File('lib/src/models/app_model.dart').readAsStringSync();
    final int method = src.indexOf('Future<RemoteMineResult> mineImmersion(');
    expect(method, greaterThan(0), reason: 'mineImmersion 改名了？守卫锚点失效，请同步更新。');
    final int methodEnd = src.indexOf('void recordHistory(', method);
    expect(methodEnd, greaterThan(method),
        reason: 'mineImmersion 的收尾锚点失效，请同步更新守卫。');
    final String body = codeOnly(src.substring(method, methodEnd));

    final int start = body.indexOf("payload.clipSourceKind == 'bilibili'");
    expect(start, greaterThan(0),
        reason: 'bilibili 段的起始锚点失效（判据换写法了？），请同步更新守卫。');
    final int end = body.indexOf('ImmersionCaptureResult cap =', start);
    expect(end, greaterThan(start),
        reason: 'bilibili 段与 Netflix 段的分界锚点失效，请同步更新守卫。');
    final String segment = body.substring(start, end);

    // 自校验：切出来的必须真是那段实现，而不是参数表/注释残渣。少了这条，
    // 锚点漂移后所有「必须包含」的断言会一起变成恒假、「不得包含」的一起变成恒真。
    expect(segment, contains('_bilibiliClipMiner.buildRequest'),
        reason: '切出的 bilibili 段里没有 buildRequest 调用 —— 窗口切错了，'
            '下面的断言全部失去意义。');
    expect(segment, contains('ImmersionMiningEngine().mine('),
        reason: '切出的 bilibili 段里没有引擎调用 —— 窗口切错了。');
    // 扫描规模哨兵：整段实现在 1.5KB 量级；塌到几百字节说明只切到了签名或片段。
    expect(segment.length, greaterThan(1200),
        reason: 'bilibili 段只切出 ${segment.length} 字节，量级塌了 —— 锚点漂移。');
    return segment;
  }

  group('源码扫描守卫：mineImmersion 的 bilibili 段（PR#1172 前置 ②）', () {
    test('requireAudio: true —— 缺音频即失败，不出无声卡', () {
      expect(bilibiliSegment(), contains('requireAudio: true'),
          reason: 'bilibili 这条路有真实 DASH 音轨，缺音频必须中止；翻成 false 就是'
              '允许出「只有一张图」的无声卡（实测存活变异 D5）。');
    });

    test('零/负长度窗在进引擎之前就 remoteMineError 返回', () {
      final String segment = bilibiliSegment();
      final int guard =
          segment.indexOf('if (payload.clipEndMs! <= payload.clipStartMs!)');
      expect(guard, greaterThanOrEqualTo(0),
          reason: '零/负长度窗的前置门不见了：引擎的 requireAudio 在 hasRange==false 时'
              '不会中止，少了这道门就静默降级成无声卡。');
      final int engine = segment.indexOf('ImmersionMiningEngine().mine(');
      expect(guard, lessThan(engine), reason: '前置门必须在进引擎**之前**，否则等于没有。');
      final int err = segment.indexOf('remoteMineError(', guard);
      expect(err, greaterThan(guard));
      expect(err, lessThan(engine),
          reason: '零/负长度窗必须直接 remoteMineError 返回，不能继续往下走到引擎。');
      expect(segment, contains("'Anki.mineImmersion.bilibili'"),
          reason: '错误域名必须是 bilibili 自己的，别复用 youtube/netflix 的日志域。');
    });

    test('封面名前缀是 web_shot.jpg，不得冒充 netflix 来源', () {
      final String segment = bilibiliSegment();
      expect(segment, contains("'web_shot.jpg'"),
          reason: '媒体库里要一眼看得出这张图来自网页解码帧那条路。'
              '换成 netflix 前缀会把 B 站卡标成 Netflix 来源（实测存活变异 D7）。');
      expect(segment.contains('netflix'), isFalse,
          reason: 'bilibili 段不该出现任何 netflix 字样 —— 那是另一条捕获链路。');
    });

    test('mediaSource: null —— 封面走扩展的原始解码帧，不解析视频轨', () {
      expect(bilibiliSegment(), contains('mediaSource: null'),
          reason: '解析视频轨既慢又错（未登录只拿得到 480P、且带弹幕/UI 层）；'
              '封面由扩展的 providedCoverBytes 给。');
    });

    test('本段不得下发动图格式 / 静态帧模式两个恒不生效的参数', () {
      final String segment = bilibiliSegment();
      expect(segment.contains('imageMode:'), isFalse,
          reason: '这条路 mediaSource 为 null 且封面已由 providedCoverBytes 写好，'
              '引擎的 `if (coverPath == null)` 阶梯整段不被求值 —— 传了恒不生效，'
              '还会把 remote_mining_image_mode_test.dart 的 YouTube 段判据稀释成'
              '「两份里删一份照样绿」（存活变异 D4）。');
      expect(segment.contains('animatedFormat:'), isFalse,
          reason: '同上：抽动图的前置守卫要求 mediaSource 非空，这里恒为 null。'
              '多一份同名字面量会稀释 remote_mining_animated_format_test.dart 的判据。');
      // 反面：真正生效的那个必须留着 —— providedCoverBytes 短路会按它归一化编码
      // （immersion_mining_engine.dart 的 cardScreenshotEncodingFor）。
      expect(segment, contains('stillFormat: _appModel.videoMiningStillFormat'),
          reason: '静图格式在这条路上是**真生效**的（provided 字节按它重编码），'
              '不能连它一起删掉。');
    });
  });
}
