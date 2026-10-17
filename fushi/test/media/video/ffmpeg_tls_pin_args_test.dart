import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// BUG-891 守卫：远端自签 Fushi 主机制卡时，抽取器必须把该 host 的 TOFU 钉扎证书指纹
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

  group('统一 FFmpeg 的 tls pin 补丁存在且完整（BUG-891）', () {
    // 相对仓库根：fushi/ 是 CWD，补丁在上一级 tool/ffmpeg-unified/patches/ffmpeg/。
    // 全平台（桌面 ffmpeg 程序、移动端 FFmpegKitNext、播放器 libmpv）共用这一份 FFmpeg。
    File patchFile() {
      final Directory dir = Directory('../tool/ffmpeg-unified/patches/ffmpeg');
      final List<File> hits = dir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.contains('tls_pin_sha256'))
          .toList();
      expect(hits, hasLength(1),
          reason: '统一 FFmpeg 必须恰有一个 tls_pin_sha256 补丁，实测 $hits');
      return hits.single;
    }

    test('补丁文件存在', () {
      expect(patchFile().existsSync(), isTrue,
          reason: '统一 FFmpeg 需要此补丁加 tls_pin_sha256；不得删除');
    });

    test('补丁定义 AVOption + 共享助手 + 覆盖五后端 + FFmpeg 8+ 默认校验被 pin 接管', () {
      final String src = patchFile().readAsStringSync();
      expect(src.contains('tls_pin_sha256'), isTrue,
          reason: '必须定义 -tls_pin_sha256 AVOption');
      expect(src.contains('ff_tls_check_cert_pin'), isTrue, reason: '共享指纹比对助手');
      // openssl=Android/iOS（FFmpegKitNext --enable-lib-openssl），gnutls=Windows
      // （MSYS2 同款配置）/ Linux，securetransport=macOS，schannel / mbedtls 也补齐。
      expect(src.contains('libavformat/tls_openssl.c'), isTrue);
      expect(src.contains('libavformat/tls_gnutls.c'), isTrue);
      expect(src.contains('libavformat/tls_securetransport.c'), isTrue);
      expect(src.contains('libavformat/tls_schannel.c'), isTrue);
      expect(src.contains('libavformat/tls_mbedtls.c'), isTrue);
      // FFmpeg >= 8 默认 tls_verify=1：不在共享 open 路径里把它让给 pin，自签主机
      // 会在握手阶段就被 CA 校验拒掉，根本走不到指纹比对。
      expect(
          RegExp(r'if \(ff_tls_has_cert_pin\(c\)\)\r?\n\+\s+c->verify = 0;')
              .hasMatch(src),
          isTrue,
          reason: '设了 pin 必须在 ff_tls_open_underlying 里关掉 CA/主机名校验');
      // Android 的 OpenSSL 没有可用 CA 包，默认校验开启后公网 HTTPS 全挂。
      expect(src.contains('openssl_load_android_system_cas'), isTrue,
          reason: 'Android 必须显式加载系统 CA 目录');
    });
  });
}
