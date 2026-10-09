"""Render a real disc offscreen using the shipped ANGLE + libmpv render API.

No window, device focus, or user preferences are changed. Writes screenshots,
native state snapshots and logs into a new evidence directory. Requires Pillow.
"""
import argparse
import ctypes as C
import json
from pathlib import Path
import time
from PIL import Image
from probe_libmpv import Mpv, Log, preload_runtime


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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", required=True)
    parser.add_argument("--angle", type=Path, required=True)
    parser.add_argument("--disc", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=28)
    parser.add_argument("--actions", type=Path, help="JSON list of {at: seconds, args: [discnav, action, ...]}")
    parser.add_argument("--preload", help="Existing runtime whose DLLs must coexist with the new one")
    args = parser.parse_args()
    preload = preload_runtime(args.preload) if args.preload else []
    actions = json.loads(args.actions.read_text()) if args.actions else [{"at": 24, "args": ["discnav", "right"]}]
    args.output.mkdir(parents=True, exist_ok=False)
    egl = C.WinDLL(str((args.angle / "libEGL.dll").resolve()))
    gl = C.WinDLL(str((args.angle / "libGLESv2.dll").resolve()))
    getdisplay = bind(egl, "eglGetDisplay", C.c_void_p, C.c_void_p)
    initialize = bind(egl, "eglInitialize", C.c_uint, C.c_void_p, C.POINTER(C.c_int), C.POINTER(C.c_int))
    choose = bind(egl, "eglChooseConfig", C.c_uint, C.c_void_p, C.POINTER(C.c_int), C.POINTER(C.c_void_p), C.c_int, C.POINTER(C.c_int))
    surface = bind(egl, "eglCreatePbufferSurface", C.c_void_p, C.c_void_p, C.c_void_p, C.POINTER(C.c_int))
    context = bind(egl, "eglCreateContext", C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p, C.POINTER(C.c_int))
    current = bind(egl, "eglMakeCurrent", C.c_uint, C.c_void_p, C.c_void_p, C.c_void_p, C.c_void_p)
    getproc = bind(egl, "eglGetProcAddress", C.c_void_p, C.c_char_p)
    display = getdisplay(None)
    major, minor = C.c_int(), C.c_int()
    assert initialize(display, C.byref(major), C.byref(minor)), "ANGLE initialization failed"
    cfg, count = C.c_void_p(), C.c_int()
    attrs = (C.c_int * 11)(0x3033, 1, 0x3040, 4, 0x3024, 8, 0x3023, 8, 0x3022, 8, 0x3038)
    assert choose(display, attrs, C.byref(cfg), 1, C.byref(count)) and count.value
    width, height = 960, 540
    surf = surface(display, cfg, (C.c_int * 5)(0x3057, width, 0x3056, height, 0x3038))
    ctx = context(display, cfg, None, (C.c_int * 3)(0x3098, 2, 0x3038))
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

    mpv = Mpv(args.library)
    render_ctx = C.c_void_p()
    try:
        for name, value in (("config", "no"), ("vo", "libmpv"), ("ao", "null"),
                            ("terminal", "no"), ("hwdec", "auto-safe"), ("idle", "yes")):
            assert mpv.option(name, value) == 0
        assert mpv.lib.mpv_initialize(mpv.handle) == 0
        create = bind(mpv.lib, "mpv_render_context_create", C.c_int, C.POINTER(C.c_void_p), C.c_void_p, C.POINTER(RenderParam))
        render = bind(mpv.lib, "mpv_render_context_render", C.c_int, C.c_void_p, C.POINTER(RenderParam))
        api = C.create_string_buffer(b"opengl")
        init = GlInit(proc, None)
        params = (RenderParam * 3)(RenderParam(1, C.cast(api, C.c_void_p)), RenderParam(2, C.cast(C.pointer(init), C.c_void_p)), RenderParam())
        assert create(C.byref(render_ctx), mpv.handle, params) == 0
        mpv.lib.mpv_request_log_messages(mpv.handle, b"v")
        assert mpv.command("loadfile", "bd://menu/" + str(Path(args.disc).resolve())) == 0
        fbo, flip = Fbo(0, width, height, 0), C.c_int(1)
        render_params = (RenderParam * 3)(RenderParam(3, C.cast(C.pointer(fbo), C.c_void_p)), RenderParam(4, C.cast(C.pointer(flip), C.c_void_p)), RenderParam())
        readpixels = bind(gl, "glReadPixels", None, C.c_int, C.c_int, C.c_int, C.c_int, C.c_uint, C.c_uint, C.c_void_p)
        pixels = (C.c_ubyte * (width * height * 4))()
        records, logs, shots = [], [], set()
        start, last = time.monotonic(), -1
        with (args.output / "state.jsonl").open("w", encoding="utf-8") as stream:
            while (elapsed := time.monotonic() - start) < args.seconds:
                event = mpv.lib.mpv_wait_event(mpv.handle, 0.01).contents
                if event.event_id == 2:
                    log = C.cast(event.data, C.POINTER(Log)).contents
                    logs.append(log.prefix.decode() + ": " + log.text.decode("utf-8", "replace").strip())
                assert render(render_ctx, render_params) == 0
                second = int(elapsed)
                if second != last:
                    last = second
                    record = {"elapsed": elapsed, "state": mpv.get("disc-navigation-state"),
                              "wire": mpv.get("disc-navigation-state-json"), "hwdec": mpv.get("hwdec-current"),
                              "aid": mpv.get("aid"), "sid": mpv.get("sid"),
                              "aid-mode": mpv.get("options/aid"), "sid-mode": mpv.get("options/sid")}
                    records.append(record)
                    stream.write(json.dumps(record) + "\n")
                    stream.flush()
                if second in (8, 22, 26, 30, 34, 38) and second not in shots:
                    readpixels(0, 0, width, height, 0x1908, 0x1401, pixels)
                    Image.frombytes("RGBA", (width, height), bytes(pixels)).transpose(Image.Transpose.FLIP_TOP_BOTTOM).save(args.output / f"frame-{second}.png")
                    shots.add(second)
                for action in actions:
                    if elapsed >= action["at"] and not action.get("done"):
                        if action["args"] == ["menu-when-allowed"]:
                            navigation = mpv.get("disc-navigation-state")
                            if not isinstance(navigation, dict) or not navigation.get("menu-call-allowed"):
                                continue
                            action["args"] = ["discnav", "menu"]
                        if action["args"] == ["select-japanese-subtitle"]:
                            tracks = mpv.get("track-list")
                            matches = [track for track in tracks if track.get("type") == "sub"
                                       and track.get("lang", "").lower() in ("ja", "jpn")]
                            assert matches, f"No Japanese subtitle track: {tracks}"
                            action["args"] = ["set", "sid", str(matches[0]["id"])]
                            assert mpv.command("set", "sub-visibility", "yes") == 0
                            records.append({"japanese_subtitle_track": matches[0]})
                        command_result = mpv.command(*action["args"])
                        records.append({"command": action["args"], "result": command_result})
                        assert command_result == 0, f"Navigation failed: {action}"
                        action["done"] = True
        (args.output / "native.log").write_text("\n".join(logs), encoding="utf-8")
        print(json.dumps({"egl": [major.value, minor.value], "records": records, "frames": sorted(shots),
                          "preloaded_modules": len(preload) - 1 if preload else 0}, indent=2))
        assert any(isinstance(r.get("state"), dict) and r["state"].get("menu-active") for r in records), "No interactive menu rendered"
    finally:
        if render_ctx:
            bind(mpv.lib, "mpv_render_context_free", None, C.c_void_p)(render_ctx)
        mpv.close()
        current(display, None, None, None)
        bind(egl, "eglDestroyContext", C.c_uint, C.c_void_p, C.c_void_p)(display, ctx)
        bind(egl, "eglDestroySurface", C.c_uint, C.c_void_p, C.c_void_p)(display, surf)
        bind(egl, "eglTerminate", C.c_uint, C.c_void_p)(display)


if __name__ == "__main__":
    main()
