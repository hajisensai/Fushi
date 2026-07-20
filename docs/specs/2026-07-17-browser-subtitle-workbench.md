# Browser subtitle workbench

## Goal

Bring the high-value subtitle workflow associated with asbplayer into Hibiki's existing browser extension without copying asbplayer source or replacing Hibiki's lookup/mining pipeline. A learner should be able to see an episode subtitle list, load their own subtitle files, navigate and study sentence by sentence, and understand immediately when the local Hibiki service is unavailable.

Reference behavior was reviewed against the official [asbplayer subtitle-loading guide](https://docs.asbplayer.dev/docs/getting-started/loading-subtitles/) and [settings reference](https://docs.asbplayer.dev/docs/reference/settings/). Hibiki keeps its own implementation and visual language.

## Scope

- Keep the universal subtitle list for Netflix, YouTube, HTML5 text tracks, and live DOM subtitle capture.
- Accept multiple user-provided SRT, ASS, SSA, and VTT files from the list action or page drag-and-drop.
- Render only the active external subtitle track over the video; do not duplicate a site's native captions.
- Preserve per-track time offset controls and precise cue lookup/mining windows.
- Add optional list auto-scroll, cue-end auto-pause, and condensed playback that skips long subtitle gaps.
- Expose all subtitle and playback preferences in a dedicated extension options page and the most important status in the action popup.
- Diagnose disabled Hibiki service, invalid token, another service on the port, and the specific Yomitan API default-port conflict.

## Connection contract

The extension probes the configured local endpoint in this order:

1. `POST /api/extension/status` identifies current Hibiki builds.
2. `POST /api/lookup/dictionary` identifies older compatible Hibiki builds.
3. `POST /serverVersion` identifies Yomitan API when it owns the configured port.

The first two Hibiki probes use the configured Basic authentication token. The version probe is used only after Hibiki has not been identified. The browser UI never exposes the token in status responses.

The default-port conflict text directs the user to disable Yomitan's `Enable Yomitan API` option and then enable Hibiki's Yomitan API server. This matches Yomitan API's documented default at `127.0.0.1:19633` in the official [yomitan-api repository](https://github.com/yomidevs/yomitan-api).

## UX behavior

- Automatic Hibiki configuration remains primary. Host, port, and token overrides stay in progressive disclosure.
- Connection state is visible on the options page and action popup with distinct connected, warning, and error treatments.
- Dropping a supported subtitle file automatically enables and opens the subtitle list.
- Unsupported picker files and files above 8 MB produce a local message without creating a track.
- Auto-pause takes precedence over condensed playback when both are enabled.
- All injected video UI is removable during teardown and hidden during capture so it cannot enter generated media.

## Verification

- Node behavior tests cover subtitle loading, drag-and-drop, overlay placement, time offsets, auto-pause, condensed playback, connection classification, and the existing extension behaviors.
- Flutter tests cover the authenticated status endpoint, installation-dialog conflict copy, and byte-identical extension source/assets mirrors.
- Browser verification covers the real options HTML/CSS/JS at desktop and narrow viewport widths, the port-conflict recovery copy, toggle persistence, and the absence of browser console errors.
