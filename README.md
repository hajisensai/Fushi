# vendored-binaries

Anchor commit for the `vendored-binaries` GitHub release of hajisensai/Fushi.

The release assets are the prebuilt third-party binaries (libmpv, ANGLE,
libplacebo, FFmpegKit, LunaHook, jogamp, ...) that the repository no longer
commits. `tool/vendored_binaries.json` in the main history lists path, size,
sha256 and asset URL for each one; `python3 tool/vendored_binaries.py fetch`
restores them.

This tag deliberately points at a parentless commit that contains only this
file, so it never keeps old history (or the old committed binaries) alive.
The release is a prerelease and never Latest; release workflows ignore it
(their `release` triggers only act on v<digit> tags).
