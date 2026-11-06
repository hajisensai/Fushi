"""生成 image_codec_test 的 AVIF 样本与参考像素（PNG）。

    python -I gen_avif_fixtures.py <ffmpeg 可执行文件>

sequence.avif（动图）另需 libsvtav1。

依赖：Pillow >= 11.2（自带 libavif，2026-10 用 Pillow 12.2 / libavif 1.4.1 生成）、带 libaom-av1
与 avif muxer 的 ffmpeg（10 位 / 单色样本）。参考像素来自 libavif 解码（与本仓 rav1d 解码相互独立）；
irot / imir 由 Pillow 转成 EXIF 方向，参考图用 exif_transpose 转正。grid 与 clap 样本由本脚本按
ISO/IEC 23008-12 手工拼盒子，参考图按规范从源图裁 / 拼。
"""

import io
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageOps

OUT = Path(__file__).resolve().parent


def synth(w, h, alpha=False):
    """平滑渐变 + 几块实色几何形状（4:2:0 只在形状边缘有色度误差）。"""
    im = Image.new("RGBA" if alpha else "RGB", (w, h))
    px = im.load()
    for y in range(h):
        for x in range(w):
            r, g, b = x * 255 // max(w - 1, 1), y * 255 // max(h - 1, 1), (x + y) * 127 // max(w + h - 2, 1) + 64
            px[x, y] = (r, g, b, (x * 4 + y * 2) % 256) if alpha else (r, g, b)
    d = ImageDraw.Draw(im)
    d.rectangle([w // 8, h // 6, w // 3, h // 2], fill=(220, 30, 40, 255) if alpha else (220, 30, 40))
    d.ellipse([w // 2, h // 3, w - 4, h - 4], fill=(20, 40, 200, 160) if alpha else (20, 40, 200))
    d.text((3, 2), "AV", fill=(255, 255, 255, 255) if alpha else (255, 255, 255))
    return im


def save_ref(name, im):
    im.save(OUT / f"{name}.ref.png")


def pillow_avif(name, im, **kw):
    path = OUT / f"{name}.avif"
    im.save(path, **kw)
    ref = ImageOps.exif_transpose(Image.open(path))
    save_ref(name, ref.convert(im.mode if im.mode in ("RGB", "RGBA") else "RGB"))
    return path


def ffmpeg_avif(ffmpeg, name, im, pix_fmt):
    src = tempfile.NamedTemporaryFile(suffix=".png", delete=False).name
    im.save(src)
    path = OUT / f"{name}.avif"
    subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-i", src, "-c:v", "libaom-av1", "-still-picture", "1",
         "-crf", "4", "-cpu-used", "8", "-pix_fmt", pix_fmt, "-frames:v", "1", str(path)],
        check=True,
    )
    save_ref(name, Image.open(path).convert("RGB"))


# --- 最小 ISOBMFF 读写（只覆盖 Pillow 输出的单图 AVIF） ------------------------------------

def boxes(data, start=0, end=None):
    end = len(data) if end is None else end
    at = start
    while at + 8 <= end:
        size, kind = struct.unpack(">I4s", data[at:at + 8])
        yield kind, at + 8, at + size
        at += size


def child(data, start, end, kind):
    return next((b, e) for k, b, e in boxes(data, start, end) if k == kind)


def single_item(path):
    """Pillow 单图 AVIF → (AV1 载荷, av1C 盒子整体字节, ispe 宽高)。"""
    data = path.read_bytes()
    mb, me = child(data, 0, len(data), b"meta")
    mb += 4
    lb, _ = child(data, mb, me, b"iloc")
    ver = data[lb]
    assert ver in (0, 1), ver
    sizes = data[lb + 4]
    off_size, len_size = sizes >> 4, sizes & 15
    base_size = data[lb + 5] >> 4
    count = struct.unpack(">H", data[lb + 6:lb + 8])[0]
    at = lb + 8
    payload = None
    for _ in range(count):
        item_id = struct.unpack(">H", data[at:at + 2])[0]
        at += 2
        if ver == 1:
            at += 2
        at += 2
        base = int.from_bytes(data[at:at + base_size], "big")
        at += base_size
        n = struct.unpack(">H", data[at:at + 2])[0]
        at += 2
        chunks = []
        for _ in range(n):
            o = int.from_bytes(data[at:at + off_size], "big")
            at += off_size
            ln = int.from_bytes(data[at:at + len_size], "big")
            at += len_size
            chunks.append(data[base + o:base + o + ln])
        if item_id == 1:
            payload = b"".join(chunks)
    pb, pe = child(data, mb, me, b"iprp")
    cb, ce = child(data, pb, pe, b"ipco")
    av1c = ispe = None
    for k, b, e in boxes(data, cb, ce):
        if k == b"av1C":
            av1c = data[b - 8:e]
        if k == b"ispe":
            ispe = struct.unpack(">II", data[b + 4:b + 12])
    assert payload and av1c and ispe
    return payload, av1c, ispe


def box(kind, body):
    return struct.pack(">I4s", 8 + len(body), kind) + body


def full(kind, version, flags, body):
    return box(kind, struct.pack(">I", (version << 24) | flags) + body)


def heif(items, primary, props, assoc, refs=b"", idat=b""):
    """items: [(id, type, data|None 表示放 idat, idat_offset)]；数据放 mdat，返回整文件。"""
    ftyp = box(b"ftyp", b"avif" + b"\0\0\0\0" + b"avifmif1miaf")
    infe = b"".join(full(b"infe", 2, 0, struct.pack(">HH4s", i, 0, t) + b"\0") for i, t, *_ in items)
    iinf = full(b"iinf", 0, 0, struct.pack(">H", len(items)) + infe)
    ipco = box(b"ipco", b"".join(props))
    ipma_body = struct.pack(">I", len(assoc))
    for item_id, links in assoc:
        ipma_body += struct.pack(">HB", item_id, len(links))
        for index, essential in links:
            ipma_body += bytes([(0x80 if essential else 0) | index])
    iprp = box(b"iprp", ipco + full(b"ipma", 0, 0, ipma_body))
    pitm = full(b"pitm", 0, 0, struct.pack(">H", primary))
    hdlr = full(b"hdlr", 0, 0, b"\0\0\0\0pict" + b"\0" * 12 + b"\0")
    iref = full(b"iref", 0, 0, refs) if refs else b""
    idat_box = box(b"idat", idat) if idat else b""

    def build(mdat_start):
        body = struct.pack(">BBH", 0x44, 0x00, len(items))
        at = mdat_start
        for item_id, _, data, idat_off in items:
            if data is None:
                body += struct.pack(">HHHHII", item_id, 1, 0, 1, idat_off, len(idat))
            else:
                body += struct.pack(">HHHHII", item_id, 0, 0, 1, at, len(data))
                at += len(data)
        iloc = full(b"iloc", 1, 0, body)
        return full(b"meta", 0, 0, hdlr + pitm + iloc + iinf + iprp + iref + idat_box)

    meta = build(0)
    mdat_start = len(ftyp) + len(meta) + 8
    meta = build(mdat_start)
    mdat = box(b"mdat", b"".join(d for _, _, d, _ in items if d is not None))
    return ftyp + meta + mdat


def ispe(w, h):
    return full(b"ispe", 0, 0, struct.pack(">II", w, h))


def grid_fixture():
    """2×2 grid，瓦片 40×32，输出 72×60（右列 / 下行被裁掉一部分）。"""
    tw, th, ow, oh = 40, 32, 72, 60
    src = synth(tw * 2, th * 2)
    tiles = []
    # 参考：libavif 解出的各瓦片按行主序拼起来，再裁到输出尺寸。
    ref = Image.new("RGB", (tw * 2, th * 2))
    for row in range(2):
        for col in range(2):
            tile = src.crop((col * tw, row * th, col * tw + tw, row * th + th))
            buf = OUT / "_tile.avif"
            tile.save(buf, quality=100, subsampling="4:4:4")
            tiles.append(single_item(buf))
            ref.paste(Image.open(buf).convert("RGB"), (col * tw, row * th))
            buf.unlink()
    av1c = tiles[0][1]
    assert all(t[1] == av1c for t in tiles), "瓦片的 av1C 必须一致"
    grid_desc = struct.pack(">BBBBHH", 0, 0, 1, 1, ow, oh)
    items = [(1, b"grid", None, 0)] + [(i + 2, b"av01", t[0], 0) for i, t in enumerate(tiles)]
    props = [ispe(ow, oh), ispe(tw, th), av1c]
    assoc = [(1, [(1, False)])] + [(i + 2, [(2, False), (3, True)]) for i in range(4)]
    refs = box(b"dimg", struct.pack(">HH", 1, 4) + b"".join(struct.pack(">H", i + 2) for i in range(4)))
    (OUT / "grid.avif").write_bytes(heif(items, 1, props, assoc, refs, grid_desc))
    save_ref("grid", ref.crop((0, 0, ow, oh)))


def clap_fixture():
    """单图 + clap（64×48 里取中心偏右下 40×30，偏移 (+4, +2)）+ irot 1（逆时针 90°）。"""
    w, h = 64, 48
    src = synth(w, h)
    buf = OUT / "_clap.avif"
    src.save(buf, quality=100, subsampling="4:4:4")
    payload, av1c, _ = single_item(buf)
    decoded = Image.open(buf).convert("RGB")
    buf.unlink()
    cw, ch, dx, dy = 40, 30, 4, 2
    clap = box(b"clap", struct.pack(">IIIIiIiI", cw, 1, ch, 1, dx, 1, dy, 1))
    irot = box(b"irot", bytes([1]))
    props = [ispe(w, h), av1c, clap, irot]
    assoc = [(1, [(1, False), (2, True), (3, True), (4, True)])]
    (OUT / "clap_rot.avif").write_bytes(heif([(1, b"av01", payload, 0)], 1, props, assoc))
    x0 = (w - cw) // 2 + dx
    y0 = (h - ch) // 2 + dy
    save_ref("clap_rot", decoded.crop((x0, y0, x0 + cw, y0 + ch)).transpose(Image.Transpose.ROTATE_90))


def sequence_fixture(ffmpeg):
    """sequence.avif：64×36 四帧纯色动图（avis 图像序列），红 / 绿 / 蓝 / 白，时长 80 / 160 / 240 / 40 ms，
    无限循环。编码参数同制卡（libsvtav1 preset 8，yuv420p，-loop 0；SVT 的随机访问 GOP 会产生
    隐藏帧 + show_existing_frame 样本，正好覆盖逐样本顺序解码）。concat 的末帧时长取不到 duration
    指令、由 muxer 按 25 fps 补 40 ms，所以末帧是 40 而不是列表里的 400。"""
    tmp = Path(tempfile.mkdtemp())
    colors = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
    lines = []
    for i, (c, d) in enumerate(zip(colors, (0.08, 0.16, 0.24, 0.4))):
        Image.new("RGB", (64, 36), c).save(tmp / f"f{i}.png")
        lines += [f"file 'f{i}.png'", f"duration {d}"]
    lines.append("file 'f3.png'")
    (tmp / "list.txt").write_text("\n".join(lines) + "\n")
    subprocess.run(
        [ffmpeg, "-y", "-loglevel", "error", "-f", "concat", "-i", str(tmp / "list.txt"),
         "-fps_mode", "vfr", "-frames:v", "4", "-c:v", "libsvtav1", "-preset", "8", "-crf", "20",
         "-pix_fmt", "yuv420p", "-loop", "0", str(OUT / "sequence.avif")],
        check=True,
    )


def main():
    ffmpeg = sys.argv[1]
    pillow_avif("rgb420", synth(61, 47), quality=90, subsampling="4:2:0")
    pillow_avif("rgb444", synth(64, 40), quality=100, subsampling="4:4:4")
    pillow_avif("rgba", synth(48, 36, alpha=True), quality=100, subsampling="4:4:4")
    for orientation in (2, 6, 7):
        im = synth(40, 24)
        exif = Image.Exif()
        exif[0x0112] = orientation
        pillow_avif(f"orient{orientation}", im, quality=100, subsampling="4:4:4", exif=exif.tobytes())
    ffmpeg_avif(ffmpeg, "ten_bit", synth(64, 48), "yuv444p10le")
    ffmpeg_avif(ffmpeg, "gray", synth(64, 48).convert("L").convert("RGB"), "gray")
    grid_fixture()
    clap_fixture()
    sequence_fixture(ffmpeg)


if __name__ == "__main__":
    main()
