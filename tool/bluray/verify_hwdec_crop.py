"""BUG-3296: verify libmpv crops padded hwdec surfaces in every render mode.

Renders a generated 1920x1080 H.264 clip (coded 1920x1088: the bottom 8 coded
rows are encoder padding) with the shipped libmpv + shipped ANGLE through the
OpenGL render API, on an EGL display bound to our own D3D11 device exactly like
media_kit_video's ANGLESurfaceManager (so libmpv's d3d11-egl zero-copy interop
is used). The clip has a green top band (8 rows), a red bottom band (8 rows) and
a 2-row white line every 120 rows. Correct cropping keeps both bands at 8 rows
and the lines at 120.5/240.5/.../960.5; the BUG-3296 squash shows a 16-row red
band and lines scaled by 1080/1088.

No window or focus is touched. Requires ffmpeg (for the clip) and Pillow.

python tool/bluray/verify_hwdec_crop.py --library <dir with libmpv-2.dll> --angle <dir with libEGL.dll> --work <new dir>
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


# Option sets that mirror Fushi's two "画质增强" states on Windows (media_kit
# defaults + VideoMpvConfig). "off" is exactly what makes vo=gpu pick dumb mode.
COMMON = {"correct-downscaling": "no", "linear-downscaling": "no", "sigmoid-upscaling": "no",
          "deband": "no", "dither-depth": "no", "interpolation": "no"}
SCALERS = {
    "off": {"scale": "bilinear", "cscale": "bilinear", "dscale": "bilinear"},
    "low": {"scale": "ewa_lanczossharp", "cscale": "ewa_lanczossharp", "dscale": "mitchell"},
}
HWDEC = {"default": "d3d11va,d3d11va-copy", "copy": "d3d11va-copy", "software": "no"}


def make_clip(path: Path) -> None:
    boxes = ["drawbox=x=0:y=0:w=1920:h=8:color=green:t=fill",
             "drawbox=x=0:y=1072:w=1920:h=8:color=red:t=fill"]
    boxes += [f"drawbox=x=0:y={k * 120}:w=1920:h=2:color=white:t=fill" for k in range(1, 9)]
    src = "color=c=0x404040:s=1920x1080:r=24:d=10," + ",".join(boxes)
    subprocess.check_call(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", src,
                           "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "10", str(path)])


def measure(img: Image.Image) -> dict:
    w, h = img.size
    px = img.load()
    rows = [px[w // 2, y][:3] for y in range(h)]

    def run(pred, ys):
        n = 0
        for y in ys:
            if not pred(rows[y]):
                break
            n += 1
        return n

    lines, cur = [], []
    for y in range(h):
        if min(rows[y]) <= 180:
            continue
        if cur and y != cur[-1] + 1:
            lines.append(sum(cur) / len(cur))
            cur = []
        cur.append(y)
    if cur:
        lines.append(sum(cur) / len(cur))
    return {"top_green": run(lambda c: c[1] > 90 and c[0] < 60 and c[2] < 60, range(h)),
            "bottom_red": run(lambda c: c[0] > 150 and c[1] < 90 and c[2] < 90, range(h - 1, -1, -1)),
            "white_lines": lines}


def render_case(library: Path, angle: Path, clip: Path, out: Path, scaler: str, hwdec: str) -> dict:
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

    # D3D11 device with VIDEO_SUPPORT|BGRA_SUPPORT, ANGLE bound to it (media_kit's zero-copy setup).
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
    width, height = 1920, 1080
    surf = surface(display, cfg, (C.c_int * 5)(0x3057, width, 0x3056, height, 0x3038))
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
               "hwdec": HWDEC[hwdec], **COMMON, **SCALERS[scaler]}
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
    assert mpv.command("loadfile", str(clip.resolve())) == 0
    fbo = Fbo(0, width, height, 0)
    render_params = (RenderParam * 2)(RenderParam(3, C.cast(C.pointer(fbo), C.c_void_p)), RenderParam())
    start = time.monotonic()
    while time.monotonic() - start < 4:
        mpv.lib.mpv_wait_event(mpv.handle, 0.01)
        render(render_ctx, render_params)
    pixels = (C.c_ubyte * (width * height * 4))()
    bind(gl, "glReadPixels", None, C.c_int, C.c_int, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_void_p)(
        0, 0, width, height, 0x1908, 0x1401, pixels)
    image = Image.frombytes("RGBA", (width, height), bytes(pixels))
    image.save(out)
    result = {"scaler": scaler, "hwdec": hwdec, "hwdec_current": mpv.get("hwdec-current"), **measure(image)}
    bind(mpv.lib, "mpv_render_context_free", None, C.c_void_p)(render_ctx)
    mpv.close()
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--angle", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--case", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.case:
        scaler, hwdec = args.case.split(":")
        print(json.dumps(render_case(args.library, args.angle, args.work / "crop1088.mp4",
                                     args.work / f"{scaler}-{hwdec}.png", scaler, hwdec)))
        return 0
    args.work.mkdir(parents=True, exist_ok=False)
    make_clip(args.work / "crop1088.mp4")
    expected_lines = [120.5 + 120 * k for k in range(8)]
    failures, results = [], []
    # One process per case: libmpv / ANGLE globals must not leak between cases.
    for scaler in SCALERS:
        for hwdec in HWDEC:
            proc = subprocess.run([sys.executable, __file__, "--library", str(args.library), "--angle",
                                   str(args.angle), "--work", str(args.work), "--case", f"{scaler}:{hwdec}"],
                                  capture_output=True, text=True, timeout=120)
            if proc.returncode != 0 or not proc.stdout.strip():
                failures.append(f"{scaler}/{hwdec}: render failed\n{proc.stderr[-800:]}")
                continue
            result = json.loads(proc.stdout.strip().splitlines()[-1])
            results.append(result)
            if result["top_green"] != 8 or result["bottom_red"] != 8 or result["white_lines"] != expected_lines:
                failures.append(f"{scaler}/{hwdec}: wrong geometry {result}")
    print(json.dumps(results, indent=2))
    for failure in failures:
        print("FAIL", failure, file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
