"""Probe the actual libmpv binary, without creating a window or changing files.

The Lua check writes one throwaway script to a temporary directory.

python tool/bluray/probe_libmpv.py /path/to/libmpv-2.dll [--disc /path/to/disc]
    [--dvd /path/to/VIDEO_TS-or-iso]
The optional disc probes report native logs, not an assertion of menu playback.

DVD (docs/specs/2026-10-24-dvd-original-menu.md) is a required capability:
the build must expose the `dvd` protocol (stream_dvdnav, -Ddvdnav=enabled) AND
have libdvdcss loaded as a link-time dependency of the library (libdvdread
built --with-libdvdcss). A runtime without libdvdcss would only play
unencrypted discs, so it fails here instead of degrading at the first
commercial disc.
"""

import argparse
import ctypes as C
import json
import os
from pathlib import Path
import sys
import tempfile
import time


class Node(C.Structure):
    pass


class NodeList(C.Structure):
    _fields_ = [("num", C.c_int), ("values", C.POINTER(Node)),
                ("keys", C.POINTER(C.c_char_p))]


class NodeValue(C.Union):
    _fields_ = [("string", C.c_char_p), ("flag", C.c_int),
                ("int64", C.c_int64), ("double", C.c_double),
                ("list", C.POINTER(NodeList))]


Node._fields_ = [("u", NodeValue), ("format", C.c_int)]


class Event(C.Structure):
    _fields_ = [("event_id", C.c_int), ("error", C.c_int),
                ("reply_userdata", C.c_uint64), ("data", C.c_void_p)]


class Log(C.Structure):
    _fields_ = [("prefix", C.c_char_p), ("level", C.c_char_p),
                ("text", C.c_char_p), ("log_level", C.c_int)]


def decode(node):
    if node.format == 1:
        return node.u.string.decode("utf-8", "replace")
    if node.format == 3:
        return bool(node.u.flag)
    if node.format == 4:
        return node.u.int64
    if node.format == 5:
        return node.u.double
    if node.format in (7, 8):
        items = node.u.list.contents
        values = [decode(items.values[i]) for i in range(items.num)]
        if node.format == 7:
            return values
        return {items.keys[i].decode(): values[i] for i in range(items.num)}
    return None


def preload_runtime(directory):
    """Retain the already-installed application's DLLs to test coexistence."""
    root = Path(directory).resolve()
    handles = [os.add_dll_directory(str(root))]
    for name in ("libcrypto-3-x64.dll", "libssl-3-x64.dll", "libplacebo-360.dll",
                 "libwinpthread-1.dll", "vulkan-1.dll"):
        handles.append(C.CDLL(str(root / name)))
    return handles


class Mpv:
    def __init__(self, path):
        self.lib = C.CDLL(str(Path(path).resolve()))
        definitions = {
            "mpv_create": (C.c_void_p, []),
            "mpv_initialize": (C.c_int, [C.c_void_p]),
            "mpv_set_option_string": (C.c_int, [C.c_void_p, C.c_char_p, C.c_char_p]),
            "mpv_get_property": (C.c_int, [C.c_void_p, C.c_char_p, C.c_int, C.c_void_p]),
            "mpv_free_node_contents": (None, [C.POINTER(Node)]),
            "mpv_command": (C.c_int, [C.c_void_p, C.POINTER(C.c_char_p)]),
            "mpv_wait_event": (C.POINTER(Event), [C.c_void_p, C.c_double]),
            "mpv_request_log_messages": (C.c_int, [C.c_void_p, C.c_char_p]),
            "mpv_terminate_destroy": (None, [C.c_void_p]),
        }
        for name, (result, args) in definitions.items():
            function = getattr(self.lib, name)
            function.restype, function.argtypes = result, args
        self.handle = self.lib.mpv_create()
        if not self.handle:
            raise RuntimeError("mpv_create failed")

    def option(self, name, value):
        return self.lib.mpv_set_option_string(self.handle, name.encode(), value.encode())

    def get(self, name):
        node = Node()
        result = self.lib.mpv_get_property(self.handle, name.encode(), 6, C.byref(node))
        if result < 0:
            return {"error": result}
        try:
            return decode(node)
        finally:
            self.lib.mpv_free_node_contents(C.byref(node))

    def command(self, *args):
        argv = (C.c_char_p * (len(args) + 1))(*(arg.encode() for arg in args), None)
        return self.lib.mpv_command(self.handle, argv)

    def close(self):
        self.lib.mpv_terminate_destroy(self.handle)


LUA_PROBE_MARKER = "fushi-lua-probe"


def probe_lua(mpv, seconds=5):
    """Run a real Lua script through load-script and wait for its log line.

    `mpv-configuration` only states the build request, and `load-script`'s
    return code is not proof either (BUG-2032: the Android build accepts the
    command without any Lua backend). Only a log message emitted by the script
    itself proves Lua scripts execute.
    """
    with tempfile.TemporaryDirectory() as temp:
        script = Path(temp) / "fushi_lua_probe.lua"
        script.write_text(f'mp.msg.info("{LUA_PROBE_MARKER} " .. _VERSION)\n', encoding="utf-8")
        mpv.lib.mpv_request_log_messages(mpv.handle, b"info")
        result = {"load_result": mpv.command("load-script", str(script)), "message": None}
        deadline = time.monotonic() + seconds
        while result["message"] is None and time.monotonic() < deadline:
            event = mpv.lib.mpv_wait_event(mpv.handle, 0.1).contents
            if event.event_id != 2:
                continue
            text = C.cast(event.data, C.POINTER(Log)).contents.text.decode("utf-8", "replace")
            if LUA_PROBE_MARKER in text:
                result["message"] = text.strip()
        return result


def loaded_modules():
    """Paths of the shared libraries mapped into this process right now."""
    if sys.platform == "win32":
        kernel32 = C.WinDLL("kernel32", use_last_error=True)
        psapi = C.WinDLL("psapi", use_last_error=True)
        kernel32.GetCurrentProcess.restype = C.c_void_p
        process = kernel32.GetCurrentProcess()
        handles = (C.c_void_p * 4096)()
        needed = C.c_ulong()
        psapi.EnumProcessModules.argtypes = [C.c_void_p, C.c_void_p, C.c_ulong,
                                             C.POINTER(C.c_ulong)]
        if not psapi.EnumProcessModules(process, handles, C.sizeof(handles), C.byref(needed)):
            raise OSError(C.get_last_error(), "EnumProcessModules failed")
        psapi.GetModuleFileNameExW.argtypes = [C.c_void_p, C.c_void_p, C.c_wchar_p, C.c_ulong]
        names = []
        for handle in handles[:needed.value // C.sizeof(C.c_void_p)]:
            buffer = C.create_unicode_buffer(32768)
            if psapi.GetModuleFileNameExW(process, handle, buffer, 32768):
                names.append(buffer.value)
        return names
    if sys.platform == "darwin":
        dyld = C.CDLL(None)
        dyld._dyld_image_count.restype = C.c_uint32
        dyld._dyld_get_image_name.restype = C.c_char_p
        dyld._dyld_get_image_name.argtypes = [C.c_uint32]
        return [dyld._dyld_get_image_name(i).decode("utf-8", "replace")
                for i in range(dyld._dyld_image_count())]
    with open("/proc/self/maps", encoding="utf-8", errors="replace") as maps:
        return sorted({line.split(None, 5)[5].strip() for line in maps
                       if len(line.split(None, 5)) == 6 and "/" in line})


def dvd_capability(protocols):
    """The DVD half of the capability report (see the module docstring).

    libdvdcss is a link-time import of libdvdread, so it is mapped as soon as
    libmpv is; the package renames it (fbddvdcss-2.dll on Windows), hence the
    substring match.
    """
    modules = [Path(name).name for name in loaded_modules()]
    css = sorted(name for name in modules if "dvdcss" in name.lower())
    read = sorted(name for name in modules if "dvdread" in name.lower())
    nav = sorted(name for name in modules if "dvdnav" in name.lower())
    report = {
        "dvd_protocol": "dvd" in protocols,
        "dvdnav_module": nav,
        "dvdread_module": read,
        "dvdcss_module": css,
    }
    report["errors"] = [message for ok, message in (
        (report["dvd_protocol"], "libmpv has no dvd:// protocol (build without -Ddvdnav=enabled)"),
        (bool(nav), "libdvdnav is not loaded with libmpv"),
        (bool(read), "libdvdread is not loaded with libmpv"),
        (bool(css), "libdvdcss is not loaded: libdvdread was not linked --with-libdvdcss "
                    "(encrypted DVDs cannot be read)"),
    ) if not ok]
    return report


def probe_dvd_disc(mpv, disc, seconds):
    """Open a DVD (VIDEO_TS folder or .iso) through dvd:// with menus on and
    report the native logs plus the v2 navigation snapshot (dvd-state)."""
    mpv.lib.mpv_request_log_messages(mpv.handle, b"v")
    target = Path(disc).resolve()
    if target.is_dir() and (target / "VIDEO_TS").is_dir():
        target = target / "VIDEO_TS"
    report = {"load_result": mpv.command("loadfile", "dvd://menu/" + str(target))}
    logs, snapshots = [], []
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        event = mpv.lib.mpv_wait_event(mpv.handle, 0.1).contents
        if event.event_id == 2:
            log = C.cast(event.data, C.POINTER(Log)).contents
            logs.append({"prefix": log.prefix.decode(), "level": log.level.decode(),
                         "text": log.text.decode("utf-8", "replace").strip()})
        state = mpv.get("disc-navigation-state-json")
        if isinstance(state, str) and (not snapshots or snapshots[-1] != state):
            snapshots.append(state)
    report["snapshots"] = [json.loads(s) for s in snapshots]
    report["disc_state"] = {name: mpv.get(name) for name in (
        "disc-menu-active", "edition-list", "duration", "track-list")}
    report["logs"] = logs
    return report


def probe(path, disc=None, seconds=5, dvd=None):
    mpv = Mpv(path)
    try:
        for name, value in (("config", "no"), ("vo", "null"), ("ao", "null"),
                            ("terminal", "no"), ("idle", "yes")):
            if mpv.option(name, value) < 0:
                raise RuntimeError(f"option failed: {name}")
        menu_option = mpv.option("disc-menu", "yes")
        result = mpv.lib.mpv_initialize(mpv.handle)
        if result < 0:
            raise RuntimeError(f"initialize failed: {result}")
        commands = mpv.get("command-list")
        properties = mpv.get("property-list")
        protocols = mpv.get("protocol-list")
        decoders = mpv.get("decoder-list")
        report = {
            "version": mpv.get("mpv-version"),
            "configuration": mpv.get("mpv-configuration"),
            "disc_menu_option_result": menu_option,
            "discnav": [item for item in commands if item.get("name") == "discnav"],
            "disc_menu_active_property": "disc-menu-active" in properties,
            "disc_navigation_state_json_property": "disc-navigation-state-json" in properties,
            "bluray_protocol": "bd" in protocols or "bluray" in protocols,
            "truehd_decoder": any(item.get("codec") == "truehd" for item in decoders),
            "render_api": all(hasattr(mpv.lib, name) for name in (
                "mpv_render_context_create", "mpv_render_context_render",
                "mpv_render_context_set_update_callback", "mpv_render_context_free")),
            "lua_script": probe_lua(mpv),
            "dvd": dvd_capability(protocols),
        }
        if disc:
            mpv.lib.mpv_request_log_messages(mpv.handle, b"v")
            report["load_result"] = mpv.command("loadfile", "bd://menu/" + str(Path(disc).resolve()))
            logs = []
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                event = mpv.lib.mpv_wait_event(mpv.handle, 0.1).contents
                if event.event_id == 2:
                    log = C.cast(event.data, C.POINTER(Log)).contents
                    logs.append({"prefix": log.prefix.decode(), "level": log.level.decode(),
                                 "text": log.text.decode("utf-8", "replace").strip()})
            report["disc_state"] = {name: mpv.get(name) for name in (
                "disc-menu-active", "disc-navigation-state", "disc-navigation-state-json",
                "current-edition", "edition-list", "duration", "track-list")}
            report["logs"] = logs
        if dvd:
            report["dvd_disc"] = probe_dvd_disc(mpv, dvd, seconds)
        return report
    finally:
        mpv.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library")
    parser.add_argument("--disc", help="Blu-ray disc root (bd://menu)")
    parser.add_argument("--dvd", help="DVD VIDEO_TS folder, its parent, or an .iso (dvd://menu)")
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--preload", help="Preload an existing Fushi runtime before the new library")
    args = parser.parse_args()
    preload = preload_runtime(args.preload) if args.preload else []
    report = probe(args.library, args.disc, args.seconds, args.dvd)
    report["preloaded_modules"] = len(preload) - 1 if preload else 0
    print(json.dumps(report, ensure_ascii=False, indent=2))
    for error in report["dvd"]["errors"]:
        print(f"DVD capability missing: {error}", file=sys.stderr)
    return 0 if all((not report["dvd"]["errors"],report["disc_menu_option_result"] == 0, report["discnav"],
                     report["disc_menu_active_property"], report["bluray_protocol"],
                     report["truehd_decoder"], report["render_api"],
                     report["lua_script"]["message"])) else 1


if __name__ == "__main__":
    raise SystemExit(main())
