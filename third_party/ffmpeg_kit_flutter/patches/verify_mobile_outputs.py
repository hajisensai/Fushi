#!/usr/bin/env python3
"""静态校验 ffmpeg-kit 移动端产物（AAR / xcframework 目录）是否符合 Fushi 配方。

与 fushi/test/tools/ffmpeg_kit_mobile_recipe_guard_test.dart 同一套判据（latin1 字节扫描，
不执行二进制），供 CI 在上传 artifact 之前把关；vendor 回仓库后仍以 Dart 守卫为准。

用法:
  verify_mobile_outputs.py android <path/to/ffmpeg-kit.aar>
  verify_mobile_outputs.py ios <path/to/dir containing *.xcframework>
退出码 0 = 全部通过；1 = 至少一条失败（逐条打印）。
"""
import os
import re
import struct
import sys
import zipfile
from typing import Callable, Dict, List, Set, Tuple

REQUIRED_FLAGS: List[str] = [
    '--enable-gpl',
    '--enable-libx264',
    '--enable-openssl',
    '--enable-libvpx',
    '--enable-libopus',
    '--enable-libdav1d',
    '--enable-libxml2',
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

# BUG-3503：在线视频源给 MPEG-DASH 清单（manifest.mpd）时，制卡的句子音频 / 封面经
# ffmpeg-kit 打开它；dash demuxer 硬依赖 libxml2，缺了清单被当成未知格式 →
# "Invalid data found when processing input" → required audio missing。--enable-small
# 会剥掉 demuxer 长名，所以判 dashdec.c 与 libxml2 自身独有的串（旧产物两个都扫不到，
# 2026-10-17 实测；带 dash 的完整 ffmpeg 里两个都在）。
# - 'missing root node'：libavformat/dashdec.c 的解析失败日志，dash muxer 里没有。
# - 'xmlParseCharRef'：libxml2 parser.c 的错误串，证明 libxml2 真链进了 libavformat。
FORMAT_MARKERS: List[str] = [
    'missing root node',
    'xmlParseCharRef',
]

ZLIB_SYMBOLS: List[str] = ['deflateInit2_', 'deflateEnd', 'inflateInit_']

EXPECTED_ANDROID_ABIS = {'arm64-v8a', 'armeabi-v7a'}
EXPECTED_IOS_SLICES = {'ios-arm64_arm64e', 'ios-arm64_x86_64-simulator'}
EXPECTED_FRAMEWORKS = {
    'ffmpegkit', 'libavcodec', 'libavdevice', 'libavfilter',
    'libavformat', 'libavutil', 'libswresample', 'libswscale',
}

# iOS 系统库的 Mach-O 兼容版本上限：framework 的 LC_LOAD_DYLIB compat 版本高于设备上的
# 系统库版本时 dyld 拒绝加载（启动即崩）。libiconv.2 自 iOS 早期起就是 7.0.0（Apple
# libiconv-64 系列，部署目标 12.1 起不变）；其余 /usr/lib 库一律要求 compat == 1.0.0
# （ld64 对系统 tbd 的默认值）。超出就当场停，别让一个新 SDK 抬高的版本混进入库产物。
IOS_SYSTEM_DYLIB_MAX_COMPAT: Dict[str, Tuple[int, int, int]] = {
    'iconv': (7, 0, 0),
}
IOS_IMPLICIT_LIBS = {'System', 'objc'}
PODSPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ios', 'ffmpeg_kit_flutter.podspec')

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
    for marker in FORMAT_MARKERS:
        check(marker in fmt, f'{label}: libavformat 含 {marker!r}（dash demuxer + libxml2）')


def macho_system_dylibs(data: bytes) -> List[Tuple[str, Tuple[int, int, int]]]:
    """返回 (库名, compat 版本) 列表：每个 arch 切片里 /usr/lib/lib<名>*.dylib 的 LC_LOAD_DYLIB。"""
    def ver(x: int) -> Tuple[int, int, int]:
        return (x >> 16, (x >> 8) & 0xff, x & 0xff)

    def thin(off: int) -> List[Tuple[str, Tuple[int, int, int]]]:
        if struct.unpack_from('<I', data, off)[0] != 0xfeedfacf:
            return []
        ncmds = struct.unpack_from('<I', data, off + 16)[0]
        p = off + 32
        out: List[Tuple[str, Tuple[int, int, int]]] = []
        for _ in range(ncmds):
            cmd, size = struct.unpack_from('<II', data, p)
            # LC_LOAD_DYLIB / LC_LOAD_WEAK_DYLIB / LC_REEXPORT_DYLIB
            if cmd in (0xc, 0x80000018, 0x8000001f):
                name_off, _ts, _cur, compat = struct.unpack_from('<IIII', data, p + 8)
                path = data[p + name_off:p + size].split(b'\0')[0].decode('latin1')
                m = re.match(r'^/usr/lib/lib([A-Za-z0-9_+]+)\.(?:[A-Za-z0-9]+\.)*dylib$', path)
                if m:
                    out.append((m.group(1), ver(compat)))
            p += size
        return out

    if struct.unpack_from('>I', data, 0)[0] == 0xcafebabe:
        n = struct.unpack_from('>I', data, 4)[0]
        result: List[Tuple[str, Tuple[int, int, int]]] = []
        for i in range(n):
            off = struct.unpack_from('>I', data, 8 + 20 * i + 8)[0]
            result.extend(thin(off))
        return result
    return thin(0)


def podspec_libraries() -> Set[str]:
    with open(PODSPEC, encoding='utf-8') as f:
        m = re.search(r'^\s*s\.libraries\s*=\s*(.+)$', f.read(), re.M)
    return set(re.findall(r"'([^']+)'", m.group(1))) if m else set()


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
                  'license_dav1d.txt', 'license_libxml2.txt', 'source.txt']:
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

    # 系统库依赖：每个 /usr/lib 库都要在 podspec s.libraries 里声明，且 compat 版本不超过
    # iOS 设备上的系统库版本（BUG-3503：libxml2 带进 libiconv.2 / libcharset.1）。
    declared = podspec_libraries()
    check(bool(declared), f'podspec s.libraries 可解析（{PODSPEC}）')
    linked: Dict[str, Tuple[int, int, int]] = {}
    for fw in sorted(frameworks):
        for sl in sorted(EXPECTED_IOS_SLICES):
            p = os.path.join(root, f'{fw}.xcframework', sl, f'{fw}.framework', fw)
            if not os.path.isfile(p):
                continue
            with open(p, 'rb') as f:
                for name, compat in macho_system_dylibs(f.read()):
                    linked[name] = max(linked.get(name, (0, 0, 0)), compat)
    check('c++' in linked and 'z' in linked, f'Mach-O 解析读到了系统库（实际 {sorted(linked)}）')
    for name, compat in sorted(linked.items()):
        if name in IOS_IMPLICIT_LIBS:
            continue
        check(name in declared, f'podspec s.libraries 声明了 {name}（framework 链接 /usr/lib/lib{name}）')
        limit = IOS_SYSTEM_DYLIB_MAX_COMPAT.get(name, (1, 0, 0))
        check(compat <= limit,
              f'lib{name} compat {".".join(map(str, compat))} <= iOS 系统版本 {".".join(map(str, limit))}')


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
