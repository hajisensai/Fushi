# Fushi Linux gamepad startup-crash patch

`linux/gamepads_linux_plugin.cc`: the plugin starts its connection listener on a
detached `std::thread` (`event_loop_start`). Upstream's
`connection_listener::listen` throws `std::runtime_error` when `/dev/input/`
cannot be opened or watched — containers, Flatpak / Snap sandboxes without
device access, users not allowed to read input devices. An exception escaping a
thread entry calls `std::terminate`, so the **entire app aborted at startup**
(`terminate called after throwing an instance of 'std::runtime_error' / what():
Error reading existing connections`, reproduced in a Debian trixie container
running the release bundle). The patch wraps the listener in `try/catch` and
logs `Gamepad support disabled: ...`; the app runs on without gamepads, same as
a machine that simply has none plugged in.

Drop this patch once upstream catches the error (or stops throwing) itself.
