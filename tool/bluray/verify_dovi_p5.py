"""BUG-2691: verify the texture renderer reshapes Dolby Vision profile 5.

Renders tests/dovi-p5.mkv (a generated DV profile 5 clip: dovi_tool's P5 RPU
on an HEVC Main 10 stream; its reshaping curves are identity, so this checks
the IPT -> LMS -> RGB decode, not the polynomial / MMR evaluation, which was
checked against real P5 content on macOS / Android, BUG-2691) and
tests/dovi-p81.mkv (profile 8.1, see EXPECTED)
with the given libmpv + shipped ANGLE through the
OpenGL render API (vo=libmpv, i.e. gl_video, the renderer Fushi's video texture
uses), on an EGL display bound to our own D3D11 device like media_kit_video's
ANGLESurfaceManager, once per hwdec mode. The picture is rendered to PQ /
BT.2020 so no tone mapping is involved, and compared cell by cell with
tests/dovi-p5-reference.json: libplacebo's own rendering of the first frame
(ffmpeg `libplacebo=apply_dolbyvision=1`, the code mpv's gl_video patch was
ported from). Without the reshaping patch the IPT samples are decoded as
YCbCr, which is what `apply_dolbyvision=0` gives ("unreshaped" in the JSON).

No window or focus is touched. Requires Pillow.

python tool/bluray/verify_dovi_p5.py --library <dir with libmpv-2.dll> --angle <dir with libEGL.dll> --work <new dir>

Regenerating the fixture (needs dovi_tool, x265-enabled ffmpeg, and ffmpeg
with libplacebo + Vulkan for the reference):

  dovi_tool generate -j {"cm_version":"V40","profile":"5","length":12,...} -o rpu.bin
  ffmpeg -f lavfi -i testsrc2=s=640x360:r=24:d=0.5 -pix_fmt yuv420p10le -c:v libx265
         -x265-params bframes=0:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:range=full
         -crf 8 -f hevc bl.hevc
  dovi_tool inject-rpu -i bl.hevc --rpu-in rpu.bin -o dv.hevc
  ffmpeg -fflags +genpts -framerate 24 -i dv.hevc -c copy dovi-p5.mkv
  python verify_dovi_p5.py --reference-from p5 <ref1.png> <ref0.png>
"""
import argparse
import ctypes as C
import json
import os
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image
from probe_libmpv import Mpv

HERE = Path(__file__).resolve().parent
# Which libplacebo picture each fixture must match. Profile 5 (IPT, no
# compatible base layer: the case BUG-2691 fixes) is only correct reshaped.
# Profile 8.1 carries an HDR10 base layer; the gl_video patch deliberately
# leaves it alone (libmpv still reports colormatrix=dolbyvision for it), so it
# must show that base layer exactly - the RPU is ignored, as on any HDR10-only
# player. Its generated RPU is near-identity (reshaped vs unreshaped differ by
# ~4), so only the unreshaped comparison is a meaningful gate for it: it proves
# the base layer is shown correctly, not that the patch skips P8.1 (that is the
# patch's own vdr_rpu_profile / full-range gate).
EXPECTED = {"p5": "reshaped", "p81": "unreshaped"}
FIXTURES = tuple(EXPECTED)
WIDTH, HEIGHT = 640, 360
COLS, ROWS = 16, 9
# Mean absolute difference per channel (8-bit PQ code values) over all cells.
# Measured (P5): patched gl_video vs libplacebo 0.36, unpatched 114.
MAX_MEAN_ERROR = 6.0


def clip_of(fixture: str) -> Path:
    return HERE / "tests" / f"dovi-{fixture}.mkv"


def reference_of(fixture: str) -> Path:
    return HERE / "tests" / f"dovi-{fixture}-reference.json"


class RenderParam(C.Structure):
    _fields_ = [("type", C.c_int), ("data", C.c_void_p)]


class Fbo(C.Structure):
    _fields_ = [("fbo", C.c_int), ("w", C.c_int), ("h", C.c_int), ("format", C.c_int)]


GETPROC = C.CFUNCTYPE(C.c_void_p, C.c_void_p, C.c_char_p)


class GlInit(C.Structure):
    _fields_ = [("get_proc_address", GETPROC), ("ctx", C.c_void_p)]


def bind(lib, name, result, *args):
    fn = getattr(lib, name)
    fn.restype, fn.argtypes = result, args
    return fn


HWDEC = {"zero-copy": "d3d11va", "copy": "d3d11va-copy", "software": "no"}
# What mpv must report as hwdec-current for each mode.
HWDEC_EXPECTED = {"zero-copy": "d3d11va", "copy": "d3d11va-copy", "software": "no"}


def cells(img: Image.Image) -> list:
    """Mean RGB of a 5x5 block at the centre of each grid cell."""
    rgb = img.convert("RGB")
    px = rgb.load()
    out = []
    for r in range(ROWS):
        for c in range(COLS):
            cx = int((c + 0.5) * WIDTH / COLS)
            cy = int((r + 0.5) * HEIGHT / ROWS)
            acc = [0, 0, 0]
            for dy in range(-2, 3):
                for dx in range(-2, 3):
                    p = px[cx + dx, cy + dy]
                    for k in range(3):
                        acc[k] += p[k]
            out.append([round(a / 25, 2) for a in acc])
    return out


def mean_error(a: list, b: list) -> float:
    total = sum(abs(x - y) for ca, cb in zip(a, b) for x, y in zip(ca, cb))
    return round(total / (len(a) * 3), 2)


def render_case(library: Path, angle: Path, out: Path, fixture: str, hwdec: str) -> dict:
    os.add_dll_directory(str(angle.resolve()))
    os.add_dll_directory(str(library.resolve()))
    egl = C.WinDLL(str(angle / "libEGL.dll"))
    gl = C.WinDLL(str(angle / "libGLESv2.dll"))
    getproc = bind(egl, "eglGetProcAddress", C.c_void_p, C.c_char_p)
    initialize = bind(egl, "eglInitialize", C.c_uint, C.c_void_p, C.c_void_p, C.c_void_p)
    choose = bind(egl, "eglChooseConfig", C.c_uint, C.c_void_p, C.POINTER(C.c_int), C.POINTER(C.c_void_p),
                  C.c_int, C.POINTER(C.c_int))
    surface = bind(egl, "eglCreatePbufferSurface", C.c_void_p, C.c_void_p, C.c_void_p, C.POINTER(C.c_int))
    context = bind(egl, "eglCreateContext", C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p, C.POINTER(C.c_int))
    current = bind(egl, "eglMakeCurrent", C.c_uint, C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p)

    d3d11 = C.WinDLL("d3d11.dll")
    create_device = bind(d3d11, "D3D11CreateDevice", C.c_long, C.c_void_p, C.c_int, C.c_void_p, C.c_uint,
                         C.POINTER(C.c_int), C.c_uint, C.c_uint, C.POINTER(C.c_void_p), C.POINTER(C.c_int),
                         C.POINTER(C.c_void_p))
    levels = (C.c_int * 4)(0xb000, 0xa100, 0xa000, 0x9300)
    dev, dctx, got = C.c_void_p(), C.c_void_p(), C.c_int()
    assert create_device(None, 1, None, 0x820, levels, 4, 7, C.byref(dev), C.byref(got), C.byref(dctx)) == 0
    egl_dev = C.CFUNCTYPE(C.c_void_p, C.c_int, C.c_void_p, C.c_void_p)(getproc(b"eglCreateDeviceANGLE"))(
        0x33A1, dev, None)
    display = C.CFUNCTYPE(C.c_void_p, C.c_int, C.c_void_p, C.c_void_p)(getproc(b"eglGetPlatformDisplayEXT"))(
        0x313F, egl_dev, None)
    assert display and initialize(display, None, None), "ANGLE on the shared D3D11 device failed"
    cfg, count = C.c_void_p(), C.c_int()
    attrs = (C.c_int * 13)(0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3021, 8, 0x3033, 1, 0x3040, 4, 0x3038)
    assert choose(display, attrs, C.byref(cfg), 1, C.byref(count)) and count.value
    surf = surface(display, cfg, (C.c_int * 5)(0x3057, WIDTH, 0x3056, HEIGHT, 0x3038))
    ctx = context(display, cfg, None, (C.c_int * 3)(0x3098, 3, 0x3038))
    assert surf and ctx and current(display, surf, surf, ctx)

    @GETPROC
    def proc(_, name):
        ptr = getproc(name)
        if ptr:
            return ptr
        try:
            return C.cast(getattr(gl, name.decode()), C.c_void_p).value
        except AttributeError:
            return None

    mpv = Mpv(str(library / "libmpv-2.dll"))
    options = {"config": "no", "vo": "libmpv", "ao": "null", "terminal": "no", "idle": "yes", "pause": "yes",
               "hwdec": HWDEC[hwdec], "target-prim": "bt.2020", "target-trc": "pq", "dither-depth": "no",
               "deband": "no", "interpolation": "no", "scale": "bilinear", "cscale": "bilinear",
               "dscale": "bilinear"}
    for key, value in options.items():
        assert mpv.option(key, value) == 0, (key, value)
    assert mpv.lib.mpv_initialize(mpv.handle) == 0
    create = bind(mpv.lib, "mpv_render_context_create", C.c_int, C.POINTER(C.c_void_p), C.c_void_p,
                  C.POINTER(RenderParam))
    render = bind(mpv.lib, "mpv_render_context_render", C.c_int, C.c_void_p, C.POINTER(RenderParam))
    render_ctx = C.c_void_p()
    api = C.create_string_buffer(b"opengl")
    init = GlInit(proc, None)
    params = (RenderParam * 3)(RenderParam(1, C.cast(api, C.c_void_p)),
                               RenderParam(2, C.cast(C.pointer(init), C.c_void_p)), RenderParam())
    assert create(C.byref(render_ctx), mpv.handle, params) == 0
    assert mpv.command("loadfile", str(clip_of(fixture))) == 0
    fbo = Fbo(0, WIDTH, HEIGHT, 0)
    render_params = (RenderParam * 2)(RenderParam(3, C.cast(C.pointer(fbo), C.c_void_p)), RenderParam())
    start = time.monotonic()
    while time.monotonic() - start < 3:
        mpv.lib.mpv_wait_event(mpv.handle, 0.01)
        render(render_ctx, render_params)
    pixels = (C.c_ubyte * (WIDTH * HEIGHT * 4))()
    bind(gl, "glReadPixels", None, C.c_int, C.c_int, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_void_p)(
        0, 0, WIDTH, HEIGHT, 0x1908, 0x1401, pixels)
    image = Image.frombytes("RGBA", (WIDTH, HEIGHT), bytes(pixels))
    image.save(out)
    result = {"fixture": fixture, "hwdec": hwdec, "hwdec_current": mpv.get("hwdec-current"),
              "colormatrix": mpv.get("video-params/colormatrix"), "cells": cells(image)}
    bind(mpv.lib, "mpv_render_context_free", None, C.c_void_p)(render_ctx)
    mpv.close()
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library", type=Path)
    parser.add_argument("--angle", type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--reference-from", nargs=3, metavar=("FIXTURE", "RESHAPED", "UNRESHAPED"),
                        help="write tests/dovi-<fixture>-reference.json from two libplacebo PNGs")
    parser.add_argument("--case", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.reference_from:
        fixture, *pngs = args.reference_from
        reshaped, unreshaped = (cells(Image.open(p)) for p in pngs)
        reference_of(fixture).write_text(json.dumps({"reshaped": reshaped, "unreshaped": unreshaped}) + "\n")
        print(f"unreshaped vs reshaped: {mean_error(unreshaped, reshaped)}")
        return 0
    if args.case:
        fixture, hwdec = args.case.split(":")
        print(json.dumps(render_case(args.library, args.angle, args.work / f"{fixture}-{hwdec}.png", fixture,
                                     hwdec)))
        return 0
    args.work.mkdir(parents=True, exist_ok=False)
    failures, results = [], []
    # One process per case: libmpv / ANGLE globals must not leak between cases.
    for fixture, hwdec in ((f, h) for f in FIXTURES for h in HWDEC):
        reference = json.loads(reference_of(fixture).read_text())
        proc = subprocess.run([sys.executable, __file__, "--library", str(args.library), "--angle",
                               str(args.angle), "--work", str(args.work), "--case", f"{fixture}:{hwdec}"],
                              capture_output=True, text=True, timeout=120)
        if proc.returncode != 0 or not proc.stdout.strip():
            failures.append(f"{fixture}/{hwdec}: render failed\n{proc.stderr[-800:]}")
            continue
        result = json.loads(proc.stdout.strip().splitlines()[-1])
        cells_ = result.pop("cells")
        result["error_vs_reshaped"] = mean_error(cells_, reference["reshaped"])
        result["error_vs_unreshaped"] = mean_error(cells_, reference["unreshaped"])
        results.append(result)
        # A hwdec mode that silently fell back to software would make that cell
        # prove nothing about the zero-copy / copy-back path.
        if result["hwdec_current"] != HWDEC_EXPECTED[hwdec]:
            failures.append(f"{fixture}/{hwdec}: hwdec-current is {result['hwdec_current']!r}")
        if result["colormatrix"] != "dolbyvision":
            failures.append(f"{fixture}/{hwdec}: libmpv did not detect Dolby Vision {result}")
        expected = EXPECTED[fixture]
        if result[f"error_vs_{expected}"] > MAX_MEAN_ERROR:
            failures.append(f"{fixture}/{hwdec}: colours differ from libplacebo's {expected} picture {result}")
    print(json.dumps(results, indent=2))
    for failure in failures:
        print("FAIL", failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
