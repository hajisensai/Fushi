"""Probe the actual libmpv binary, without creating a window or changing files.

python tool/bluray/probe_libmpv.py /path/to/libmpv-2.dll [--disc /path/to/disc]
The optional disc probe reports native logs, not an assertion of menu playback.
"""

import argparse
import ctypes as C
import json
import os
from pathlib import Path
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


def probe(path, disc=None, seconds=5):
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
            "disc_menu_option_result": menu_option,
            "discnav": [item for item in commands if item.get("name") == "discnav"],
            "disc_menu_active_property": "disc-menu-active" in properties,
            "disc_navigation_state_json_property": "disc-navigation-state-json" in properties,
            "bluray_protocol": "bd" in protocols or "bluray" in protocols,
            "truehd_decoder": any(item.get("codec") == "truehd" for item in decoders),
            "render_api": all(hasattr(mpv.lib, name) for name in (
                "mpv_render_context_create", "mpv_render_context_render",
                "mpv_render_context_set_update_callback", "mpv_render_context_free")),
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
        return report
    finally:
        mpv.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("library")
    parser.add_argument("--disc")
    parser.add_argument("--seconds", type=float, default=5)
    parser.add_argument("--preload", help="Preload an existing Fushi runtime before the new library")
    args = parser.parse_args()
    preload = preload_runtime(args.preload) if args.preload else []
    report = probe(args.library, args.disc, args.seconds)
    report["preloaded_modules"] = len(preload) - 1 if preload else 0
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 0 if all((report["disc_menu_option_result"] == 0, report["discnav"],
                     report["disc_menu_active_property"], report["bluray_protocol"],
                     report["truehd_decoder"], report["render_api"])) else 1


if __name__ == "__main__":
    raise SystemExit(main())
