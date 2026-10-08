#!/usr/bin/env python3
"""静态校验 ffmpeg-kit 移动端产物（AAR / xcframework 目录）是否符合 Hibiki 配方。

与 fushi/test/tools/ffmpeg_kit_mobile_recipe_guard_test.dart 同一套判据（latin1 字节扫描，
不执行二进制），供 CI 在上传 artifact 之前把关；vendor 回仓库后仍以 Dart 守卫为准。

用法:
  verify_mobile_outputs.py android <path/to/ffmpeg-kit.aar>
  verify_mobile_outputs.py ios <path/to/dir containing *.xcframework>
退出码 0 = 全部通过；1 = 至少一条失败（逐条打印）。
"""
import os
import sys
import zipfile
from typing import Callable, Dict, List

REQUIRED_FLAGS: List[str] = [
    '--enable-gpl',
    '--enable-libx264',
    '--enable-openssl',
    '--enable-libvpx',
    '--enable-libopus',
    '--enable-libdav1d',
]

# libavcodec 里必须同时出现 ffmpeg 封装名与库自身的串：
# - 'libx264' / 'x264 - core'：沿用现守卫。
# - 'libvpx-vp9'：ffmpeg 的 AVCodec 名（libavcodec/libvpxenc.c:1990，解码器同名）。
#   注意 ffmpeg configure 对 libvpx 每个编解码器用的是 check_pkg_config（软失败，
#   configure:6702-6718），所以 --enable-libvpx 在 configure 串里 ≠ VP9 编码器真在。
# - 'WebM Project VP9 Encoder'：libvpx 编码器接口名（vp9/vp9_cx_iface.c:2127），
#   只有真链进 VP9 编码器才会出现——这是「编码器在」的判据。
# - 'libopus'：ffmpeg 的 AVCodec 名（libavcodec/libopusenc.c:587）。
# - 'request not implemented'：libopus 的 opus_strerror 表（celt/celt.c:293），
#   ffmpeg 的 libopusenc.c 多处调用 opus_strerror；FFmpeg n6.0 源码里无此串（已 grep 核）。
# - 'libdav1d'：ffmpeg 的 AV1 软件解码器 AVCodec 名（libavcodec/libdav1d.c）。BUG-2947：
#   原生 'av1' 解码器只是 hwaccel 壳，移动端没有任何 hwaccel，缺它 AV1 源一帧都解不出。
# - 'Malformed ITU-T T.35 metadata message format'：dav1d 自身的 dav1d_log 串
#   （dav1d 1.2.1 src/obu.c，logging 默认开）；旧产物四个切片都扫不到（2026-10-05 实测），
#   证明它只会因真链进 dav1d 而出现。
CODEC_MARKERS: List[str] = [
    'libx264',
    'x264 - core',
    'libvpx-vp9',
    'WebM Project VP9 Encoder',
    'libopus',
    'request not implemented',
    'libdav1d',
    'Malformed ITU-T T.35 metadata message format',
]

ZLIB_SYMBOLS: List[str] = ['deflateInit2_', 'deflateEnd', 'inflateInit_']

EXPECTED_ANDROID_ABIS = {'arm64-v8a', 'armeabi-v7a'}
EXPECTED_IOS_SLICES = {'ios-arm64_arm64e', 'ios-arm64_x86_64-simulator'}
EXPECTED_FRAMEWORKS = {
    'ffmpegkit', 'libavcodec', 'libavdevice', 'libavfilter',
    'libavformat', 'libavutil', 'libswresample', 'libswscale',
}

failures: List[str] = []


def check(ok: bool, message: str) -> None:
    print(('  ok   ' if ok else '  FAIL ') + message)
    if not ok:
        failures.append(message)


def text(data: bytes) -> str:
    return data.decode('latin1')


def check_slice(label: str, util: str, codec: str, fmt: str) -> None:
    check('--target-os=' in util, f'{label}: libavutil 内嵌 configure 串存在')
    for flag in REQUIRED_FLAGS:
        check(flag in util, f'{label}: configure 含 {flag}')
    check('--disable-zlib' in util and '--enable-zlib' not in util,
          f'{label}: 仍是 --disable-zlib（BUG-2366 假设不变）')
    check('--enable-libx265' not in util, f'{label}: 负向对照 --enable-libx265 不存在')
    for marker in CODEC_MARKERS:
        check(marker in codec, f'{label}: libavcodec 含 {marker!r}')
    for sym in ZLIB_SYMBOLS:
        check(sym not in codec, f'{label}: libavcodec 不含 zlib 符号 {sym}')
    check('tls_pin_sha256' in fmt, f'{label}: libavformat 含 cert-pin 选项 tls_pin_sha256')


def verify_android(aar_path: str) -> None:
    z = zipfile.ZipFile(aar_path)
    names = set(z.namelist())
    abis = {n.split('/')[1] for n in names if n.startswith('jni/') and n.count('/') >= 2 and n.split('/')[1]}
    check(abis == EXPECTED_ANDROID_ABIS, f'ABI 集合 == {sorted(EXPECTED_ANDROID_ABIS)}（实际 {sorted(abis)}）')
    for abi in sorted(EXPECTED_ANDROID_ABIS):
        def so(lib: str) -> str:
            name = f'jni/{abi}/{lib}'
            if name not in names:
                check(False, f'AAR 缺 {name}')
                return ''
            return text(z.read(name))
        util = so('libavutil.so')
        check_slice(f'android {abi}', util, so('libavcodec.so'), so('libavformat.so'))
        check('--disable-mediacodec' in util, f'android {abi}: 仍 --disable-mediacodec')
    lic = 'res/raw/license.txt'
    check(lic in names and 'GNU GENERAL PUBLIC LICENSE' in text(z.read(lic)), 'license.txt 为 GPLv3')
    for extra in ['license_x264.txt', 'license_openssl.txt', 'license_libvpx.txt', 'license_opus.txt',
                  'license_dav1d.txt', 'source.txt']:
        check(f'res/raw/{extra}' in names, f'AAR 含 res/raw/{extra}')


def verify_ios(root: str) -> None:
    frameworks = {d[:-len('.xcframework')] for d in os.listdir(root) if d.endswith('.xcframework')}
    check(frameworks == EXPECTED_FRAMEWORKS, f'xcframework 集合 == 入库 8 个（实际 {sorted(frameworks)}）')
    for fw in sorted(frameworks):
        slices = {d for d in os.listdir(os.path.join(root, f'{fw}.xcframework'))
                  if os.path.isdir(os.path.join(root, f'{fw}.xcframework', d))}
        check(slices == EXPECTED_IOS_SLICES, f'{fw}: 切片 == {sorted(EXPECTED_IOS_SLICES)}（实际 {sorted(slices)}）')

    def binary(lib: str, sl: str) -> str:
        p = os.path.join(root, f'{lib}.xcframework', sl, f'{lib}.framework', lib)
        if not os.path.isfile(p):
            check(False, f'缺 {p}')
            return ''
        with open(p, 'rb') as f:
            return text(f.read())

    for sl in sorted(EXPECTED_IOS_SLICES):
        check_slice(f'ios {sl}', binary('libavutil', sl), binary('libavcodec', sl), binary('libavformat', sl))


def main(argv: List[str]) -> int:
    modes: Dict[str, Callable[[str], None]] = {'android': verify_android, 'ios': verify_ios}
    if len(argv) != 3 or argv[1] not in modes:
        print(__doc__)
        return 2
    print(f'== verify {argv[1]}: {argv[2]}')
    modes[argv[1]](argv[2])
    if failures:
        print(f'\n{len(failures)} check(s) FAILED')
        return 1
    print('\nall checks passed')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
