import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';

/// BUG-891 守卫：远端自签 Hibiki 主机制卡时，抽取器必须把该 host 的 TOFU 钉扎证书指纹
/// 下发给 ffmpeg 的 `-tls_pin_sha256`——否则移动端自编 ffmpeg-kit（无 https/min 变体，
/// 或加了 gnutls 但默认接受任意证书）要么 `Protocol not found`、要么无钉扎放行。
///
/// 这些是纯函数断言（不跑 ffmpeg）：锁死「pin 非空 → 出现在 `-i` 前」「pin 空/本地输入 →
/// 不出现」这两条不变量；配合 ffmpeg 源码补丁存在性守卫，覆盖到「重编时补丁不丢」。
/// 真正的握手/钉扎生效需真机（自编 ffmpeg-kit 加载）验证，见 BUG-891。
void main() {
  const String pin = 'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:'
      'aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99';
  const String remote =
      'https://192.168.31.160:38765/api/library/videos/x/stream?token=t';
  const String local = '/data/user/0/app/files/video.mp4';

  group('buildFfmpegRemoteInputArgs 的 tls pin 透传（BUG-891）', () {
    test('远端 https + pin → -tls_pin_sha256 <pin>，且在 -user_agent 之前', () {
      final List<String> args =
          buildFfmpegRemoteInputArgs(remote, tlsPinSha256: pin);
      final int p = args.indexOf('-tls_pin_sha256');
      expect(p, greaterThanOrEqualTo(0), reason: '远端自签流必须下发 -tls_pin_sha256');
      expect(args[p + 1], pin, reason: '指纹原样透传（ffmpeg 侧归一化冒号/大小写）');
      final int ua = args.indexOf('-user_agent');
      expect(p, lessThan(ua), reason: 'TLS 输入选项必须在其它输入选项/`-i` 之前');
    });

    test('远端 https 无 pin → 不含 -tls_pin_sha256（公网源不钉扎，行为不变）', () {
      final List<String> args = buildFfmpegRemoteInputArgs(remote);
      expect(args.contains('-tls_pin_sha256'), isFalse);
      // 既有远端韧性开关保持不变。
      expect(args.contains('-user_agent'), isTrue);
      expect(args.contains('-reconnect'), isTrue);
    });

    test('空/空白 pin → 不含 -tls_pin_sha256', () {
      expect(
          buildFfmpegRemoteInputArgs(remote, tlsPinSha256: '')
              .contains('-tls_pin_sha256'),
          isFalse);
      expect(
          buildFfmpegRemoteInputArgs(remote, tlsPinSha256: '   ')
              .contains('-tls_pin_sha256'),
          isFalse);
    });

    test('本地路径输入 → 空参数（pin 被忽略，本地无 TLS）', () {
      expect(buildFfmpegRemoteInputArgs(local, tlsPinSha256: pin), isEmpty);
    });
  });

  group('抽取器 arg builder 把 pin 传到 -i 前（BUG-891）', () {
    void expectPinBeforeInput(List<String> args) {
      final int p = args.indexOf('-tls_pin_sha256');
      final int i = args.indexOf('-i');
      expect(p, greaterThanOrEqualTo(0));
      expect(i, greaterThanOrEqualTo(0));
      expect(p, lessThan(i), reason: 'tls pin 是输入选项，必须在 -i 之前');
      expect(args[p + 1], pin);
    }

    test('句子音频 buildFfmpegClipArgs', () {
      expectPinBeforeInput(buildFfmpegClipArgs(
        inputPath: remote,
        startMs: 1000,
        endMs: 3000,
        outputPath: '/tmp/a.aac',
        tlsPinSha256: pin,
      ));
    });

    test('单帧 buildFfmpegFrameArgs', () {
      expectPinBeforeInput(buildFfmpegFrameArgs(
        inputPath: remote,
        outputPath: '/tmp/f.jpg',
        atSeconds: 1.0,
        tlsPinSha256: pin,
      ));
    });

    test('cue 动图 buildFfmpegClipGifArgs', () {
      expectPinBeforeInput(buildFfmpegClipGifArgs(
        inputPath: remote,
        startMs: 1000,
        endMs: 3000,
        outputPath: '/tmp/c.gif',
        tlsPinSha256: pin,
      ));
    });

    test('无 pin 时三个 builder 输出与旧行为一致（不含 -tls_pin_sha256）', () {
      final List<List<String>> all = <List<String>>[
        buildFfmpegClipArgs(
            inputPath: remote,
            startMs: 0,
            endMs: 1000,
            outputPath: '/tmp/a.aac'),
        buildFfmpegFrameArgs(inputPath: remote, outputPath: '/tmp/f.jpg'),
        buildFfmpegClipGifArgs(
            inputPath: remote,
            startMs: 0,
            endMs: 1000,
            outputPath: '/tmp/c.gif'),
      ];
      for (final List<String> args in all) {
        expect(args.contains('-tls_pin_sha256'), isFalse);
      }
    });
  });

  group('ffmpeg 源码 tls pin 补丁存在且完整（BUG-891）', () {
    // 相对仓库根：fushi/ 是 CWD，补丁在上一级 third_party/。
    final File patch = File(
        '../third_party/ffmpeg_kit_flutter/patches/ffmpeg-tls-pin-sha256.patch');

    test('补丁文件存在', () {
      expect(patch.existsSync(), isTrue,
          reason: '重编 ffmpeg-kit 需要此补丁加 tls_pin_sha256；不得删除');
    });

    test('补丁定义 AVOption + 共享助手 + 覆盖四后端', () {
      final String src = patch.readAsStringSync();
      expect(src.contains('tls_pin_sha256'), isTrue,
          reason: '必须定义 -tls_pin_sha256 AVOption');
      expect(src.contains('ff_tls_check_cert_pin'), isTrue, reason: '共享指纹比对助手');
      // openssl=移动端(Android/iOS 自编 --enable-openssl)，gnutls=Linux 桌面，
      // securetransport=macOS，schannel=Windows 各有钉扎分支。
      expect(src.contains('libavformat/tls_openssl.c'), isTrue);
      expect(src.contains('libavformat/tls_gnutls.c'), isTrue);
      expect(src.contains('libavformat/tls_securetransport.c'), isTrue);
      expect(src.contains('libavformat/tls_schannel.c'), isTrue);
    });
  });
}
