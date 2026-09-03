// 守卫：入库的 macOS 精简 ffmpeg/ffprobe 必须是 **universal**（x86_64 + arm64）。
//
// 背景（BUG-1668）：`flutter build macos --release` 产出的 app 本体是 universal，
// 而 `tool/ffmpeg-min/build-ffmpeg-min.sh` 历来只编**构建机自己的架构**，
// `.github/workflows/ffmpeg-min.yml` 的 macOS job 又跑在 Apple Silicon runner 上。
// 于是 2.1.1 发出去的包里：
//
//   fushi.app/Contents/MacOS/fushi    universal: x86_64 + arm64
//   fushi.app/Contents/MacOS/ffmpeg   arm64 only
//   fushi.app/Contents/MacOS/ffprobe  arm64 only
//
// 在 Intel Mac 上，app 本体照常启动、查词照常可用，但每次
// `Process.start('…/Contents/MacOS/ffmpeg')` 都被内核以 `Bad CPU type in executable`
// (EBADARCH) 拒掉 → 音频与首帧抽取全灭 → `requireAudio` → 整卡 abort。用户看到的
// 就是「生成完成：已处理 0 · 失败 N」。同链路一起哑掉的还有内封字幕抽取与字体、
// cue 动图、片段导出、音频容器元数据。
//
// 为什么既有门禁全部免疫：
//   - ffmpeg-min.yml 的 smoke-test 跑**刚编出来的**二进制，在 arm64 runner 上跑
//     arm64 产物，必然通过；
//   - release-desktop.yml 装配后的 `ffmpeg -version` 同样跑在 arm64 runner 上；
//   - ffmpeg_min_vendored_recipe_guard 只比对**内嵌 configure 串**的组件清单，
//     架构不在它的语义里；
//   - ffmpeg_min_vendored_self_contained_guard 只查有没有外部 dylib 依赖。
// 上面几道验的都是「能跑 / 编了什么 / 依赖谁」，没有一道验「能在**哪些架构**上跑」。
//
// 本守卫补上那条不变式，且不依赖 `lipo`/`file`（Windows、Linux CI 上同样有效）：
// Mach-O 的 FAT header 与 cputype 都是定长大端/小端整数，纯字节解析即可。
//
// 失败即意味着：入库二进制不是 universal —— 重跑 ffmpeg-min.yml（macOS job 现在会
// 按架构各构建一次再 lipo 合并），把 artifact 重新 vendor 到
// third_party/ffmpeg-min/macos/，并记得 `git update-index --chmod=+x`。

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

/// Mach-O / FAT 魔数。FAT 头恒为大端；瘦 Mach-O 头按自身字节序。
const int _kFatMagic = 0xCAFEBABE;
const int _kFatMagic64 = 0xCAFEBABF;
const int _kMachoMagic32 = 0xFEEDFACE;
const int _kMachoMagic64 = 0xFEEDFACF;

/// cputype 常量（mach/machine.h）。`| 0x01000000` 是 CPU_ARCH_ABI64。
const int _kCpuTypeX8664 = 0x01000007;
const int _kCpuTypeArm64 = 0x0100000C;

const Map<int, String> _cpuNames = <int, String>{
  _kCpuTypeX8664: 'x86_64',
  _kCpuTypeArm64: 'arm64',
  0x00000007: 'i386',
  0x0000000C: 'arm',
};

/// app 本体（`flutter build macos --release`）覆盖的架构。捆绑 helper 必须至少覆盖
/// 同样这些，否则在少掉的那种 Mac 上 helper 无法执行。
const List<int> _requiredCpuTypes = <int>[_kCpuTypeX8664, _kCpuTypeArm64];

Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/tool/ffmpeg-min/build-ffmpeg-min.sh').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 tool/ffmpeg-min/build-ffmpeg-min.sh 的仓库根'
      '（从 ${Directory.current.path} 向上）');
}

/// 解析 Mach-O，返回其包含的全部 cputype。瘦二进制返回 1 个，universal 返回 N 个。
List<int> machoCpuTypes(Uint8List bytes) {
  if (bytes.length < 8) fail('文件太短，不是 Mach-O（${bytes.length} 字节）');
  final ByteData bd = ByteData.sublistView(bytes);
  final int magicBe = bd.getUint32(0, Endian.big);

  if (magicBe == _kFatMagic || magicBe == _kFatMagic64) {
    final int count = bd.getUint32(4, Endian.big);
    // 每条 fat_arch 20 字节（fat_arch_64 是 32），cputype 在开头。
    final int stride = magicBe == _kFatMagic ? 20 : 32;
    final List<int> types = <int>[];
    for (int i = 0; i < count; i++) {
      final int off = 8 + i * stride;
      if (off + 4 > bytes.length) break;
      types.add(bd.getUint32(off, Endian.big));
    }
    return types;
  }

  // 瘦 Mach-O：魔数按自身字节序，cputype 紧随其后。
  final int magicLe = bd.getUint32(0, Endian.little);
  if (magicLe == _kMachoMagic32 || magicLe == _kMachoMagic64) {
    return <int>[bd.getUint32(4, Endian.little)];
  }
  if (magicBe == _kMachoMagic32 || magicBe == _kMachoMagic64) {
    return <int>[bd.getUint32(4, Endian.big)];
  }
  fail('不是 Mach-O：magic=0x${magicBe.toRadixString(16).padLeft(8, '0')}');
}

String _describe(List<int> types) =>
    types.map((int t) => _cpuNames[t] ?? '0x${t.toRadixString(16)}').join(', ');

void main() {
  final Directory root = _repoRoot();

  for (final String tool in <String>['ffmpeg', 'ffprobe']) {
    test('vendored macOS $tool 必须是 universal（x86_64 + arm64）', () {
      final File file = File('${root.path}/third_party/ffmpeg-min/macos/$tool');
      expect(file.existsSync(), isTrue,
          reason: '缺 ${file.path}——macOS 发布包靠它，见 release-desktop.yml 的装配步。');

      final List<int> types = machoCpuTypes(file.readAsBytesSync());
      for (final int want in _requiredCpuTypes) {
        expect(
          types,
          contains(want),
          reason: 'third_party/ffmpeg-min/macos/$tool 缺 ${_cpuNames[want]} 切片'
              '（实际: ${_describe(types)}）。app 本体是 universal(x86_64+arm64)，'
              'helper 少哪个架构，那种 Mac 上它就无法执行（Bad CPU type / EBADARCH）：'
              '制卡音频与封面、内封字幕抽取、片段导出会全线静默失效（BUG-1668）。'
              '修法：重跑 .github/workflows/ffmpeg-min.yml（macOS job 已改为双架构 '
              'lipo 合并），把 artifact 重新 vendor 到 third_party/ffmpeg-min/macos/，'
              '并 `git update-index --chmod=+x`。',
        );
      }
    });
  }

  // 纯解析器自测：守卫的判据本身必须能分清 universal 与瘦二进制，否则它可能只是
  // 恰好在真文件上返回了「对」的答案。构造最小 FAT / 瘦 Mach-O 头各验一次。
  test('machoCpuTypes 能分清 universal 与瘦二进制', () {
    final BytesBuilder fat = BytesBuilder();
    final ByteData fatHdr = ByteData(8)
      ..setUint32(0, _kFatMagic, Endian.big)
      ..setUint32(4, 2, Endian.big);
    fat.add(fatHdr.buffer.asUint8List());
    for (final int cpu in <int>[_kCpuTypeX8664, _kCpuTypeArm64]) {
      final ByteData arch = ByteData(20)..setUint32(0, cpu, Endian.big);
      fat.add(arch.buffer.asUint8List());
    }
    expect(machoCpuTypes(fat.toBytes()), <int>[_kCpuTypeX8664, _kCpuTypeArm64]);

    final ByteData thin = ByteData(8)
      ..setUint32(0, _kMachoMagic64, Endian.little)
      ..setUint32(4, _kCpuTypeArm64, Endian.little);
    expect(machoCpuTypes(thin.buffer.asUint8List()), <int>[_kCpuTypeArm64]);
  });
}
