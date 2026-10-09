# Galgame 引擎支持矩阵

> 此文件由 `engine-support.yaml` 通过 `tools/generate_engine_support.py` 自动生成，禁止手工编辑。
> 状态基线：2026-07-23；来源：`hajisensai/hibiki/docs/specs/galgame-mining/engine-adapter-plan.md`（1. 当前真相）。
> “已验证”只代表下方明确列出的真实样本、版本和能力，不外推到同家族的其它游戏。

## 总览

| ID | 引擎 / 后端 | 状态 | 文本 | 音频优先级 | 已验证样本 |
|---|---|---|---|---|---|
| `siglus` | SiglusEngine | `verified` | engine_exact_utf16_hook (implemented_unverified)；luna_hook (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | resource_audio (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `elf_ai6` | elf AI6 | `implemented_unverified` | luna_textouta_hook (implemented_unverified) | ai6_voice_arc_resource (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `reallive` | RealLive / old VisualArt's | `implemented_unverified` | luna_hook (implemented_unverified) | reallive_nwk_nwa_resource (implemented_unverified)；visual_arts_ovk_resource (implemented_unverified)；xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `cmvs` | CMVS (Purple Software) | `implemented_unverified` | luna_hook (implemented_unverified) | cmvs_group_loader_voice_ogg_resource (implemented_unverified)；xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `kirikiri_z` | KiriKiri2 / KiriKiriZ | `partial` | luna_auto_or_pc_hooks (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | kirikiri_resource_stream (implemented_unverified)；kirikiri_decoder_pcm (implemented_unverified)；directsound_pcm (verified)；process_loopback (verified) | 2 |
| `xaudio2_directsound` | XAudio2 / DirectSound generic capture | `verified` | — | xaudio2_source_voice_pcm (verified)；directsound_buffer_pcm (verified)；xwma_compressed_resource (implemented_unverified) | 1 |
| `renpy_ffmpeg` | Ren'Py / FFmpeg | `implemented_unverified` | luna_auto_or_pc_hooks (implemented_unverified) | ffmpeg_resource_event (implemented_unverified)；ffmpeg54_decoder_pcm (implemented_unverified)；process_loopback (verified) | 1 |
| `tyrano_nwjs` | TyranoScript / NW.js | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | tyrano_asar_voice_resource (verified)；ffmpeg_resource_event (implemented_unverified)；process_loopback (verified) | 1 |
| `bgi_ethornell` | BGI / Ethornell | `implemented_unverified` | bgi_message_set_text_hook (implemented_unverified)；luna_auto_or_pc_hooks (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | bgi_arc20_voice_resource (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `artemis_pfs` | Artemis Engine / PF8 | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | artemis_pf8_voice_resource (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `catsystem2` | CatSystem2 / KIF INT | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | catsystem2_unencrypted_kif_voice_resource (verified)；directsound_pcm (verified)；process_loopback (verified)；catsystem2_engine_decrypted_voice_resource (implemented_unverified) | 1 |
| `malie_libp` | Malie System / LIBP CFI | `implemented_unverified` | malie_message_segment_hook (implemented_unverified)；luna_auto_or_pc_hooks (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | malie_ogg_decoder_input_voice_resource (implemented_unverified)；directsound_pcm (verified)；process_loopback (verified) | 0 |
| `qlie_filepack` | QLIE / FilePack | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | qlie_wuvorbis_per_source_pcm (verified)；qlie_wuvorbis_float_per_source_pcm (implemented_unverified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `unity_il2cpp` | Unity IL2CPP | `verified` | luna_pc_hooks (verified)；unity_tmp_events (verified)；unity_legacy_text_events (implemented_unverified) | unity_audioclip_resource (verified)；xaudio2_source_voice_pcm (verified)；process_loopback (verified) | 1 |
| `leaf_aquaplus` | Leaf / AQUAPLUS (WHITE ALBUM2 exact profile) | `implemented_unverified` | luna_exact_cp932_thread (implemented_unverified)；ingame_lookup_geometry (implemented_unverified)；ingame_lookup_sampled_input_shield (implemented_unverified) | leaf_lac_voice_resource (implemented_unverified)；directsound_pcm (implemented_unverified) | 0 |
| `hunex_gge` | HUNEX GGE / HFA-HW | `implemented_unverified` | luna_typemoon_dialogue_thread (implemented_unverified) | hunex_hfa_hw_ogg_resource (implemented_unverified) | 0 |
| `smash_fzmedia` | smash / fzmedia (TYPE-MOON smash framework) | `implemented_unverified` | engine_exact_utf16_hook (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | smash_fzmedia_fcd_ogg_resource (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `sgre` | M2 wind3d11 runtime (STEINS;GATE RE:BOOT) | `implemented_unverified` | ingame_lookup_geometry (implemented_unverified)；ingame_lookup_directinput_shield (implemented_unverified) | engine_archive_resource (implemented_unverified) | 0 |
| `unreal_iostore` | Unreal Engine (IoStore) | `implemented_unverified` | luna_pc_hooks (implemented_unverified) | xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `aos_sfa` | AOS / SFA (Princess Sugar, Atelier Kaguya family) | `implemented_unverified` | — | xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `unity_mono` | Unity (Mono runtime) | `implemented_unverified` | luna_hook (implemented_unverified)；unity_mono_managed_text_events (implemented_unverified)；unity_mono_fungus_say_events (implemented_unverified) | unity_audioclip_resource (implemented_unverified)；xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `yuris` | YU-RIS | `implemented_unverified` | yuris_message_text (implemented_unverified)；luna_auto_or_pc_hooks (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | yuris_decoder_input_voice_resource (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `fvp` | FVP (Favorite View Point) | `implemented_unverified` | fvp_text_print_hook (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | fvp_decoder_input_ogg_resource (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `kogado_hy` | Kogado Hy engine | `implemented_unverified` | kogado_hy_message_page_hook (implemented_unverified)；luna_auto_or_pc_hooks (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `luca` | LucaSystem (Prototype) | `implemented_unverified` | luca_message_text (implemented_unverified)；luna_auto_or_pc_hooks (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | luca_voice_pak_member (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |

## 无 OCR 内嵌查词矩阵

> 仅限 Windows x86/x64。OCR 被协议与范围守卫禁止；`xaudio2_directsound` 是通用音频后端，不计作引擎。

| 引擎 | 几何 provider | geometry | verified shield | risky left click |
|---|---|---|---|---|
| `kirikiri_z` | runtime_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `renpy_ffmpeg` | runtime_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `tyrano_nwjs` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `unity_il2cpp` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `elf_ai6` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `reallive` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `bgi_ethornell` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `catsystem2` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `malie_libp` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `qlie_filepack` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `artemis_pfs` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `siglus` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `leaf_aquaplus` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `hunex_gge` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `sgre` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `smash_fzmedia` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `cmvs` | engine_exact_layout | `implemented_unverified` | `implemented_unverified` | `unavailable` |
| `unity_mono` | engine_exact_layout | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `yuris` | engine_exact_layout | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `fvp` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `kogado_hy` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `luca` | engine_exact_layout | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |

证据边界：

- `kirikiri_z` geometry：IPC v19 registry migration and offline adapter/attached-surface tests only; no same-session real-game card E2E is recorded.
  - verified shield：The v19 transaction protocol and standard public input-surface filters exist, but the 1,000-transaction real-build gate has not run.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `renpy_ffmpeg` geometry：IPC v19 registry migration and offline adapter/attached-surface tests only; Ren'Py 8 custom-screen coverage still needs real builds.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `tyrano_nwjs` geometry：The calibrated fallback is implemented offline; a Tyrano DOM runtime-layout provider is not yet admitted.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `unity_il2cpp` geometry：The calibrated fallback is implemented offline; TMP/UGUI source-index and Canvas-transform geometry are not yet admitted.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `elf_ai6` geometry：The calibrated fallback is implemented offline; positioned GDI lineage has not been admitted for this engine.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `reallive` geometry：Engine-exact glyph provider (kLookupGeometryProviderIdReallive). Sites resolve only from structure: the TextRender body (glyph-cache lookup, cache-hit jump, GetGlyphOutlineA rasteriser) and the join both paths reach, where the font-size global and the pen (x, y) become the bitmap origin; the per-pass GetKeyboardState key-table join and its focused-window global; the compositor's call into the generic blitter. LunaHook's RealLive entry patch is never touched. A glyph is visible iff the last blit into the presented 800x600 screen buffer that covered its cell came from its own text surface; at press time its opaque surface pixels must also appear in the presented buffer. The selected LunaHook line must equal the render-order suffix of the visible glyphs. The screen buffer is presented 1:1 at the client origin in windowed and exclusive-fullscreen modes. A claimed press masks VK_LBUTTON in the engine's key table from press to release. Offline: x86/x64 build and fushi_reallive_lookup_test. 2026-09-27 Fushi host on the original launch path, 智代アフター 2005 disc build (RealLive.exe SHA-256 0075C027…364F9A, x86, exclusive fullscreen 800x600, hook DLL SHA-256 5C6FAB28…5DFBA2): sites resolved in 8 ms; model 20 glyphs from 64,484; accept4 on 「いいじゃないか。記念となる日を増やしていこう」 at 285,497 recorded text=PASS, audio=PASS (matched game_resource Z0629.nwk_19.wav), lookup card, no advance on lookup, dismiss and re-lookup, and a real card through the in-game route (noteId 1790508127612 with sentence, audio and image): verdict=full. Runtime corrections found on this build: the Focused() proof calls GetFocus (the engine imports no GetForegroundWindow), and neighbour glyph cells overlap by a few pixels (tighter pen advance than the font size), so only a majority-area overlap starts a new page. The geometry acceptance gate (200 positive probes, 100 stale-generation cases, 3 same-session cards per build) has not run; single RealLive build.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `bgi_ethornell` geometry：Engine-exact message-page provider (kLookupGeometryProviderIdBgi). Sites resolve only from structure (both generations, see text.bgi_message_set_text_hook): SetTextImpl, the Ex vtable, the owner field (+0x20) and the cell-list sentinel (+0x7c) come from the Impl's own instructions; the screen mode index and width/height tables from the `mov eax,[reg*4+W]` / `[W+0x20]` / `mov eax,[W-4]` triple. At SetTextImpl return the detour copies the laid-out cells (0x48-byte records linked at +0x44 from sentinel+0x44; owner-local pen +0x10/+0x14, glyph surface +0x28/+0x2c) because the message object is destroyed after the reveal while the text stays on the owner's layer until the next line. The owner's class is admitted only when its vtable slot 2 decodes as one of the two known drawable predicates (1.5: visible flags +4/+8 and transparency +0x98 < 256; 1.6: +0x20/+0x10 set, +0x18 clear, +0xc4 < 256, +0xc8 > 0) and exactly one vtable function decodes as the display-position composer (sum of pair getters; 1.6's camera term refused while its flag is set). A glyph is offered only when its line has no inline markup, the cell count equals the displayed unit count (an engine-inserted leading quote is a displayed unit outside the published text), the owner is still that class, drawn by the engine's predicate and at the model's display position, and the selected line equals the render-order suffix of the page; only a client with the design aspect is admitted and design pixels are projected to physical client pixels. A claimed WM_LBUTTONDOWN/DBLCLK is swallowed in the main window procedure (found at runtime as the only visible ANSI top-level window of the process whose procedure lies in the game image) together with its WM_LBUTTONUP; the press is refused when a newer line was captured, the owner changed, the host's native-input admission is missing or a card shields the game. 2026-09-30 Frida probes on the 2011 Ethornell 1.519.6 trial (1280x720 design, windowed): cells {16+27i, 12, 29x29} on the owner at 300,560 matched the screenshot glyphs at 316,572; right-click hide and the backlog faded the owner's transparency to 256; a WM_LBUTTONDOWN/UP pair swallowed at the window procedure did not advance while unswallowed clicks did (the per-frame GetAsyncKeyState poll only releases the latch; masking it alone did not stop the advance). The resolver and the owner-ABI decoder were also run offline on a 2016 Ethornell 1.626 trial (not installed, never run). Offline: x86/x64 build and fushi_bgi_lookup_test. 2026-09-30 injector-side on the original trial exe (SHA-256 EEDC03B1...381047538, x86, windowed 1280x720 client, launched by fushi_voice_injector --japanese-locale with hook DLL SHA-256 E673177F...D4C4183): sites resolved in 5.3 ms, window procedure +0x6c2f0 hooked, owner class decoded (3 drawable terms, display slot 11, 3 position terms); a mini host (lookup enabled, NativeOnly admission, BGI exact lane selected) received models of 16/33/36 glyphs (first glyph design 316,572 27x29, second row y 610) and kind 2 id 21 hits (char 4 of a 33-unit line at 424,572; char 32 of a 36-unit line on the second row at 424,610) and the page did not advance; a click off the glyphs advanced; right-click hide and the backlog retired the model (drawable false) and closing them re-offered it. That run drove the window with SendInput clicks from a helper script. 2026-09-30 Fushi host (gal_realgame_driver_itest, rebuilt with the id 21 runner/Dart allowlists) on the original launch path, same exe: the first host run on voiced lines got no_advance=PASS but lookup=FAIL, because the worker resolved a claimed press against the newest model and silently dropped it when the model had been rebuilt in between (the message window fades out and back in around speaker lines), and its diagnostics had exhausted a fixed log budget. Presses now carry their glyph and resolve against the model they were claimed on, are published before any gate of the tick, and every drop is logged. Re-run with hook DLL SHA-256 E12D272D...CC3ABDBF: accept4 on 「放せよっ！」 (char 1 at physical 343,572 27x29, voiced) recorded text=PASS (BGI exact thread), audio=PASS (matched game_resource data04099.arc_aiy710000010.ogg), lookup=PASS, no_advance=PASS, dismiss and re-lookup PASS, and a real card through the in-game route (fake AnkiConnect noteId 1790765888185 with sentence, audio and image): verdict=full. The intermediate build 51322FBD... (same fix, before the published-line history moved into the tested core) recorded verdict=full on 「……される」 (noteId 1790765888183) as well. Release evidence ledger not yet written.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `catsystem2` geometry：Engine-exact message-page provider (kLookupGeometryProviderIdCatSystem2). Sites resolve only from structure: the back-to-back ClearPage/RenderChar pair (record code +4, pen +0x10/+0x14, advance +0x18, font size +0x1c) whose GetCharImage call reaches one rasteriser calling GetGlyphOutlineA (LunaHook's CatSystem2 hook patches that rasteriser entry; it is never touched); the message-window Update whose reveal loop renders through RenderChar and whose SyncLayer hands the page to the screen object at +0x68; the part layer query (layer id +4, screen +0x68; every copy must call the same Screen::QueryLayer) and the scene list layout proven by Screen::QueryLayer, Scene::Visible (list, head +0x14, visible +0xc) and Scene::Find (id +8); and the input handler that owns SetCapture/ReleaseCapture/WindowFromPoint. A glyph is on screen iff RenderChar revealed it on the current page (ClearPage forgets it), its layer node is visible, the unscaled sprite sits at integral design pixels with the page size and box {x-1,y-1,x+w,y+h}, and no later-drawn visible layer box covers its cell (hiding the window or opening the system menu retires the model). The selected LunaHook line must equal the render-order suffix of the visible glyphs of exactly one page. The design back buffer (screen +0x18/+0x1c, mirrored) is stretched over the whole client; only a client with the design aspect is admitted. A claimed WM_LBUTTONDOWN/DBLCLK is swallowed in the engine's own input handler together with its WM_LBUTTONUP (message thread; lparam client pixels mapped to design pixels); the press is refused when anything on screen changed since the model was built. Offline: x86/x64 build and fushi_catsystem2_lookup_test. 2026-09-27 injector-side on the original launch path, the Grisaia no Yuukan build (GrisaiaAno1.exe SHA-256 DB0CD534...39C45A, x86, windowed, 1280x720 design on a 2560x1440 physical client): sites resolved in 16 ms; models of 42/20/69 glyphs, first glyph design 293,591 -> physical 586,1182 52x52; a mini host (lookup enabled, NativeOnly admission, CatSystem2 rasteriser lane selected) received kind 2 id 19 hits (char 2 of a 69-unit line, char 3 of a 40-unit line) and the page did not advance; a click off the glyphs advanced; the system menu retired the model and closing it re-offered. That run drove the covered window with posted mouse messages and a Frida-faked cursor/foreground, so the real-foreground press and the Fushi host accept4 route are not verified yet. 2026-09-28 Fushi host (gal_realgame_driver_itest) on the original launch path, same GrisaiaAno1.exe, windowed 2560x1440 physical client, real foreground SendInput click: with the CatSystem2 rasteriser lane (0x56ab00) selected, accept4 on 「はい、おはよー」 at physical 1304,1590 recorded text=PASS, lookup card, no advance on lookup, dismiss and re-lookup, and a real card through the in-game route (noteId 1790528375095): geometry/claim verified on this build. The same run reported audio=PASS via engine_pcm, which is a false positive: every clip came from one DirectSound buffer in 500 ms streaming slices, and the per-line voice path is off because this build's pcm_*.int archives are encrypted KIF (the adapter rejected encrypted archives). 2026-09-28: the engine-decrypted voice lane (catsystem2_engine_decrypted_voice_resource) now publishes one verified Ogg per voiced page on this build injector-side. 2026-09-28 Fushi host re-run with that lane (hook DLL SHA-256 296194B8…, EmbedCS2 dialogue lane selected: its line precedes the voice by 32-63 ms, while the rasteriser lane can trail it by up to 1.7 s, past the 1.5 s binding window): the session opened in gameResource mode, voiced lines paired as matched/game_resource, and accept4 on 「すみません、唐突に失礼が過ぎましたね。おはようございますみちる様」 at physical 1304,1590 recorded text=PASS, audio=PASS (pcm_e.int_SAC_griani_003_002.ogg), lookup card, no advance on lookup, dismiss and re-lookup, and a real card through the in-game route (noteId 1790534808080 with sentence, audio and image): verdict=full. 2016 targeted-render layout (BUG-2898): RenderChar(renderer, record, target) with GetCharImage behind the font vtable, a non-adjacent ClearPage, the [scene+4] layer list with [node+8] layers and a 6-argument input handler (ret 0x18) resolve through a second structural proof; both renderer pages (+4 and the text-fade work page +0x40) are the text page; the client is measured in the window's own DPI context; a partly covered glyph keeps its whole cell clickable (the message window's menu-bar box overlaps the second row); a spoken line that Luna reports as body + trailing speaker tag matches the page by its body. 2026-10-04 Fushi host on the original launch path (初恋サンカイメ体験版 launcher -> data/cs2.exe, x86, 1280x720 DPI-aware client, HA8:-1C rasteriser lane): accept4 on narration rows 1 and 2, on an unvoiced dialogue line (card written, audio missing: unvoiced) and on 「許してって、一体何を言ってるんだ君は」【少女】 recorded text=PASS, audio=PASS (matched/game_resource E_00_01_004.ogg), lookup card, no advance on lookup, dismiss and re-lookup, and a real card through the in-game route (noteId 1791054570550 with sentence, audio and image): verdict=full; real touch (PT_TOUCH) taps on glyphs, inside the card, outside it and swipes never advanced the line nor took the foreground.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `malie_libp` geometry：Engine-exact RICHTEXT3D message provider (kLookupGeometryProviderIdMalie = 28). Sites resolve only from structure: the RICHTEXT3D class table (UTF-16 class name -> unique word copy -> the method stores of that frame function) and, among its methods, the one draw pass decoded from its own bytes (node+0x1c page data; glyph records +0x84 with stride 0x34 pinned by the U+2015 run compare; count +0x88; texture array +0x8c; reveal range +0xa4/+0xa8; translation floats +0x90..+0x98); the reveal setter must write exactly those data/reveal fields, and the click-unit parser (one caller) must be followed by that reveal setter. The draw detour copies (bounded, render thread, only for the node the latest unit revealed into) the glyph code units and node-local boxes, the translation and the parent world matrix; world = Translate * parent must be an axis-aligned unflipped 2D transform. Design size comes from the engine's ScreenWidth/ScreenHeight globals (the store after the profile read's call). The engine stretches the design back buffer over the whole client (measured 1024x600 design in a 1280x720 window, 1.25 x 1.2); a windowed client of any size is admitted with independent axis scales, a monitor-covering client only with the design aspect. A glyph is offered only when the selected line is exactly the current click unit, every non-space unit character maps to a glyph of the unit's own reveal range (ruby glyphs are skipped), the node was drawn within the last 256 node draws of the engine and the unit is fully revealed. A claimed WM_LBUTTONDOWN/DBLCLK is swallowed with its WM_LBUTTONUP in the window procedure of the child window that covers the main window's client (found at runtime, procedure in the game image; the APP frame only forwards); the press is refused when a newer unit was parsed, the draw is stale, the host's native-input admission is missing, a card shields the game or the window is not foreground. Offline: x86/x64 build and fushi_malie_lookup_test; resolver run offline on the real image and refused on five other-engine x86 executables (CMVS x2, NeXAS x2, FVP). 2026-10-03 Fushi host (gal_realgame_driver_itest) on the original launch path, Dies irae ~Interview with Kaziklu Bey~ (2016, malie.exe SHA-256 7F7506F4D9085B5BF1579F73F913437F0133E85EDFBE403662C08615375BA12E, x86, windowed 1280x720): sites resolved (draw +0x34bad0, parser +0x3872d0, reveal +0x34bf50, click window child procedure +0x1365a0 at client origin 0,0); models of 16/41/60/31/39/20/18 units were built (first glyph 「 at physical 202,75 26x25), the 18-unit ruby line mapped 18 of 29 glyphs. Before the host admitted provider id 28 every claimed press was refused with reason 6 (native input not admitted) and the click advanced the game. 2026-10-03 rerun after the host admitted id 28 (same exe, hook DLL SHA-256 951C3B17...894F1D): accept4 on 「場」 of the voiced line 「つっても場所がら…」 (physical 1618,1025; unit 5 at 327,251 25x25) recorded text=PASS (Malie exact), audio=PASS (matched game_resource 349672484_fushi_textseq10_vir_v_vir0002.ogg), lookup=PASS, no_advance=PASS (mouse only; Windows touch tap, long press, swipe and touch activation not measured), dismiss_no_advance=PASS, relookup_after_dismiss=PASS; card=FAIL because the rebuilt host's isolated data root had no dictionary (the card read 未找到搜索結果, mine added no note). The freshness gate was changed from a 400 ms clock to a draw-count window: the engine redraws only on change and slowly while a card is foreground, which had retired the model between presses. 2026-10-04 second build on the original launch path: キミの花が咲いたら、また僕はキミに出会う 体験版 (malie.exe SHA-256 D53217CD0BEB557D1B82A44A658DB5C63B902D19BFE6448B8CD8319C4B346A3D, x86, windowed 1280x720; hook DLL SHA-256 D5B3BC4C6914C3DFE7A12B5951D91693208663442BC29413F2EEF0BCE8BC6C8F): the same structural resolver found a different site set (draw +0x25a740, parser +0x28f970, reveal +0x25abc0, design globals +0x3e9d0c/+0x3e9d10, click window child procedure +0xf17a0 at client origin 0,0) with the same field offsets; models of 49/65/18/35/10/6 units were built (first glyph at physical 261,565 29x27). accept4 on the voiced line 「……え？」 recorded text=PASS (Malie exact), audio=PASS (matched game_resource 570405046_fushi_textseq36_yuk_v_yuk0001.ogg), lookup=PASS, no_advance=PASS, dismiss_no_advance=PASS, relookup_after_dismiss=PASS and card=PASS through the in-game route (fake AnkiConnect note 1791059190139 with sentence, audio and image): verdict=full. Windows touch (InjectTouchInput PT_TOUCH, same session): a tap on a glyph claimed the press and opened the card with the game staying foreground and the line not advancing; a tap outside the open card closed it without advancing; a re-tap reopened it; a 900 ms long press did not advance. Unvoiced narration lines fall back to loopback by design (segment voice=0). The prefetch reader's partial 8192-byte read of each voice file is logged as 'incomplete, dropped' and the complete file follows (written=1).
  - verified shield：Engine input path: the click is consumed in the game's client window procedure (the engine's input dispatcher receives WM_LBUTTONDOWN/UP there; mouse buttons are not polled for advance, DirectInput is joystick-only). No real-build transaction corpus for the generic shield.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `qlie_filepack` geometry：The calibrated fallback is implemented offline; positioned GDI/DWrite lineage has not been admitted for this engine.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `artemis_pfs` geometry：Engine-exact glyph-node provider (kLookupGeometryProviderIdArtemis). Sites resolve only from structure: a unique Layer::CreateGlyph factory signature whose constructor must carry the glyph vtable, cell-size and multibyte-width proofs; vtable slot 4 must be the per-frame draw forwarder (slot 3 its sibling); a unique Input::Update prologue pins the key-state array and a unique cursor-mapping block pins the HWND and letterbox scale. Any missing/ambiguous proof installs nothing. Visible glyphs are the ones drawn in the last frame; the selected LunaHook line must equal the creation-ordered suffix of those glyphs, and each glyph's world scale must equal the engine root scale 1/k (world units are engine client pixels). 2026-09-27 runtime on アマナツ ～Perfect Edition～ Ver2.0.0 x64 (exe SHA-256 C0C14E52…F37A92E2, same bytes as the trial row) via fushi_voice_injector --launch --hold plus a scratch host emulator (not the Fushi host): sites resolved in 12.5 ms, OfferReady published name+dialogue models (e.g. 14 glyphs, 遥 at 330,490 39x56, dialogue cells 27x41 from 340,552 on a 1280x720 client), a bare left click on 海 published hit kind=2 id=17 char=6 rect=448,552 27x41 and the line did not advance, while a click off the text advanced it. 2026-09-27 Fushi host (gal_realgame_driver_itest, Debug runner with the kind 2 id 17 allowlist, hook DLL SHA-256 799AAC58…2FE8C1) on the original launch path: accept4 at physical (1768,1314) on こがね「よ、よそ者……！」 recorded text=PASS, audio=PASS (matched game_resource 222273750_fem_kog_00019.ogg), lookup card shown, no advance on lookup, dismiss and re-lookup, and a real card through the in-game route (noteId 1790491970749 with sentence, audio and image): verdict=full. A second accept4 on an unvoiced narration line passed lookup and no-advance. The geometry acceptance gate (200 positive probes, 100 stale-generation cases, 3 same-session cards per build) has not run.
  - verified shield：A claimed glyph press is masked in the engine's own per-frame key-state array (Input::Update, left button) from press through release, so neither edge reaches the script; a masked click was measured not to advance. Dismiss clicks while a card is shown rely on the generic GetAsyncKeyState shield (the engine polls all 256 keys through GetAsyncKeyState; its per-key message queue stayed empty for mouse clicks). No real-build transaction corpus has run.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract. The exact provider consumes a press only under NativeInputAllowed, with no card/shield active, the game in the foreground and the cursor on exactly one mapped glyph; no measured real-build click-leak rate is recorded.
- `siglus` geometry：LunaScenario and NativeEcxTextUnion are independently resolved x86 ABI families. Each requires its own hydrated-image glyph/text/input signatures and corroborating call relationships; exactly one complete family proof must succeed. The Siglus-only loaded-image view opts into VirtualSize section extents, with complete image bounds, executable-section readability and section-overlap rejection, so a protected executable's larger on-disk raw payload is not mistaken for mapped code; other adapters retain the default extent policy. Known executable hashes only check resolved-anchor consistency and cannot admit either family directly. NativeEcxTextUnion resolves the sampled-key slot from an independent key loop and compares its target exactly with the named user32!GetKeyState export. Each family has independent renderer-size and window-normalization chains that must identify one Gameexe configuration slot; its live design dimensions are read and validated. Missing, ambiguous or incompatible anchors, two matching families and invalid design dimensions fail closed; cross-build original-path lookup/card E2E is not recorded.
  - verified shield：Exact and generic shield code exists, but the 1,000-transaction real-build gate has not run.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `leaf_aquaplus` geometry：The portable exact SHA-256 identity is followed by hydrated-image, all-executable-section unique masked signatures, module-relative relocated-operand checks, callgraph gates and a D3D9 ABI gate. Zero/multiple candidates and unknown hashes fail closed; lookup/card E2E is not recorded.
  - verified shield：Exact and generic shield code exists, but the 1,000-transaction real-build gate has not run.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `hunex_gge` geometry：The calibrated fallback and a fail-closed exact provider are implemented. The HUNEX hydrated-image scanner requires unique executable-section renderer/input/projection anchors plus callgraph, unwind and imported-API validation before it can publish geometry. The original WoH session has not yet produced a complete glyph-to-client projection or lookup/card E2E. The engine_exact_layout entry above is a deliberate 2026-08-31 graduation from observation-only; only the geometry provider layer graduated, and the resource-capture and pairing gates stay not_verified.
  - verified shield：Generic shielding plus HUNEX semantic-submit ownership are implemented, but the real-build click, Shift and popup transaction gates have not run.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate); fail-closed native-input admission is implemented; no measured real-build click-leak rate is recorded.
- `sgre` geometry：The measured SHA-256 row is a consistency check only. Known and unknown hashes traverse populated, mutually corroborated draw/vtable/DirectInput signatures across all executable sections, PE exception-directory function bounds, decoded module-relative targets and live vtable/COM ABI gates. Zero/multiple intersections, layout/codegen mismatches and structure faults fail closed. 2026-09-03 original-path E2E on the measured Steam x64 build (SHA-256 75A83A0E…C404B9D8, Fushi 2.2.4-debug.13075 launching sgre_steam.exe, injected helper, IPC v21): hover+Shift lookups (いて/サイ) and a bare left click on 話 each published a hit, presented the direct galCard inside the game and the game line did not advance; one word card was written (Sentence エル・プ<b>サイ</b>・コングルゥ, 3.19 s paired xWMA voice re-encoded to AAC, 480×270 AVIF animation). Evidence grade for the audio stops at captured: neither a byte-hash comparison against the source voice_body.bin entry nor a pure-voice classification was recorded, so hash_verified and voice_classified are NOT claimed and the run does not satisfy the per-sentence original-resource claim in full. Only this one build is covered.
  - verified shield：Exact DirectInput and generic shield code exists, but the 1,000-transaction real-build gate has not run.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate). 2026-09-03 measurement, taken while that gate still existed: 8 popup-outside quick clicks (60 ms down/up) after Shift or click lookups, 7 were swallowed by the WH_MOUSE_LL + DirectInput shield pair with no line advance; the first click right after the mid-session risk acceptance (needsRiskAcceptance → activeNative) leaked and advanced the line once, and the leak did not reproduce on a fresh session whose acceptance was restored from memory. That one leak sat on the acceptance transition itself, which no longer happens; the shield pair it measured is unchanged. Too few transactions for a rate; the 1,000-transaction gate has not run.
- `smash_fzmedia` geometry：The calibrated fallback and a fail-closed exact provider are implemented. Glyph cells come from the KAG TextLayerBase::layoutChar detour in layer units; they are projected with the uniform 1920x1080 stage fit plus a host-solved layer origin (PublishLookupLayerLine / ReadLookupLayerOrigin). Readiness requires a solved origin for the current client size and every inked cell inside the client rect (8 px tolerance); no real-session hit, lookup or card E2E is recorded.
  - verified shield：Generic shielding plus a GWLP_WNDPROC subclass of the GLFW30 game window (bare left down/up on a glyph consumed and queued as Submit; every client-area left down/up swallowed while a card is published or a v19 transaction targets the window; Shift-move hover never consumed) are implemented, but the real-build click, Shift and popup transaction gates have not run. XInput / joystick input has no shield.
  - risky left click：Per-executable risk gating and fail-closed native-input admission are implemented; no measured real-build click-leak rate is recorded.
- `cmvs` geometry：ChronoClock trial v2 x64 exact-hash frame observer, bounded live glyph/sprite reader, selected EmbedCMVS lane identity, and explicit presentation rectangles. Real card and input shielding E2E remain unverified.
  - verified shield：Reuses the generic public input surface transaction protocol; no CMVS popup/input transaction corpus has passed.
  - risky left click：This CMVS sensor implements Shift lookup only; it does not intercept bare left clicks.
- `unity_mono` geometry：Engine-exact per-glyph message provider (kLookupGeometryProviderIdUnityMono) for the Unity Mono per-glyph TextMesh message framework the Mono text path already admits structurally (instance `string Message.Mes(string,bool)` + static 8-parameter `Game.NewText(..., string @3, ...)` in Assembly-CSharp). Sites resolve only through the Mono embedding API: Message.FixedUpdate (instance, void, no parameters), Message.messageSprite proven to be List<List<UnityEngine.GameObject>> (both List`1 levels share one `_items`/`_size` layout; the inner element class is the engine's GameObject), Message.LastMes (string), UnityEngine.Object.m_CachedPtr (native peer), and 14 engine bindings matched by name + instance/static + return + parameter types + by-ref-ness + the internal-call flag and taken from mono_lookup_internal_call (Camera.main / WorldToScreenPoint_Injected / cullingMask / targetTexture / orthographic, Screen.width/height, GameObject.activeInHierarchy / GetComponent(Type) / layer / get_scene_Injected, SceneManager.GetActiveScene_Injected, Renderer.get_bounds_Injected / enabled); a missing or duplicated piece installs nothing (pre-2018 players without `_Injected` bindings are rejected). After the framework's FixedUpdate the main thread samples every glyph object (alive native peer, active in hierarchy, renderer enabled, layer inside Camera.main's culling mask, scene == active scene so an additive overlay scene retires it, camera renders to the screen) and projects the renderer's world AABB with Camera.main.WorldToScreenPoint (orthographic cameras may use a negative near plane, so depth is only required for perspective cameras). The selected line must equal Message.LastMes of exactly one fresh instance and every '\n'-terminated line of it must have exactly as many glyph objects as UTF-16 units. Unity's screen grid must equal the client in the window's own DPI context; cells are scaled to physical client pixels. A claimed WM_LBUTTONDOWN/DBLCLK is swallowed with its WM_LBUTTONUP in a GWLP_WNDPROC subclass of the UnityWndClass window (Unity's legacy input takes mouse buttons from the window procedure: a swallowed pair keeps Input.GetMouseButtonDown(0) false), only with the host's NativeInputAllowed admission, no card/shield, the game in the foreground, no modifier, and nothing re-sampled since the model. The Mes text lane now carries a role key (hash of the object's scene name via Object.GetName) so the body and the speaker name plate, two objects of the same class written body-then-name for every spoken line, no longer share one lane whose latest line was always the speaker name. Offline: x86/x64 build and fushi_unity_mono_lookup_test. 2026-09-27 injector-side on the original launch path, the デスマッチラブコメ！ Steam build (DMLC.exe SHA-256 35416BAD...8B5B2D, x86, Unity 2019.2.15, MonoBleedingEdge, per-monitor DPI aware, 1280x720 client at 192 dpi): sites resolved (sprite +12, LastMes +28, List `_items` +8 / `_size` +12, m_CachedPtr +8); models followed the typing reveal (60 of 65 units, first glyph 266,56 36x51); a mini host (lookup enabled, NativeOnly admission, the body Message.Mes lane selected) received kind 2 id 20 hits from real foreground SendInput clicks (char 19 of a 65-unit narration page, char 8 of a 33-unit spoken line with a separate name-plate lane) and the page did not advance; a click off the glyphs advanced; the backlog overlay retired the model and closing it re-offered; the body and name-plate lanes kept their thread ids across a return to title + reload (new Message objects) and across a process restart. Visual occlusion by same-scene sprites (e.g. a modal confirm dialog dimming the message box) is not modelled; only an overlay scene or a hidden message object retires the model. 2026-09-28 Fushi host on the original launch path (DMLC.exe, windowed 1280x720, real foreground SendInput click, Message.Mes body lane selected): accept4 on the two-line narration 「我跟同班同学的身体，…四分五裂——」 at physical 1599,1253 recorded text=PASS, lookup card, no advance on lookup, dismiss and re-lookup, and a real card through the in-game route (noteId 1790528375097). Audio is not measurable on this sample (no voice). A first attempt failed only because the game was not the foreground window when the click landed (host status targetBackground, nativeInputAllowed=false), which is the intended gate. 2026-09-28 framework 2 on the same provider id: Fungus (public Unity VN framework, namespace `Fungus`) SayDialog on a UGUI Text. Admitted only when the text path resolved `IEnumerator Fungus.SayDialog.DoSay(string, bool x5, AudioClip, Action)` exactly and uniquely across images; sites: SayDialog.LateUpdate (instance, void, no parameters), SayDialog.storyText typed UnityEngine.UI.Text, Text.m_Text / m_TextCache (TextGenerator) / m_FontData.m_Font, Graphic.m_Canvas / m_CanvasRenderer / m_Color.a, TextGenerator.m_LastString / m_Characters (List<UICharInfo>) / m_Lines (List<UILineInfo>) with value strides from mono_class_value_size, UnityEngine.Object.m_CachedPtr, and 17 internal calls (Component.gameObject/transform, Behaviour.isActiveAndEnabled, Transform.get_localToWorldMatrix_Injected, Canvas.rootCanvas/renderMode/scaleFactor/worldCamera, CanvasRenderer.GetInheritedAlpha/cull, Font.dynamic, TextGenerator.GetCharactersInternal/GetLinesInternal, Camera.WorldToScreenPoint_Injected/targetTexture, Screen.width/height). After SayDialog.LateUpdate the main thread samples the story Text only when the generator laid out exactly the string it shows (m_LastString == m_Text), fills the generator's own character/line lists, requires one UICharInfo per raw UTF-16 unit + terminator, strips `<...>` like the text lane and hides glyphs inside an alpha-0 <color> span (the Writer's read-ahead), projects [cursor.x, +charWidth] x [lineTop-height, lineTop] / pixelsPerUnit through localToWorld and the root canvas (identity for Screen Space-Overlay, worldCamera.WorldToScreenPoint for Screen Space-Camera; World Space refused; dynamic fonts only) and requires the text active+enabled, not culled, inherited CanvasGroup alpha and colour alpha >= 0.5. The selected line (the DoSay lane: Fungus `{...}` tags stripped) must equal the stripped rendered text; each glyph carries its text index. The window-procedure claim is shared with framework 1 (Unity's Input System package also takes mouse buttons from the window procedure: with WM_LBUTTONDOWN/UP swallowed a real SendInput click did not advance a Fungus line, without it the same click did). Offline: x86/x64 build, fushi_unity_mono_lookup_test (Fungus site resolution with every fail-closed branch, rich text, geometry). 2026-09-28 injector-side on the original launch path of センチメンタルデスループ Steam (Sentimental Death Loop.exe SHA-256 34D59C4A...219629, x64, Unity 2021.3.10f1 MonoBleedingEdge, Fungus.dll, own windowed 1280x720 client at 192 dpi): sites resolved (story +64, m_Text +200, m_TextCache +208, m_Canvas +48, m_CanvasRenderer +40, color.a +116, UICharInfo stride 12, UILineInfo stride 16); models followed the reveal (18 -> 28 of 30 units, first glyph 330,579 24x35); a mini host (lookup enabled, NativeOnly admission, DoSay lane selected) received a kind 2 id 20 hit from a real foreground SendInput click on the second glyph (char 1 of 30, rect 354,579 25x35) and the line did not advance; a click off the glyphs advanced to the next line. Measured before the change with Frida: glyph cells from this projection overlay the rendered glyphs to the pixel. Not modelled: a game's own overlay in the same scene over the dialog (this title's Back Log dims but does not hide the dialog; its glyph positions stay claimable while it is open). 2026-09-28 Fushi host on the original launch path with the 67b8fd3dc51 build (x64 hook DLL SHA-256 9046DBE0…, unity_audio_runtime present): Sentimental Death Loop (Unity 2021.3 x64 Mono, Fungus, windowed 1280x720), Unity Mono Fungus Say lane selected, session in gameResource mode, accept4 on 「さっきから何回目の休憩だと思ってるの。⏎まったく。そんなことじゃ私はもう手伝うのやめる。」 at physical 1646,1338 recorded text=PASS, audio=PASS (matched game_resource sce_0006.wav), lookup card, no advance on lookup, dismiss and re-lookup, and a real card through the in-game route (noteId 1790549375831): verdict=full. Regression on the DMLC framework (x86) with the same build: text, lookup, no advance, dismiss/re-lookup and a real card PASS (noteId 1790549375833); audio not measurable (no voice on that sample).
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：The left-click claim is gated on the host's NativeInputAllowed admission; no measured real-build click-leak rate is recorded.
- `yuris` geometry：Engine-exact message-layer provider (kLookupGeometryProviderIdYuris, 22). Every site resolves from the executable's own code as laid out on disk (other in-process hookers such as LunaHook's YU-RIS hooks patch the rasteriser's TextOutA call in the live image; the two hook targets must still be byte-identical live): DRAW is the call target shared by the engine's typing sites `call DRAW; mov edx,[S]; add [edx+X],eax` whose first bytes call a rasteriser holding `call [TextOutA]`; the message state global S, the pen field X, the message text pointer T and text index TI, the per-op font size array and op index come from those sites' own argument setup and pen/text-index updates (every site must agree); DRAW's stack-argument ABI (font size, pen x/y, target layer) from the stores that follow the size and pen loads. Every DRAW call (the engine typewriter and the script-level string command alike) records layer, pen, font size and character; a change of the engine message text S+T opens a page and is the text lane. A layer's design position is the sum of its sprite positions up the parent chain, exactly as the engine's own sprite hit test walks it (`mov S,[N+sprite]; [S+x] .. [S+y]; mov N,[N+parent]; test; je; cmp [N+live],0; jne`, unique); the design screen and the main HWND come from the window record the cursor mapping reads (`mov r,[table..]; push [r+hwnd]; call [ScreenToClient]` followed by the design bounds check). A draw of the same character within 2 px of an earlier one on the same layer (shadow pass, then face) replaces it. The selected line must be the render-order suffix of exactly one layer's glyphs; a client with another aspect than the design screen is refused. The click claim masks VK_LBUTTON's high bit in the engine's GetKeyboardState table (`push K; call [GetKeyboardState]`) at the head of its per-frame mouse-button loop (`mov ebx,1; movzx edx,byte[ebx+K]; sar edx,7; ... cmp ebx,7`, unique, over the same K) from press to release; the press is refused when a newer glyph was drawn, the layer moved, the host's native-input admission is missing or a card shields the game. Offline: x86/x64 build and fushi_yuris_adapter_test; the resolvers accept the 2011 euphoria (v500) and 2016 アイカギ (v481) executables and reject 39 x86 executables of seven other engines. 2026-10-03 Fushi host (gal_realgame_driver_itest, provider ids 22-28 admitted, dictionaries installed) on both original launch paths, DPI-unaware windows stretched 2x: euphoria (euphoria.exe SHA-256 d30b992f...184d, 800x600 design on a 1600x1200 physical client) accept4 #16 on 「恵ちゃん、大丈夫？」 (大, char 6 at physical 332,968 42x40) recorded text=PASS (YU-RIS exact lane), audio=PASS (game_resource 356654437_fushi_textseq239_kan_m01_0073.ogg, paired by text event id), lookup, no_advance, dismiss_no_advance, relookup and a real card (fake AnkiConnect noteId 1791002595603 with sentence, audio and image): verdict=full; アイカギ (アイカギ.exe SHA-256 907cecc1...a851, loose Chinese-patch directories moved aside, 1024x768 design on 2048x1536) accept4 #34 on 「ぁあっ……中でまた大きくっ……」 (中, char 6 at physical 658,1360 50x48) recorded the same seven PASS (game_resource 358129265_fushi_textseq37_shi_01_comn_04_0003.ogg, noteId 1791002595605): verdict=full. Touch (InjectTouchInput PT_TOUCH, euphoria): a tap is promoted to a sub-frame DOWN/UP the engine's key table never shows (an unclaimed tap neither advances nor opens anything), so promoted touch presses (extra info 0xFF5157xx) are claimed at the main window procedure: tap on a glyph opened the card without advancing; tap and vertical swipe inside the card, then tap outside, closed it without advancing; horizontal swipe on the card closed it without advancing; long press (0.9 s) with no card changed nothing; a swipe on the game with no card advanced, as a mouse drag does; the game stayed foreground throughout. On アイカギ a touch tap on a glyph opened the card without advancing; a later touch outside the game left the host's FushiFloatingLyricWindow in the foreground (host-side). The host's FushiFloatingLyricWindow (topmost) swallows game clicks under it; the アイカギ window was moved clear of it for the runs.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：The left-click claim masks VK_LBUTTON in the engine's own GetKeyboardState table before its per-frame mouse-button loop and is gated on the host's NativeInputAllowed admission; no measured real-build click-leak rate is recorded.
- `fvp` geometry：Engine-exact text-buffer provider (kLookupGeometryProviderIdFvp). Sites resolve only from structure (fvp_lookup_core.h ResolveSites): the syscall registration blocks of `TextPrint` (argc 2) and `PrimSetText` (argc 4) calling one registration function give their handlers; the TextPrint handler's bounded buffer load (`cmp eax,0x1f` + `mov edx,[G]; mov ebp,[edx+eax*4+A]`), length bound (`cmp eax,0x200`) and `push esi; mov ecx,ebp; call` give the VM global, the text-buffer array and the text object's Print; Print's `push 1/0/0; call` gives the layout whose repeated callee with the PutGlyph prologue gives the pen x/y and glyph-advance fields and the base-glyph ruby rule (format+2 size, +4 ruby size, +0x14 == 2, +0x24 gap); PrimSetText's `mov [eax+K],dx` gives the prim's buffer-index field, and the render walk's text case using that same field, VM global and array gives DrawSprite and the drawn surface offset; DrawSprite's own translation, scale-identity (1000), rotation, UV/WH/3D flag and alpha code, and its 3D-centre load of the design size, are all required. At Print return the detour has the glyph records PutGlyph saw (pen before each glyph); a print is mapped only when the records pair one-to-one with its displayed units (`[ruby|base]` ruby glyphs flagged), and a glyph is offered only while the text object is still the buffer's object with an unmoved pen and its surface was drawn within the engine's recent draw count (clamp(2 x the observed draw period, 64, 1024) draws, no wall clock) as a plain visible translation (no rotation/scale/UV/WH/3D, alpha > 0, zero surface origin); design pixels = draw origin (ox + prim.x, oy + prim.y) + glyph cell, projected to physical client pixels under the design aspect. A claimed WM_LBUTTONDOWN/DBLCLK is swallowed with its WM_LBUTTONUP in the main window procedure (the only visible ANSI top-level window whose procedure lies in the game image); refused when the same buffer printed again, the text object or draw origin changed, the host's native-input admission is missing or a card shields the game. Offline: resolver on the 2011 World.exe and the 2019 HoshimemoEH_HD.exe (原版备份) both resolve the same field offsets; nine other-engine executables (CMVS, Malie, YU-RIS x2, Softpal, QLIE, the FVP disc launcher and a Chinese-patch launcher) refuse at the registration step; fushi_fvp_lookup_test. One Fushi-host accept4 run is recorded (gal_realgame_driver_itest, いろとりどりのセカイ World.exe, x86, 1024x640, commit c9fb999a06): text, audio, lookup, no advance on lookup (mouse only; touch not measured), dismiss and re-lookup PASS (before the 2026-10-03 rework of the freshness gate, voice gating and window rebinding, which has not been re-run on the device); card=FAIL because the host had no dictionary installed at the time (to be re-run). The geometry acceptance gate has not run; single host sample.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `kogado_hy` geometry：Engine-exact message-window provider (kLookupGeometryProviderIdKogadoHy, 24). Sites resolve only from structure (kogado_hy_core.h ResolveLookupSites): the row renderer of the text lane gives the row pitch (`shl r,imm8; lea r,[r+r*s]`), the row band (`push WIDTH; push HEIGHT` before THyAlpha::Draw) and, at every row-array call site that shows a row, the row array's panel (`mov eax,[ebx+P]; call THyRGBPanel::SetModify`); the exported THyRGBPanel::ClientToScreen gives the panel's x/y/parent fields and THyRGBPanel::SetVisible its shown flag. A CP932 byte is half the row height wide (MS Gothic). The glyphs of the published click unit are placed at the panel chain's live origin (every panel of the chain shown) plus (byte * width, row * pitch), the same skips as the text lane (speaker row, quote indent), and projected to physical client pixels under the design aspect (the window's logical client is the design screen). The engine reads clicks only as window messages (a press swallowed in the game window's procedure does not advance; no key-state polling): a claimed WM_LBUTTONDOWN/DBLCLK is swallowed with its WM_LBUTTONUP in the game window's procedure (replaced for each bound window, chained with CallWindowProc and restored at shutdown while still the head of the chain; the window thread is not the script thread that renders the rows; the window is the only visible non-child top-level window whose class the game image registered), for mouse and promoted touch alike; refused when the unit or its last row changed, the panel moved or hid, the client size changed, the host's native-input admission is missing, a card shields the game or the game is not foreground. Offline: resolver on the 2004 Symphonic Rain SR.exe (row 24/520x20, panel fields 0x70/0x74/0x38/0x31, arrays 0x118->0x60 and 0x248->0xb4); fushi_kogado_hy_adapter_test. Fushi host run 2026-10-04 (local build of this branch, original launch path: SR.exe SHA-256 04b4c08b...ce4c started from the workbench under Locale Emulator, DPI-unaware 640x480 window stretched to a 1120x840 client): mouse click on a glyph opened the card for the clicked word in the adventure window (row 1 and row 2) and in the full-screen window (row 3), without advancing; a click outside closed the card without advancing; with no card a click advanced. Touch (InjectTouchInput PT_TOUCH): a tap on a glyph opened the card without advancing; a tap inside the card (nested lookup) then outside closed both without advancing; a horizontal swipe on the card closed it without advancing; with no card a swipe advanced and a 0.9 s long press opened the game's right-click menu, as the mouse does; the game window stayed foreground throughout. No card was written (no fake AnkiConnect run); not an accept4 run; single sample.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate); no measured real-build click-leak rate is recorded.
- `luca` geometry：Engine-exact text-object provider (kLookupGeometryProviderIdLuca, 25). The text object's layout routine is resolved from the loaded image (prologue shape plus a four-block row reset at stride 0x5A, unique) and cross-checked by the fields its body reads (row capacity, origin x/y, row count, row ring, row head); it is detoured only to learn live text objects. The worker reads each known object's row ring (glyph records: unit, x, width, height; row y offset) and accepts the line only when exactly one object's records spell the selected line unit by unit; positions are design space from system.cnf SCREEN_WIDTH/HEIGHT (1280x720) projected aspect-fit to physical client pixels. The click claim runs in the generic GetAsyncKeyState detour for calls from the main image only: a fresh VK_LBUTTON press on a glyph of the offered line (host native-input admission present, no card shield, game foreground, no modifiers) is claimed and masked (0x8000|0x0001) until release. Offline: x86/x64 build and fushi_luca_adapter_test (synthetic records, projection, hit test, claim state). Live layout dump 2026-10-09: the dialogue text object holds the current line's glyph records at origin (190,576). Fushi host run 2026-10-09 (local build of this branch, original Steam launch path, 1280x720 design on a 2240x1260 physical client): one session published 28 lookup hits (15 claimed clicks, 13 Shift presses), each opening the card for the word under the cursor; per the user, a click on a glyph did not advance, a click outside closed the card without advancing, a click with no card advanced, the touch checklist (tap on a glyph, tap inside then outside the card, swipe on the card) showed no problem, and a real card was written with the line's sentence and voice. The hook log cannot tell mouse from touch input or observe advancement, so the no-advance and touch results rest on the user's report; not an accept4 run; single sample. Win64 implementation 2026-10-10: a separate unique four-subobject reset site plus model-field/row-accessor ABI cross-checks resolve the text-object drawing contract. A worker reads the 64-bit row ring and glyph records, normalizes actual per-row origins, and uses adjacent engine screen-dimension globals located through the same drawing code. Synthetic positive/negative resolver, relocation, row alignment, ABI mismatch and invalid-coordinate tests pass on x86 and x64; a read-only normally launched x64 process resolved exactly one site and valid engine dimensions. No x64 actual lookup/click/no-advance/touch/card E2E has been proved; status remains implemented_unverified.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate); no measured real-build click-leak rate is recorded.

## 识别与能力明细

### SiglusEngine (`siglus`)

- 状态：`verified`
- 别名：Siglus 3、VisualArt's Siglus
- 家族：`visualarts`（VisualArt's / Key 系引擎）
- 当前 adapter：`hook/adapters/siglus_adapter.inc`
- 进程策略：launch=`normal_launch_then_delayed_attach_after_game_window`，attach=`supported`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：SiglusEngine.exe；证据：real_sample — anemoi 正式版与 Summer Pockets Reflection Blue 原始安装样本（2026-07-19 / 2026-08-27）
- `pe_architectures`：x86；证据：real_sample — anemoi SiglusEngine 1.1.141.3 与 Summer Pockets Reflection Blue SiglusEngine 1.1.134.0 均为 x86
- `directory_files_all`：Gameexe.dat、Scene.pck；证据：real_sample — renamed Siglus executable regression fixed by hibiki-hook d1601b9
- `runtime_modules`：dsound.dll；证据：runtime_observation — anemoi used DirectSound through CoCreateInstance
- `resource_extensions`：.ovk；证据：real_sample — anemoi koe/*.ovk entries exported byte-identically
- `hashes`：algorithm=sha256, scope=game_executable, value=D94C94EB132FB1FCD6C20F35DD16552ED1301708B7A83DE07B275AD26C97D059, version=1.1.141.3、algorithm=sha256, scope=game_executable, value=190DF9A72929BD6B6327E773952B5C507C69052BC6D3FF16A4868BD1FF1791FD, version=1.1.134.0；证据：real_sample — anemoi 正式版（2026-07-19）与 Summer Pockets Reflection Blue 原始 SiglusEngine.exe 身份固定（2026-08-27）

文本能力：

- `engine_exact_utf16_hook`：`implemented_unverified` — The NativeEcxTextUnion x86 family structurally resolves its exact-text entry, dialogue caller, renderer and input anchors independently of LunaScenario. Anemoi's recorded hash is only an anchor-consistency check and no longer admits the lookup profile directly. The two families cannot borrow each other's partial matches; exactly one complete ABI proof must succeed. Cross-build original-path exact-text/lookup/card verification is not recorded, so the capability remains implemented_unverified.
- `luna_hook`：`implemented_unverified` — The LunaScenario x86 lookup family consumes the Luna scenario-text lane associated with structurally resolved text and caller anchors. Its independent renderer/input signatures and call relationships must form a complete proof, with no simultaneous NativeEcxTextUnion family match. A known executable hash is not required; recorded hashes only corroborate resolved anchors. Cross-build original-path text/lookup/card verification is not recorded.
- `ingame_lookup_geometry`：`implemented_unverified` — Two independent x86 ABI resolvers cover LunaScenario and NativeEcxTextUnion instruction/layout contracts. A Siglus-only opt-in loaded-image view uses VirtualSize rather than the maximum of raw and virtual section sizes, validates complete image bounds and executable-section readability, and rejects overlapping sections without truncating malformed ranges; the shared default extent policy remains unchanged. Each resolver finds unique glyph, text, dialogue/input-caller and input-message anchors across those hydrated executable sections and validates their call relationships; exactly one complete family proof must succeed. LunaScenario validates the named GetKeyState import, while NativeEcxTextUnion independently resolves the sampled-key slot from its key loop and requires its live target to equal the actual named user32!GetKeyState export. Each family uses its own renderer-size and window-normalization signatures to corroborate one readable/writable Gameexe configuration slot; live design width/height at +0x7c/+0x80 are range-checked and revalidated before lookup installation. Known Anemoi and Summer Pockets Reflection Blue hashes only check anchor consistency, never substitute for structural admission. Missing/ambiguous anchors, broken relationships, unsupported or simultaneously matching ABIs and invalid/changed dimensions fail closed. Cross-build original-path lookup/card E2E is not recorded, so the capability remains implemented_unverified.
- codepage：utf-16le for the exact engine path
- 线程提示：Prefer the engine exact-text source when observed; otherwise select the stable Luna dialogue thread.

音频优先级：

1. `resource_audio` — `verified`；格式：Ogg/Vorbis entries in koe/*.ovk；clean voice：是
2. `directsound_pcm` — `verified`；格式：44100 Hz / stereo / signed 16-bit in the verified sample；clean voice：engine_dependent
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **anemoi 正式版**（x86，SiglusEngine 1.1.141.3，2026-07-19）：Two OVK voice entries were exported byte-identically; delayed launch/attach and DirectSound PCM were exercised on the original path. SHA-256：D94C94EB132FB1FCD6C20F35DD16552ED1301708B7A83DE07B275AD26C97D059。

已知限制：

- Verification is specific to the recorded x86 sample and OVK layout.
- Late attach may miss the DirectSound format; raw OVK voice remains the preferred path.
- The exact-text hook is implemented but is not promoted to verified by this baseline.
- Engine-family lookup admission is limited to the structurally recognized LunaScenario and NativeEcxTextUnion x86 ABIs. Unknown and known hashes traverse independent complete family proofs; neither scan order nor a measured hash can choose between two matching families. Unsupported code generation, ambiguous anchors, invalid GetKeyState identity and unavailable or changed Gameexe design dimensions reject lookup. This is implemented_unverified and does not establish support for every Siglus build or x64.
- Recorded Anemoi and Summer Pockets Reflection Blue identities remain consistency evidence for resolved anchors, not lookup-admission shortcuts. Structural family admission, dynamic design-size parsing and input ownership still require original-path lookup and same-session card-mining E2E before any support promotion. This change records no results from localized or modified Summer Pockets Reflection Blue builds.

Fixtures：尚无（P5 补齐）

Tests：`tests/siglus_ovk_test.cpp`、`tests/siglus_launch_test.cpp`、`tests/siglus_text_test.cpp`、`tests/siglus_lookup_test.cpp`、`tests/siglus_autoprofile_test.cpp`、`tests/siglus_viewport_test.cpp`、`tests/siglus_native_autoprofile_test.cpp`、`tests/siglus_native_viewport_test.cpp`、`tests/siglus_loaded_image_test.cpp`、`tests/exact_lookup_signature_test.cpp`、`tests/adapter_structure_test.py`

### elf AI6 (`elf_ai6`)

- 状态：`implemented_unverified`
- 别名：AI6WIN、elf AI6
- 家族：`elf`（elf AI6 archive-based engine）
- 当前 adapter：`hook/adapters/elf_ai6_adapter.inc`
- 进程策略：launch=`unverified`，attach=`unverified`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：


文本能力：

- `luna_textouta_hook`：`implemented_unverified` — Candidate Luna TextOutA route; original AI6 thread selection is not verified.
- codepage：CP932
- 线程提示：Select the stable TextOutA dialogue thread and reject title/menu rendering threads.

音频优先级：

1. `ai6_voice_arc_resource` — `implemented_unverified`；格式：candidate Ogg/Vorbis in u32le count + count x 272-byte voice.arc index；clean voice：是
2. `directsound_pcm` — `implemented_unverified`；格式：generic DirectSound PCM fallback；clean voice：否
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- No AI6 original-install identity/timeline ledger or same-session text-resource-card E2E is available; this adapter is offline-only and implemented_unverified.
- DirectSound and process-loopback are mixed-output fallbacks and must not be described as clean voice.
- The candidate resource parser accepts only the bounded fixed 272-byte index layout with stored Ogg members that pass structural/EOS validation; Ogg CRC is not validated.

Fixtures：`tests/fixtures/elf_ai6_replay.json`、`../../fushi/test/fixtures/galhook/elf_ai6_replay.json`

Tests：`tests/elf_ai6_adapter_test.cpp`、`tests/resource_audio_ready_test.cpp`、`../../fushi/test/mining/elf_ai6_pairing_test.dart`

### RealLive / old VisualArt's (`reallive`)

- 状态：`implemented_unverified`
- 别名：RealLive、VisualArt's RealLive
- 家族：`visualarts`（older sibling of the verified Siglus OVK path）
- 当前 adapter：`hook/adapters/reallive_adapter.inc`
- 进程策略：launch=`profile_pending_real_sample`，attach=`generic_attach_available`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x86；证据：real_sample — Key planetarian Kinetic Novel (2004) ships its RealLive build renamed as Kinetic.exe, PE32 machine 0x014c; static probe 2026-09-27
- `resource_extensions`：.ovk、.nwk；证据：real_sample — anemoi VisualArt's/Siglus koe/*.ovk proves the shared container path only; it is not RealLive compatibility evidence. Key planetarian Kinetic Novel (RealLive, x86) Kineticdata/KOE/z0001.nwk (754 members) and z0002.nwk (102 members): every member parsed and decoded offline to 16-bit WAV on 2026-09-27; offline format evidence only, no runtime read observed

文本能力：

- `luna_hook`：`implemented_unverified` — A RealLive dialogue-thread fixture and real sample are still required.
- codepage：game-specific
- 线程提示：Select a stable RealLive/Luna dialogue thread after real-sample probing.

音频优先级：

1. `reallive_nwk_nwa_resource` — `implemented_unverified`；格式：u32 count + 12-byte {byte_len, offset, voice_id} entries; NWA complevel -1..5 (16-bit, mono/stereo) decoded on the worker to PCM WAV；clean voice：not_verified
2. `visual_arts_ovk_resource` — `implemented_unverified`；格式：strict u32 count + 16-byte entries + complete Ogg/EOS；clean voice：not_verified
3. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：generic source PCM fallback；clean voice：engine_dependent
4. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Format sharing with verified Siglus OVK is not evidence that a RealLive title is compatible.
- NWK/KOE/NWA remain unevaluated because no real old VisualArt's sample is available; no parser or support claim is added for them.
- A real original-path run must add executable/module hashes, text-thread evidence and byte-identity proof before promotion.
- Supersedes the NWK/NWA line above: a bounded NWK index parser and NWA decoder (complevel -1..5, 16-bit) now decode all 856 members of a real planetarian Kinetic Novel sample offline; no runtime KOE read, text pairing or card has been recorded, so the path stays implemented_unverified.
- Identity is structural: ASCII Gameexe.ini plus a Seen script name in the executable file, or Gameexe.ini plus Seen.txt beside it, with any SiglusEngine marker or Siglus directory signature as a veto. Older AVG32 builds share that naming and are not distinguished.
- NWK capture only observes a synchronous ReadFile that starts exactly at an indexed member; pending overlapped reads, memory-mapped KOE access and 8-bit NWA are not captured. Standard RealLive KOE/*.ovk titles still rely on the shared OVK path.

Fixtures：`tests/fixtures/reallive_replay.json`

Tests：`tests/reallive_adapter_test.cpp`、`tests/reallive_nwk_test.cpp`

### CMVS (Purple Software) (`cmvs`)

- 状态：`implemented_unverified`
- 别名：CMVS、Purple Software、パープルソフトウェア
- 家族：`cmvs`（Purple Software in-house engine; no verified sibling）
- 当前 adapter：`hook/adapters/cmvs_adapter.inc`
- 进程策略：launch=`generic_launch_available`，attach=`generic_attach_available`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：cmvs32.exe、cmvs64.exe；证据：real_sample — Purple Software クロノクロック 体験版v2 (2015-03-20) ships both cmvs32.exe (x86) and cmvs64.exe (x64); static probe 2026-09-04. Retail builds may rename the exe, so names are catalogue only and the adapter matches on cmvs.cfg + CPZ archives instead
- `pe_architectures`：x86、x64；证据：real_sample — cmvs32.exe machine 0x14c, cmvs64.exe machine 0x8664 (same trial package)
- `directory_files_all`：cmvs.cfg、data/pack/start.ps3；证据：real_sample — cmvs.cfg opens with [CMVS_SYSTEM_MAIN] and SCRIPT_INIT_PATH=data\pack\; data/pack/start.ps3 (PS2A) is the script entry; trial package 2015-03-20
- `pe_imports`：DSOUND.dll、WINMM.dll、d3d9.dll、mog2x32.dll、mog2x64.dll；证据：real_sample — PE import tables of cmvs32.exe / cmvs64.exe (static probe 2026-09-04); DirectSound is the only audio API imported
- `runtime_modules`：mog2x32.dll、mog2x64.dll；证据：real_sample — Purple MOG2 image library shipped next to the exe (sha256 6b8dc960… / c51ba0c3…); static import only, runtime load not yet observed
- `resource_extensions`：.cpz、.ps3、.cmv；证据：real_sample — data/pack/*.cpz (CPZ6 magic; voice.cpz + voice2.cpz hold voice), data/pack/start.ps3, data/video/*.cmv, data/music/*.ogg in the trial package
- `hashes`：c5e715d98b56468df0a3d6bd8ec263b72bab736e0ad004de4e443a54c470ddad、aa89205a61c7078a167f9e6668eea2e4328bdd5c9cbcdd6f45b238cf475acea2；证据：real_sample — cmvs32.exe / cmvs64.exe of クロノクロック 体験版v2, catalogue only; the adapter does not hash-pin because the structural cfg + CPZ check is the identity

文本能力：

- `luna_hook`：`implemented_unverified` — Observed and selected EmbedCMVS dialogue lane in the 2026-09-13 trial x64 session; its UTF-16 text exactly matched the live glyph reader. Card/audio pairing E2E remains unverified.
- codepage：932
- 线程提示：Prefer the LunaHook EmbedCMVS thread once observed; the adapter installs no text hook of its own.

音频优先级：

1. `cmvs_group_loader_voice_ogg_resource` — `implemented_unverified`；格式：Decrypted per-line Ogg member returned by the engine's own archive-group loader for voice*.cpz groups (x64 only; loader sites resolved structurally from the main image exception directory)；clean voice：是
2. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：DirectSound source PCM via the generic Windows audio adapter；clean voice：engine_dependent
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Per-line voice comes from the engine's archive-group loader (BUG-2932): x64 builds only, because x86 images carry no unwind table to prove the loader entry; x86 stays on the generic PCM path, which has no voice/SE floor and can pair click SEs as voice. The 2026-10-04 リアライブ体験版v2 session wrote the right per-line Ogg files, but no same-session card E2E is recorded yet.
- Identity is structural (cmvs.cfg section + CPZ archive magic); executable hashes are catalogued but not pinned.
- In-game Shift lookup is wired only for the measured ChronoClock trial v2 x64 executable hash. Other CMVS builds, transformed/faded/ambiguous sprites and unproved presentation modes fail closed; real popup/input/card E2E is pending.

Fixtures：`tests/fixtures/cmvs_replay.json`

Tests：`tests/cmvs_adapter_test.cpp`、`../../fushi/test/mining/cmvs_pairing_test.dart`

### KiriKiri2 / KiriKiriZ (`kirikiri_z`)

- 状态：`partial`
- 别名：吉里吉里2、Kirikiri 2、吉里吉里Z、Kirikiri Z
- 家族：`kirikiri`（KiriKiri family）
- 当前 adapter：`hook/adapters/kirikiri_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`limited_after_audio_device_creation`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：otomeki.exe、isekai-elf-sample.exe；证据：real_sample — otomeki.exe KiriKiriZ run (2026-07-18) and official BABEL KiriKiri2 experience version run (2026-07-23)
- `pe_architectures`：x86；证据：real_sample — Both recorded KiriKiriZ and KiriKiri2 samples are x86
- `runtime_modules`：dsound.dll、wuvorbis.dll；证据：runtime_observation — DirectSound was observed in otomeki.exe; the official BABEL experience version loaded wuvorbis.dll from the KiriKiri temp plugin directory
- `resource_extensions`：.xp3、.ogg；证据：real_sample — The official BABEL experience version ships data.xp3/plugin.xp3 and opens Ogg through wuvorbis
- `hashes`：2280115774277789CA15760CD25E29E82560B928FC7994763F7EBEBF7461D92A；证据：real_sample — SHA-256 of isekai-elf-sample.exe from the developer-hosted experience version

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — Generic Luna plumbing exists; the P0 baseline does not record a versioned text-thread replay.
- `ingame_lookup_geometry`：`implemented_unverified` — In-game dictionary lookup is implemented but remains capability-level unverified: the KiriKiri sensor supplies per-glyph geometry and paints the selection highlight, while Hibiki reuses its existing popup in a dedicated off-screen galCard WebView2 surface, captures BGRA, and presents that bitmap through the v15 shared-memory frame route into a game Layer. During mining, the v15 exact CaptureSuppress control frame temporarily hides the game-side card and highlight without destroying the off-screen popup state; the hook alone advances lookup_frame_applied_seq after a later continuous callback, so ordinary present/dismiss/highlight frames cannot satisfy the capture barrier. Embedded mode suppresses only the popup sentence banner; dictionary, audio, mining, theme, and nested-card rendering remain shared with the normal Fushi popup. A 2026-08-13 Windows/KiriKiri same-session E2E on the target game observed applied_seq 0→76, a later full restore frame at 80, a real Anki card with a 480×286 AVIF, and an original-resolution image containing no Fushi popup or selection highlight. Coordinate conversion, KAG message-layer identity, submit/hover fencing, off-screen resize handling, and the v15 wire contract have source-level guards, but by explicit request no automated tests, generators, guards, or CTest were run; no broad KiriKiri support upgrade is claimed.
- codepage：game-specific
- 线程提示：Reject metadata/per-character noise and select the stable dialogue thread manually when auto-selection is ambiguous.

音频优先级：

1. `kirikiri_resource_stream` — `implemented_unverified`；格式：TVPCreateIStream / complete Ogg from wuvorbis callbacks；clean voice：not_verified
2. `kirikiri_decoder_pcm` — `implemented_unverified`；格式：wuvorbis / wuopus decoder output when available；clean voice：not_verified
3. `directsound_pcm` — `verified`；格式：44100 Hz / stereo / signed 16-bit in the verified sample；clean voice：否
4. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **otomeki.exe sample**（x86，not recorded，2026-07-18）：Hibiki launched the game through the x86 injector and read three seconds of non-silent 44100/2/16 PCM through the real shared-memory channel. SHA-256：未记录。
- **異世界で猫耳聖女とツンデレエルフ 体験版**（x86，KiriKiri2 (Borland/BCB register ABI)，2026-07-23）：Developer-hosted experience version launched under Japanese CP932; the BCB resource hook and wuvorbis open/read hooks installed, Luna connected, and non-silent 44100/2/16 decoder PCM reached shared memory. A voiced dialogue line was not traversed, so clean per-line Ogg remains unverified. SHA-256：2280115774277789CA15760CD25E29E82560B928FC7994763F7EBEBF7461D92A。

已知限制：

- The verified KiriKiriZ sample software-mixes into one DirectSound output stream, so captured PCM is equivalent to loopback and includes BGM/SE.
- KiriKiri2 BCB resource and decoder hooks install on the recorded official sample, but a voiced dialogue line has not yet been traversed; clean per-line Ogg is not claimed.
- The older KiriKiriZ sample executable hash and engine version were not recorded; executable name alone is not a reusable engine signature.
- In-game dictionary lookup remains implemented_unverified. The production route reuses the Fushi popup in an off-screen galCard WebView2, captures a bounded BGRA frame, and displays it through the v15 KiriKiri Layer route; the game-side sensor still owns glyph hit-testing and selection highlighting. The v15 CaptureSuppress/applied-seq handshake was verified in one 2026-08-13 target-game same-session E2E: applied_seq advanced only after suppression, a later full frame restored the popup, and the real Anki AVIF contained no Fushi popup or selection highlight. Required automated/offline verification was explicitly skipped, and the geometry sensor is gated on a third-party textrender.dll plus a runtime probe for global.TextRender.getCharacters, so it does not generalise to KiriKiri as an engine. No capability or support-state upgrade is claimed.
- 2026-08-19 measurement, both directions, same hook build. Positive: on a second KiriKiri Z sample (tenshi_sz.exe, Chinese release, KAGEX plus third-party textrender.dll) launched by Fushi 2.1.1-debug.11887, one session completed the whole in-game chain: lookup_diag reached 0x0000106F (sensor_installed | geometry_observed | hit_submitted | buffer_route_ready | frame_presented | expression_ready), clicking a glyph rendered the lookup card inside the game layer, and the card's mining button wrote a real Anki note (total notes 13200 -> 13201) whose media are genuine (10138-byte AVIF starting with ftypavis, 9260-byte MP3 starting with ID3) and whose sentence field holds the clicked line. Negative: on a classic KAG3 sample that ships no textrender.dll (フタマタ恋愛 Ver1.00, KiriKiri2/BCB), with lookup_enabled forced to 1 by the diagnostic probe, lookup_diag stayed 0x00000000 for the entire session while text capture worked (text_writes=8) - the sensor never installs and in-game lookup is entirely absent there. In-game lookup therefore stays scoped to KiriKiri Z builds shipping textrender.dll and is still not a KiriKiri-engine-wide capability. Recorded as measurement only; no status or capability upgrade is claimed.
- Text-thread choice is not free on this engine: the same game exposes one EmbedKrkrZ thread carrying whole-string-doubled dialogue (folded correctly by the block-level normaliser) and several KiriKiriZ threads carrying per-character doubled/tripled strings that the artifact gate correctly drops. Selecting a KiriKiriZ thread leaves the workbench with zero lines forever and makes in-game mining fail silently. Tracked as BUG-1733/1734/1735; the native filtering is correct and must not be relaxed.
- 2026-09-05 measurement, classic KAG3 in-game lookup, same hook build (helper x86 a180314c5688eca6eb03269c5c1dc958fe103a57b2fed6c28d74e1a80447afad). This supersedes the 2026-08-19 negative on classic KAG3, whose stated cause (no textrender.dll) was wrong. Two classic KAG3 / KiriKiri2-BCB samples were driven by the injector directly (--launch --hold) with lookup_enabled forced by the diagnostic probe. Fate/stay night[Realta Nua] -Fate-: lookup_diag 0xB0000541 (sensor_installed | expression_ready | classic_patch_installed | classic_processch_fired), xaudiodiag2 0x0194000c (SeamArmed | SeamFired | BootstrapStarted | BootstrapFired). Futamata Renai Ver1.00, the very sample recorded as the 2026-08-19 negative: lookup_diag 0xB0000141 (sensor_installed | expression_ready | classic_patch_installed), xaudiodiag2 0xa194000c, which additionally carries ExporterScanRan | ExporterScanAdopted. Four distinct root causes were fixed to get here: BUG-2121 (main-window shape, poll semantics, and the addHook precondition), BUG-2144 (Borland exceptions crossing an MSVC catch(...)), and BUG-2145 (a build with no export directory at all whose plugins all link before the LoadLibrary hook). The sensor now installs on classic KAG3 without textrender.dll. This is an install-stage measurement only: no glyph hit, card render, or mining E2E was run on either sample in this session, and no status or capability upgrade is claimed.
- 2026-09-26 measurement, Yuzusoft KiriKiri Z variant plus launch lifecycle (BUG-2701/2702). Samples, all x86: 喫茶ステラと死神の蝶 original CafeStella.exe (SHA-256 0dd0b3bcc5dcdda257f50ef52f121f919a7453c2afa614f8f82124cb92351d50; no exe exports, exporter obtained by the linked-plugin scan; plugins PackinOne/yuzuex decrypt hashed archive members), the same package's Enigma-packed Chinese exe (7e6106bbfd82b0635ecbb2c9308cb3ddd5661d8fb89ee7f22e58e40f9764fc31; one TLS callback), PARQUET Steam build with SteamStub removed (83c40f84b722be859531795d0afd2722182cbf09f041a60916279b1103153d00), and 夏空カナタ KiriKiri2/BCB (2485542046550c6bd9c026fecd95b73493c2cf1def36eb211cfe9bc3f4714afe). The Enigma exe hung the remote LoadLibraryW under create-suspended early injection because the injector thread ran the process's TLS callbacks; the injector now parks the primary thread at the entry point when the exe declares TLS callbacks and its directory carries the KiriKiri XP3 archive signature (engine launch profile admission, no title or hash; owner 2026-09-26 narrowed it from every TLS-callback exe to KiriKiri, and a packer that rewrites the entry leaves the primary thread running and the game attached as a running process), after which it reached OK hooked, EmbedKrkrZ dialogue text and decdiag 0x031e0903. On the original exe every named voice open also produced a same-length ciphertext copy under the hashed physical name; the named-storage enqueue now requires an Ogg or RIFF/WAVE container, after which only the decrypted noz001_*.ogg files were published. Observed stages on the original exe: process_found, helper_ready, ipc_ready, text_ready (EmbedKrkrZ thread; KiriKiriZ threads carry the known doubled artifacts), and resource files whose ticks follow the matching dialogue lines. Not run: card write E2E. Japanese-named SE files still reach the consumer as voice candidates (BUG-2703). Measurement only; no status or capability upgrade is claimed.
- 2026-09-26 measurement, Senren Banka disc release (BUG-2704/2705/2706/2708). Samples, x86: SenrenBanka.exe (SHA-256 5b9cdea0a8c5b22cfb1a7df2ecb2e01484a190dce31b2cd6d6b101b178645727; KAGEX CustomMessageLayer with a MessageTextLayer child, textrender.dll loaded but no TextRender instance bound to any message layer) and the package's Enigma-packed Chinese exe SenrenBankaCHS.exe (2369627f97a0de5222781e456e4abe9679d24a39e0b35f15e04f4184a59f3153; TLS callback shows a translator notice before the entry point). Original path via the rebuilt Fushi itest host (launchoff): the remembered EmbedKrkrZ thread restored to the current session, text lines arrive single and without the sticky looping-sound suffix, voiced lines pair as game_resource, and in-game lookup captured glyph geometry through the classic processCh fallback: clicking a glyph highlighted it, opened the Fushi lookup card for the clicked word, and the host line list did not advance. Not run: card write E2E. The Chinese exe was verified only up to the loader gate waiting on its notice (the sample itself then reports a missing patch.xp3 without Fushi). One extra click is swallowed right after dismissing a card (BUG-2710). Measurement only; no status or capability upgrade is claimed.

Fixtures：`tests/fixtures/kirikiri_lookup_replay.tsv`

Tests：`tests/resource_audio_ready_test.cpp`、`tests/lookup_ipc_contract_test.cpp`、`tests/lookup_session_replay_test.cpp`、`tests/kirikiri_lookup_source_guard_test.py`

### XAudio2 / DirectSound generic capture (`xaudio2_directsound`)

- 状态：`verified`
- 别名：XAudio2、DirectSound、Windows source PCM
- 家族：`windows_audio_api`（generic audio backend）
- 当前 adapter：`hook/adapters/windows_audio_adapter.inc`
- 进程策略：launch=`create_suspended_preferred`，attach=`supported_for_objects_created_after_attach`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x86、x64；证据：runtime_observation — Both helper architectures build; x86 KiriKiriZ/Siglus paths were exercised on real games.
- `runtime_modules`：xaudio2_9.dll、xaudio2_8.dll、dsound.dll；证据：runtime_observation — The shipped generic adapters resolve these loaded modules; DirectSound was observed on the recorded x86 samples.

文本能力：

- 不适用；文本由具体引擎 profile / Luna 线程处理。
- codepage：not_applicable
- 线程提示：Text selection belongs to the engine/Luna profile, not the audio backend.

音频优先级：

1. `xaudio2_source_voice_pcm` — `verified`；格式：source-voice PCM；clean voice：engine_dependent
2. `directsound_buffer_pcm` — `verified`；格式：secondary/output buffer PCM；clean voice：engine_dependent
3. `xwma_compressed_resource` — `implemented_unverified`；格式：RIFF/XWMA rebuilt from the submission's own fmt + dpds；clean voice：engine_dependent

真实样本证据：

- **Recorded real-game set**（x86 verified; x64 build covered，mixed，2026-07-18/19）：The generic capture path produced non-silent PCM on the KiriKiriZ and Siglus samples; the baseline also records XAudio2 real-game verification without a versioned sample hash. SHA-256：未记录。

已知限制：

- A backend hit does not prove clean voice: software-mixed buffers can be equivalent to loopback.
- Attach cannot retroactively hook already-created engine/source objects.
- The P0 baseline does not contain a named, hashed XAudio2 sample, so compatibility must be re-verified per engine.
- xWMA source voices publish a compressed resource rebuilt from the runtime format and the XAUDIO2_BUFFER_WMA dpds table. The compressed payload is verbatim, but the RIFF envelope is synthesised here, so the emitted file is not byte-identical to any archive entry. No real game has been run against this path yet.

Fixtures：尚无（P5 补齐）

Tests：`tests/session_reuse_test.cpp`

### Ren'Py / FFmpeg (`renpy_ffmpeg`)

- 状态：`implemented_unverified`
- 别名：Ren'Py、libavcodec、libavformat、FFmpeg 54
- 家族：`renpy`（versioned FFmpeg runtime）
- 当前 adapter：`hook/adapters/renpy_adapter.inc`
- 进程策略：launch=`launcher_then_scored_game_child`，attach=`implemented_for_target_process_only`，follow-child=`true`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：Sakura Swim Club.exe；证据：real_sample — Sakura Swim Club full-card run recorded in hibiki handoff 2026-07-18
- `pe_architectures`：x86；证据：runtime_observation — Recorded Ren'Py sample launches a child python.exe targeted by the legacy hook
- `runtime_modules`：avcodec-54.dll、avformat-54.dll；证据：runtime_observation — The existing adapter targets the recorded legacy Ren'Py/FFmpeg runtime; the sample did not produce an adapter hit

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — No versioned text-thread replay is recorded for the sample.
- codepage：game-specific
- 线程提示：Select the child python process and its stable dialogue thread, not the launcher.

音频优先级：

1. `ffmpeg_resource_event` — `implemented_unverified`；格式：signature-checked OGG/WAV/Opus/FLAC/M4A from any versioned avformat module；clean voice：not_verified
2. `ffmpeg54_decoder_pcm` — `implemented_unverified`；格式：libavcodec/libavformat major 54 decoded PCM；clean voice：not_verified
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **Sakura Swim Club**（x86 child python process，Ren'Py version not recorded，2026-07-18）：The end-to-end card path succeeded through process loopback; the engine adapter did not hit, so this is not evidence of FFmpeg adapter compatibility. SHA-256：未记录。

已知限制：

- Generic avformat resource capture only accepts local, standalone OGG/WAV/Opus/FLAC/M4A files; archive/custom AVIO URLs fall through to PCM or loopback.
- Only the optional decoded-PCM compatibility path interprets libavcodec/libavformat major 54 hand-maintained layouts; modern majors never use those offsets.
- The selected injector/DLL architecture must match the followed game child; a launcher that crosses x86/x64 still requires selecting the child's architecture upstream.
- The real sample fell back to loopback; no clean decoder-level voice claim is made.

Fixtures：`tests/fixtures/workflow_replay.json`

Tests：`tests/ffmpeg_runtime_test.cpp`、`tests/child_process_policy_test.cpp`、`tests/resource_audio_ready_test.cpp`

### TyranoScript / NW.js (`tyrano_nwjs`)

- 状态：`partial`
- 别名：TyranoScript 5、TyranoBuilder、NW.js
- 家族：`tyrano`（NW.js packaged TyranoScript runtime）
- 当前 adapter：`hook/adapters/tyrano_adapter.inc`
- 进程策略：launch=`inject_visible_nwjs_process_before_resume`，attach=`requires_attach_before_app_asar_open`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：kaerimichi.exe；证据：real_sample — かえりみち official free Windows release from novelgame.jp, verified 2026-07-23
- `pe_architectures`：x64；证据：real_sample — kaerimichi.exe PE/COFF x86-64 runtime observation
- `directory_files_all`：resources/app.asar、ffmpeg.dll；证据：real_sample — Official sample package layout and live module inventory
- `runtime_modules`：ffmpeg.dll；证据：runtime_observation — Monolithic Chromium FFmpeg exports avformat_open_input and is loaded in the visible NW.js process
- `resource_extensions`：.ogg、.m4a；证据：real_sample — app.asar contains paired OGG/M4A voice members under data/sound/v_*
- `hashes`：kaerimichi.exe sha256:B12A54AA1F76C7EE7308B40885ACE4534679798F79ED81909524260FB667F80D、app.asar sha256:46867519C7896B7DFB753BB3381C040970B1F0FFA226E3511751414D8E1FCED7；证据：real_sample — Local SHA-256 of the official かえりみち Windows release, 2026-07-23

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — The live run exposed Tyrano text in process diagnostics, but no stable production thread-selection replay was recorded.
- codepage：UTF-8/Unicode
- 线程提示：Prefer a stable complete-line renderer thread; ignore CSS, resource-path and per-character noise.

音频优先级：

1. `tyrano_asar_voice_resource` — `verified`；格式：exact signature-checked OGG/M4A member from data/sound/v_*；clean voice：是
2. `ffmpeg_resource_event` — `implemented_unverified`；格式：monolithic Chromium ffmpeg.dll avformat boundary；clean voice：not_verified
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **かえりみち**（x64，TyranoScript 5 / NW.js; package product version 1.0.1，2026-07-23）：Official free full-voice sample. The first voiced line exported d_a_1.ogg (58,597 bytes); SHA-256 9C94CE6BE59B788E35F299379001C50E82D55CAF02B54EB0A63B9FB4C079AAF9 exactly matched the corresponding app.asar member. SHA-256：B12A54AA1F76C7EE7308B40885ACE4534679798F79ED81909524260FB667F80D。

已知限制：

- Clean resource capture currently recognizes the Tyrano convention data/sound/v_* and OGG/M4A members; projects using custom voice directories or encrypted archives need another profile.
- The verified build captures from the visible root process. NW.js builds that perform archive reads only in a child process still require explicit child targeting until injector-wide descendant propagation is implemented.
- Audio is verified, but stable automatic Tyrano text-thread selection remains unverified.

Fixtures：尚无（P5 补齐）

Tests：—

### BGI / Ethornell (`bgi_ethornell`)

- 状态：`implemented_unverified`
- 别名：BURIKO General Interpreter、Ethornell
- 家族：`bgi`（BURIKO ARC20 runtime）
- 当前 adapter：`hook/adapters/bgi_ethornell_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`supported_before_voice_archive_open`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：BGI.exe；证据：real_sample — AUGUST official 千の刃濤、桃花染の皇姫 Web trial, inspected 2026-07-23
- `pe_architectures`：x86；证据：real_sample — Official trial BGI.exe PE/COFF static probe
- `directory_files_all`：BGI.exe、BGI.hvl、data03110.arc；证据：real_sample — Official trial package layout
- `pe_imports`：DSOUND.dll、KERNEL32.dll；证据：real_sample — Official trial BGI.exe import table
- `resource_extensions`：.arc、.ogg；证据：real_sample — data03110.arc has a BURIKO ARC20 index and 146 bw-wrapped Ogg members
- `hashes`：BGI.exe sha256:03BBBD0F98AF6C050924448070198D5DF180925819E57AD446FB9F6EC88BC2C1、data03110.arc sha256:8EB51113AD99FCB6A8AC953C25E8F25431B3590CEA0B6C50EE722E8B1D8C4162、official trial zip sha256:470FD6C7F16980F226232925AD3E6216A4A14B1E46C6B5965706296430835E4F；证据：real_sample — Local SHA-256 of the developer-authorized DLsite trial and its BGI.exe, 2026-07-23

文本能力：

- `bgi_message_set_text_hook`：`implemented_unverified` — Native exact text lane (source kind 7, hook 'BGI exact', ENGINE:BGI:message_set_text): the message object's SetTextImpl is resolved structurally for both calling-convention generations (1.5x __thiscall ret 0x10 / 1.6x __stdcall ret 0x14) from its unique vcall shape through the Ex vtable layout slot, cross-proved against the vtable a constructor installs whose layout wrapper calls the function owning the leading-control-byte switch; the detour copies the CP932 line (bounded) and the worker strips control bytes / inline tags, converts to UTF-16 and publishes one lane per message owner (owner class + base position). 2026-09-30 Frida probes on the 2011 Ethornell 1.519.6 trial (original Fushi-host launch, LocaleEmulator) showed one clean whole line per SetTextImpl (render=1) plus an empty clear on a sibling object, and that LunaHook's EmbedBGI on the layout function emitted nothing on that path. Resolver run offline on that exe and on a 2016 Ethornell 1.626 trial resolved both generations. 2026-09-30 injector-side on that trial (same run as lookup_acceptance.geometry): the BGI exact lane published each dialogue line whole (e.g. 「ここ数日、街に雨は降っていない。」, then two two-row lines) 70-200 ms before the EmbedBGI lane carried the same text. No Fushi-host text_ready run with this DLL is recorded yet.
- `luna_auto_or_pc_hooks`：`implemented_unverified` — Generic Luna plumbing is present; no stable BGI dialogue thread has been selected on the official sample yet.
- `ingame_lookup_geometry`：`implemented_unverified` — Engine-exact message-page provider kLookupGeometryProviderIdBgi (21), see lookup_acceptance.geometry. Offline: x86/x64 build and fushi_bgi_lookup_test; no Fushi-host accept4 run is recorded.
- codepage：CP932 / game-specific
- 线程提示：Select a stable complete-line Luna thread after the installed game reaches dialogue.

音频优先级：

1. `bgi_arc20_voice_resource` — `implemented_unverified`；格式：complete Ogg after the 64-byte BGI bw wrapper in data031*.arc；clean voice：not_verified
2. `directsound_pcm` — `implemented_unverified`；格式：generic DirectSound fallback；clean voice：engine_dependent
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- The official trial archive and BGI wrapper were measured directly, but the adapter has not yet crossed a voiced line in the installed game, so clean voice is not claimed.
- The initial profile intentionally tracks data031*.arc only; BGI titles that use another archive number require measured evidence before widening the classifier.
- The callback only queues bounded metadata. ARC index parsing, Ogg validation and disk output run on the hook worker.
- Per-line voice archives are recognised by content convention (every member a mono bw wrapper), measured on two AUGUST trials: the 2011 PackFile-generation Eustia Web trial (17 voice archives, 3529 members) and the 2016 ARC20 senmomo trial (19 voice archives, 4371 members); BGM, SE, ambience and mixed archives in both were rejected. A BGI title with an all-mono SE archive or stereo voice would be misclassified.
- The former data031*.arc name rule pointed at the senmomo trial SE archive (data03110.arc, 143 of 146 members stereo); its voice lives in data04xxx.arc. The adapter no longer uses that name rule (every *.arc handle is tracked and classified on the worker); the process-strategy note and audio format that still mention data031*.arc are evidence-gated claim fields and stay unchanged until a runtime ledger backs the new contract.

Fixtures：尚无（P5 补齐）

Tests：—

### Artemis Engine / PF8 (`artemis_pfs`)

- 状态：`partial`
- 别名：Artemis Engine、Artemis、PF8
- 家族：`artemis`（iarsys runtime with PF6/PF8 archives）
- 当前 adapter：`hook/adapters/artemis_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`requires_attach_before_target_pfs_open`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：アマナツ体験版.exe；证据：real_sample — あざらしそふと official アマナツ trial, verified 2026-07-23
- `pe_architectures`：x64；证据：real_sample — Official trial executable PE/COFF x86-64 static and live observation
- `directory_files_all`：iarsys64.dll、*.pfs；证据：real_sample — Official trial portable package contains iarsys64.dll and a same-title PF8 archive
- `pe_imports`：DSOUND.dll、KERNEL32.dll；证据：real_sample — Official trial executable import table
- `runtime_modules`：iarsys64.dll；证据：runtime_observation — Official trial launched through the x64 Hibiki injector and exposed the Artemis runtime next to the executable
- `resource_extensions`：.pfs、.ogg；证据：real_sample — PF8 index contains 797 Ogg voice members under sound/vo and sound/sysse/vo
- `hashes`：trial executable sha256:C0C14E5215541D531AC3C68C208BB514C0EF1A36CBCA6F133872A3DDF37A92E2、trial PF8 sha256:A61E2A66056A7A9D196A8CD4D537B417D0996231103B64502FB514F0E3B8B402、official trial zip sha256:46B5BE9C24C71A3A5709312E25CEAF7E3A6638E6F5FE108C809445F2FDFED553；证据：real_sample — Local SHA-256 of the developer-authorized official trial package, executable and PF8, 2026-07-23

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — The resource-audio run disabled Luna; no stable Artemis dialogue thread is claimed.
- codepage：Unicode / game-specific
- 线程提示：Select a stable complete-line dialogue thread after enabling Luna on the target title.

音频优先级：

1. `artemis_pf8_voice_resource` — `verified`；格式：complete SHA-1-XOR-decrypted Ogg member from sound/vo or sound/sysse/vo；clean voice：是
2. `directsound_pcm` — `verified`；格式：generic DirectSound fallback；clean voice：engine_dependent
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **アマナツ 体験版**（x64，Artemis Engine PF8; title version 1.0.0，2026-07-23）：Official developer trial. Real title-screen playback exported yas_00108.ogg (17,039 bytes, SHA-256 EACCA1330C73EA131E04AC5F2456868D97F98037FC0012DFA344ED255FDF84F5) and kaz_00239.ogg (41,208 bytes, SHA-256 81FF8F2C736E514001B1CEF6BC325B4DA4DC7E8C42CFC3D4D9BFDDEE69F59CBF); both exactly matched the corresponding decrypted PF8 members. SHA-256：C0C14E5215541D531AC3C68C208BB514C0EF1A36CBCA6F133872A3DDF37A92E2。

已知限制：

- Clean capture is verified for PF8 Ogg members in sound/vo and sound/sysse/vo; PF6 parsing is implemented but lacks a real-sample playback run.
- The adapter publishes the first PFS containing recognized voice entries; multi-PFS titles that split voices across archives need measured evidence before widening the implementation.
- Audio is verified, but stable automatic Artemis text-thread selection remains unverified.

Fixtures：尚无（P5 补齐）

Tests：—

### CatSystem2 / KIF INT (`catsystem2`)

- 状态：`partial`
- 别名：CatSystem2、CS2、KIF INT
- 家族：`catsystem2`（ARES ADV runtime and KIF archives）
- 当前 adapter：`hook/adapters/catsystem2_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`requires_attach_before_target_pcm_archive_open`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：cs2_open.exe、cs2.exe；证据：real_sample — ARES official CatSystem2 starter kit v3.01, verified 2026-07-23
- `pe_architectures`：x86；证据：real_sample — Official cs2_open.exe PE/COFF i386 static and live observation
- `directory_files_all`：config/startup.xml、*.int；证据：real_sample — Official packaged starter-kit replay layout
- `resource_extensions`：.int、.ogg；证据：real_sample — Official MakeInt.exe produced pcm_d.int with a named Ogg member that cs2_open.exe played through the pcm command
- `hashes`：official starter zip sha256:5D6230D0B947A71737DC55BF5E282D410B35011327E8890E4DDBD520263F32D3、cs2_open.exe sha256:D1889D60DBE3350B068605F94A49AE8E93EB388CE66E7ABC36607EED2EDA7010、replay pcm_d.int sha256:B1437440DD0C9A3D92570F57C855A4F6552F22546D39C4CCF92CB1E76A94AABC；证据：real_sample — Local SHA-256 of the official starter kit and the legally generated local replay archive, 2026-07-23

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — The resource-audio replay disabled Luna; no stable CatSystem2 dialogue thread is claimed.
- codepage：CP932 / game-specific
- 线程提示：Select a stable complete-line dialogue thread after enabling Luna on a target title.

音频优先级：

1. `catsystem2_unencrypted_kif_voice_resource` — `verified`；格式：complete Ogg member from unencrypted pcm_*.int；clean voice：是
2. `directsound_pcm` — `verified`；格式：generic source PCM fallback; 22050 Hz mono signed 16-bit in the replay；clean voice：engine_dependent
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否
4. `catsystem2_engine_decrypted_voice_resource` — `implemented_unverified`；格式：whole Ogg Vorbis member of any pcm_*.int the index lane does not own (encrypted KIF included), copied from the plaintext the engine's own Archive::ReadEntry hands its decoder and page-CRC-verified on the worker: <archive>_<member>.ogg, or <archive>_<member>.partial.ogg for the verified page prefix of a voice the next line stopped；clean voice：not_verified

真实样本证据：

- **CatSystem2 入門セット v3.01 — local voice replay**（x86，cs2_open.exe 2.6.1.67，2026-07-23）：ARES official engine and MakeInt tool with a locally generated 4.183220-second TTS voice. Real pcm playback exported D0213_02_001.ogg (26,897 bytes, SHA-256 D3D7C4A1F08B2A82DB1B4E4416B257B88047A774CAD8EBB6DDFD0728A5BA9E00), exactly matching both the source and KIF member. This verifies the unencrypted developer KIF path, not encrypted commercial-title compatibility. SHA-256：D1889D60DBE3350B068605F94A49AE8E93EB388CE66E7ABC36607EED2EDA7010。

已知限制：

- Encrypted commercial KIF archives containing __key__.dat use title-specific Blowfish material and are deliberately rejected; no commercial-title resource-audio claim is made.
- Only Ogg members in pcm_*.int are classified as voice; loose developer-mode files and non-Ogg voice formats fall back to source PCM or loopback.
- Audio is verified for the official starter-kit replay, but stable automatic CatSystem2 text-thread selection remains unverified.
- Encrypted pcm_*.int are rejected only by the index lane. The engine-decrypted lane (catsystem2_engine_decrypted_voice_resource) copies the plaintext the engine itself decrypts for its Ogg decoder, through Archive::ReadEntry resolved from structure alone (the kcBigFile::Read forwarder and its (entry, buf, len) order, the ReadEntry prologue, the plain-path block with the entry fields and the SetFilePointer/ReadFile import slots); no cipher, key or encrypted KIF index is implemented. Archive handles are classified from the engine's own reads (worker-side file-name query), so the lane also covers archives opened before it armed. It stays implemented_unverified until a Fushi host accept4 pairs one of its files with the displayed line and writes a real card.
- The engine lane publishes a voice once every page CRC verifies. A voice the next line stops before its tail was read (long lines clicked through) is published as its verified page prefix (<member>.partial.ogg: the heard part plus the decode-ahead); a playback whose Vorbis headers or first audio page were never read (skip) publishes nothing. Voice-to-line binding keys on Luna's hook identity: EmbedCS2 script lines precede the voice (measured 32-80 ms), render-time lanes such as the CatSystem2 rasteriser follow it (measured 0.3-1.7 s). Only lines within the host's 1.5 s resource window bind, so a render-lane line typed for longer (measured +1.7 s on a long line) stays unbound and cannot pair under the current host window.
- 2026-09-28 injector-side measurement (fushi_voice_injector --launch --hold with a hook DLL built from this tree; not a Fushi host run): グリザイアの有閑 GrisaiaAno1.exe (SHA-256 DB0CD534E0DF4C90ACE8296D1F2AC5D59D2EA4697C5303275109D4AFC539C45A, cs2 2.6.1, x86, all seven pcm_*.int encrypted). ReadEntry resolved at +0x136700; the adapter installed about 6 s after injection, after the engine had opened its archives, and the lane classified them from ReadEntry. 30 pages: 25 voiced pages gave 25 files, one per kcWLOgg pcm open with the file tick equal to the open tick; the 5 narration pages and the se.int/bgm.int Ogg opens gave none. 21 complete members (0.86-8.62 s, EOS, every page CRC valid, ffprobe durations equal) and 4 partial prefixes (4.7-9.1 s). Every binding still in the text ring matched the displayed page: 7/7 with the rasteriser lane selected (+312 to +1187 ms) and 8/8 with the EmbedCS2 dialogue lane (-32 to -63 ms); one rasteriser line at +1735 ms stayed unbound.

Fixtures：尚无（P5 补齐）

Tests：`tests/catsystem2_voice_test.cpp`

### Malie System / LIBP CFI (`malie_libp`)

- 状态：`implemented_unverified`
- 别名：Malie、Malie System、LIBP、CFI
- 家族：`malie`（Greenwood Malie runtime and title-keyed LIBP archives）
- 当前 adapter：`hook/adapters/malie_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`ready_but_preloaded_voice_requires_restart`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：malie.exe、malie_dsp.exe、malie_fabla.exe；证据：real_sample — Steam app 644540 build 21665074, verified 2026-07-23
- `pe_architectures`：x86；证据：real_sample — Official malie.exe PE/COFF i386, Malie System 1.0.0.5
- `directory_files_all`：malie.exe、data2.dat；证据：real_sample — Official Steam free common-route installation
- `pe_imports`：CreateFileA、CreateFileW、ReadFile、CreateFileMappingA、MapViewOfFile；证据：real_sample — malie.exe import table and live file-I/O diagnostics
- `resource_extensions`：.dat、.ogg；证据：real_sample — data2.dat contains 20,434 CFI-encrypted data\voice\*.ogg members
- `hashes`：malie.exe sha256:CFDAA598422245A36B2333F1E923C8E808412D0360C86EF83D914ADF4D6EA926、data2.dat sha256:D900B788306D1F7016FDAA592D3839E0E0845529435B1E8D73931E9D3F17AB39、GARbro 1.5.44 Formats.dat sha256:6AFB3BFD04FA1CD6D4616A1D36B21B8BE6E58B9FF475462A43D370EEAC4A37C3；证据：real_sample — Local SHA-256 of the official Steam sample and GARbro release database, 2026-07-23

文本能力：

- `malie_message_segment_hook`：`implemented_unverified` — Native exact text lane (source kind 15, hook 'Malie exact', ENGINE:MALIE:message_segment): the message window's click-unit parser (unique, one caller) and the RICHTEXT3D reveal setter are resolved from structure (see lookup_acceptance.geometry); the parser detour copies the unit's formatted text (bounded) and the reveal detour on the same thread pairs it with the text node and its glyph range. The worker removes control codes (0x07 0x08 voice tag, 0x07 0x09, 0x07 0x06 click wait, 0x07 0x04, line breaks) and keeps ruby bases only. 2026-10-03 Fushi host on Dies irae ~Interview with Kaziklu Bey~ (2016): the host auto-selected this lane and recorded clean whole lines, e.g. 「まあ何か飲めよ。どれがいい？」; LunaHook offered malie_6/Malie4/Malie5 threads on the same build.
- `luna_auto_or_pc_hooks`：`implemented_unverified` — The resource-audio run disabled Luna; no stable Malie dialogue thread is claimed.
- `ingame_lookup_geometry`：`implemented_unverified` — Engine-exact RICHTEXT3D provider kLookupGeometryProviderIdMalie (28), see lookup_acceptance.geometry.
- codepage：CP932 / localized build dependent
- 线程提示：Select a complete-line Malie dialogue thread after enabling Luna on a supported title.

音频优先级：

1. `malie_ogg_decoder_input_voice_resource` — `implemented_unverified`；格式：whole Ogg Vorbis file the engine's Ogg decoder consumes, copied at libogg ogg_sync_wrote from the decoder's own refill call sites (return-address checked) for decoders whose path field lies below a voice directory, published once its EOS page arrives (or as <name>.partial.ogg, the whole-page prefix, when the next line stops it) and bound to the message unit that carries the same voice tag；clean voice：not_verified
2. `directsound_pcm` — `verified`；格式：generic source PCM fallback；clean voice：engine_dependent
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- No Malie title is verified. The former verified_games record (Dies irae ~Amantes amentes~ free common route, Steam build 21665074, malie.exe sha256 CFDAA598422245A36B2333F1E923C8E808412D0360C86EF83D914ADF4D6EA926, 2026-07-23: v_ma2056.ogg byte-identical to the GARbro-decrypted data2.dat member) proved only the title-keyed CFI archive lane, and that lane was removed on 2026-10-03 (see below). The record was withdrawn with it: Amantes audio is back to unverified and must be re-run on the decoder-input lane from the original launch path before any verified claim returns.
- detection (directory_files_all data2.dat, CFI-encrypted data2.dat resource evidence, sample hashes) and the process_strategy notes (CFI decryption on HookWorker, hookio range bits, the --force-direct-launch run) are historical records of the retired Amantes CFI run, not the current mechanism: identity is the executable's CFI I/O scheme table, voice is the Ogg decoder input, and no archive is classified by file name.
- Whether the decoder-input lane still needs explicit --force-direct-launch under Steam (the retired archive lane did, because Steam protocol attach missed startup-prefetched reads) is unmeasured; titles that reject inherited AppID direct launch keep the DirectSound/loopback fallback.
- Malie audio is not verified on any title, and automatic text-thread selection is measured on one build only (Kaziklu Bey 2016, see text.capabilities); neither is a support claim.
- 2026-10-03: the title-keyed CFI lane (malie_libp_cfi_voice_resource, verified 2026-07-23 on Amantes) was retired together with its CFI key constants and the worker-side archive decryption: the same engine's 2016 Kaziklu Bey build encrypts its archive (data.dat, not data2.dat) with Camellia and another key, so the key could never be an engine-level property. Identity now comes from the executable's structure (the CFI I/O scheme table) and voice from the Ogg decoder input; the withdrawn Amantes verification predates this and the decoder-input lane has not been run on Amantes yet.
- The decoder-input lane copies the bytes the engine feeds its Ogg decoder while the voice plays (4 KiB refills): a voice the next click stops before its tail was decoded is published as its whole-page prefix (<name>.partial.ogg); a voice with fewer than four whole pages is dropped. A BOS page ends only the same decoder's open member; a member is finalised as stalled only after 48 feeds of other decoders (no feed at all, e.g. the game paused, never stalls it), and a member that lost a chunk (ring full or the copy faulted) is marked damaged and never published.
- Second sample pending: identity, decoder-input voice, text lane and RICHTEXT3D geometry were measured on one build (Kaziklu Bey 2016). The structural resolvers were also refused on five other-engine x86 executables; another Malie title (e.g. a Steam Amantes or a .lib-generation release) is still required.

Fixtures：尚无（P5 补齐）

Tests：`tests/malie_engine_io_test.cpp`、`tests/malie_lookup_test.cpp`

### QLIE / FilePack (`qlie_filepack`)

- 状态：`partial`
- 别名：QLIE、FilePackVer3.1、wuvorbis QLIE
- 家族：`qlie`（Warmth / AMUSE CRAFT QLIE runtime and FilePack archives）
- 当前 adapter：`hook/adapters/qlie_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection_with_optional_japanese_locale`，attach=`verified_live_attach_for_new_decoder_instances`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：美少女万華鏡_体験版.exe；证据：real_sample — 美少女万華鏡 -理と迷宮の少女- 体験版 1.01, verified 2026-07-23
- `pe_architectures`：x86；证据：real_sample — Measured trial executable PE/COFF i386
- `directory_files_all`：DLL/wuvorbis.dll、GameData/data0.pack；证据：real_sample — Measured trial directory; data0.pack tail contains FilePackVer3.1
- `runtime_modules`：wuvorbis.dll；证据：runtime_observation — Live x86 process invoked wu_ov_open_callbacks and wu_ov_read; the wu_ov_read_float export was present and its detour reached hook-ready state
- `resource_extensions`：.pack、.ogg；证据：real_sample — GameData/data*.pack with GARbro-extracted character voice Ogg members
- `hashes`：美少女万華鏡_体験版.exe sha256:E40C01C7611F1868F7057E534B3AA61316E9639481D1447267BF8645DEEB789B、wuvorbis.dll sha256:60996D622B30DC0AF15BD85A1B701F84FC8A34E7A8F1877C917E0EB63FA9EB2B、data0.pack sha256:A9E1C3EFECA180891C8C788A226391CD0DD96E34E127C9CEA1F2894C68B1A2A7；证据：real_sample — Local SHA-256 of the measured trial files, 2026-07-23

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — The live run verified audio and visible Japanese dialogue, but did not establish a stable automatic QLIE dialogue thread.
- codepage：CP932
- 线程提示：Select the stable complete-line QLIE dialogue thread; launch old non-Unicode titles with the optional Japanese-locale path.

音频优先级：

1. `qlie_wuvorbis_per_source_pcm` — `verified`；格式：44.1 kHz per-decoder signed 16-bit PCM from wu_ov_read；clean voice：是
2. `qlie_wuvorbis_float_per_source_pcm` — `implemented_unverified`；格式：planar float from wu_ov_read_float, chunk-converted to interleaved signed 16-bit PCM；clean voice：是
3. `directsound_pcm` — `verified`；格式：generic source PCM fallback；clean voice：engine_dependent
4. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **美少女万華鏡 -理と迷宮の少女- 体験版**（x86，QLIE FilePackVer3.1; trial version 1.01，2026-07-23）：Live attach captured separate decoder sources while a voiced line was displayed. The mono 44.1 kHz capture segment matched the beginning of GARbro-extracted syou0005.ogg decoded PCM at zero lag with normalized waveform correlation 0.99964, while simultaneous stereo BGM remained on different source handles. This verifies clean pre-mix voice PCM, not original compressed Ogg bytes. SHA-256：E40C01C7611F1868F7057E534B3AA61316E9639481D1447267BF8645DEEB789B。

已知限制：

- The verified path emits decoded PCM rather than the original compressed Ogg member; Hibiki must package or encode the selected utterance for card storage.
- Only the measured x86 wuvorbis/FilePackVer3.1 title is verified. Other QLIE versions, alternate decoder DLLs, and non-Ogg voice formats require their own samples.
- The measured voice path invoked wu_ov_read. The wu_ov_read_float detour was installed successfully but its capture path still needs a title that actually invokes that export.
- Live attach captures decoder instances created after injection and can miss a line already playing at attach time; early launch injection remains preferred.
- Stable automatic text-thread selection is not yet verified for this title.

Fixtures：尚无（P5 补齐）

Tests：`tests/qlie_pack_test.cpp`、`tests/adapter_structure_test.py`

### Unity IL2CPP (`unity_il2cpp`)

- 状态：`verified`
- 别名：Unity、UnityPlayer IL2CPP
- 家族：`unity`（IL2CPP runtime）
- 当前 adapter：`hook/adapters/unity_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`supported_with_reduced_audio_coverage`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：manosaba.exe、Sasasa.exe；证据：real_sample — manosaba_game and 最悪なる災厄人間に捧ぐ runtime observations
- `pe_architectures`：x64；证据：real_sample — manosaba_game Unity IL2CPP sample
- `directory_files_all`：UnityPlayer.dll、GameAssembly.dll、*/il2cpp_data/Metadata/global-metadata.dat；证据：real_sample — manosaba_game directory inspection recorded in hibiki-hook README
- `runtime_modules`：UnityPlayer.dll、GameAssembly.dll；证据：runtime_observation — manosaba_game Unity IL2CPP sample

文本能力：

- `luna_pc_hooks`：`verified` — PC hooks are auto-enabled for the recorded Unity IL2CPP layout.
- `unity_tmp_events`：`verified` — The baseline records TMP/text and AudioClip resource pairing on a real IL2CPP sample.
- `unity_legacy_text_events`：`implemented_unverified` — Sasasa.exe was exercised through Hibiki launch/capture and produced complete Unity TextMesh lines; full offline gates were skipped by request. That run used the retired Sasasa.exe file-name gate. 2026-10-03 (PR #1917) the gate became a behavioural detector (>= 2 consecutive single-glyph TextMesh.set_text calls followed by a standalone U+3000, process-wide because a single-glyph TextMesh renderer uses one component per glyph); single glyphs are only buffered, not published as component lines, until the signature completes or breaks; after the latch, multi-character strings stay on their own component lanes and a multi-character string with an interior U+3000 revokes the latch. This detector is covered by synthetic unit tests only (tests/unity_text_mesh_reassembler_test.cpp) and has not been re-run on Sasasa or on any other Unity TextMesh title; a real re-test on Sasasa (first line lands on the 'Unity TextMesh line' lane and is auto-selected) is required. Known limit: a mid-sentence standalone U+3000 after >= 2 glyphs in a one-TextMesh-per-cell layout has the same call shape as the Sasasa terminator and still latches until revoked.
- codepage：utf-16 / managed strings
- 线程提示：Prefer the stable TMP/Luna dialogue source; keep text active when audio falls back to loopback.

音频优先级：

1. `unity_audioclip_resource` — `verified`；格式：AudioClip / StreamingAssets resource extraction；clean voice：是
2. `xaudio2_source_voice_pcm` — `verified`；格式：source-voice PCM fallback；clean voice：engine_dependent
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **manosaba_game / manosaba.exe**（x64，Unity IL2CPP (version not recorded)，2026-07-18）：Real directory/runtime signatures and the AudioClip/TMP/resource-pairing path are recorded; the helper release includes the x64 unity_audio_runtime. SHA-256：未记录。

已知限制：

- Unity Mono is a separate Phase 4 target and is not covered by this IL2CPP claim.
- The verified sample version and executable hash were not recorded.
- Attach after startup may miss source voices and must retain loopback fallback.

Fixtures：尚无（P5 补齐）

Tests：`tests/unity_event_cursor_test.cpp`、`tests/il2cpp_thread_scope_test.cpp`、`tests/resource_audio_ready_test.cpp`、`tests/adapter_structure_test.py`

### Leaf / AQUAPLUS (WHITE ALBUM2 exact profile) (`leaf_aquaplus`)

- 状态：`implemented_unverified`
- 别名：Leaf、AQUAPLUS、WHITE ALBUM2、WA2
- 家族：`leaf_aquaplus`（Leaf / AQUAPLUS custom Windows runtime）
- 当前 adapter：`hook/adapters/leaf_aquaplus_adapter.inc`
- 进程策略：launch=`normal_launch_or_suspended_launch_implemented_unverified`，attach=`implemented_unverified`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：WA2.exe；证据：real_sample — WHITE ALBUM2 bundled installation sample inspected on 2026-08-28; the name is descriptive only and never enables exact offsets
- `pe_architectures`：x86；证据：real_sample — Measured WA2.exe PE/COFF i386 sample, 1,220,096 bytes
- `pe_imports`：d3d9.dll、dsound.dll；证据：real_sample — Measured import table of the exact hashed x86 sample
- `runtime_modules`：d3d9.dll、dsound.dll；证据：runtime_observation — The exact hashed WA2 x86 sample completed original-path D3D9 lookup/input interception and source-audio card mining on 2026-08-28
- `resource_extensions`：.pak；证据：real_sample — VOICE.PAK and IC/VOICE.PAK are validated LAC archives whose playback entries are complete Ogg/Vorbis resources; the root archive completed original-path card mining on 2026-08-28
- `hashes`：algorithm=sha256, scope=game_executable, value=005E71107ED70E662C41CB526879CDCF0B9486E067C0E5A306308688C17409ED, version=WHITE ALBUM2 bundled edition (version not recorded)；证据：real_sample — SHA-256 measured from the user's original WA2.exe on 2026-08-28

文本能力：

- `luna_exact_cp932_thread`：`implemented_unverified` — The selected HSX0:0 source is identity-bound to module RVA 0x512BF. The original path was user-accepted, but the release evidence/offline gate set was intentionally skipped.
- `ingame_lookup_geometry`：`implemented_unverified` — The exact D3D9 profile reconstructs bounded per-glyph geometry only after the portable SHA-256 identity and hydrated-image unique-signature/decoded-target/callgraph/COM-ABI gate pass. The relocated A1 /GS cookie operand is deliberately masked and then required to resolve to the profile's module-relative data RVA. Release E2E evidence remains incomplete.
- `ingame_lookup_sampled_input_shield`：`implemented_unverified` — Single-click and Shift-hover interception is installed only after the same unique hydrated-image gate validates the exact GetAsyncKeyState poller callsites and D3D9 device ABI. Release evidence gates, including the 1,000-transaction shield corpus, remain incomplete.
- codepage：CP932
- 线程提示：Use only the selected Luna line source whose thread address equals WA2.exe + 0x512BF.

音频优先级：

1. `leaf_lac_voice_resource` — `implemented_unverified`；格式：original Ogg/Vorbis entry from VOICE.PAK or IC/VOICE.PAK；clean voice：是
2. `directsound_pcm` — `implemented_unverified`；格式：48000 Hz / mono / signed 16-bit in the observed sample；clean voice：engine_dependent

真实样本证据：


已知限制：

- This is one hash-pinned WHITE ALBUM2 x86 executable profile, not a family-wide Leaf or AQUAPLUS support claim. The hash is portable same-build identity, not a dependency on the developer's machine or install directory.
- A game update, different executable hash, missing/ambiguous hydrated signature, decoded target mismatch, callgraph mismatch or D3D9 ABI mismatch disables the selected text, geometry and sampled-input offsets until that build is measured independently.
- DirectSound remains a decoded/mixed fallback; the user-accepted card audio comes from the complete source Ogg member in VOICE.PAK.
- The root VOICE.PAK path completed runtime card mining; IC/VOICE.PAK shares the validated LAC parser but was not separately exercised in the accepted session.
- Late attach remains implemented_unverified; the accepted path used suspended launch so archive handles and playback reads could not be missed.
- The original path was user-accepted, but the requested skip-all-tests submission leaves the full release evidence/offline gate set incomplete, so support is not promoted to verified.

Fixtures：`tests/fixtures/leaf_aquaplus_replay.json`

Tests：`tests/leaf_aquaplus_adapter_test.cpp`、`tests/exact_lookup_signature_test.cpp`、`tests/leaf_aquaplus_voice_archive_test.cpp`、`tests/leaf_d3d_trace_export_test.cpp`、`tests/resource_audio_ready_test.cpp`、`tests/adapter_structure_test.py`、`tests/galhook_workflow_test.py`、`../../fushi/test/lookup/gal_ingame_lookup_click_swallow_guard_test.dart`

### HUNEX GGE / HFA-HW (`hunex_gge`)

- 状态：`implemented_unverified`
- 别名：HUNEX GGE、HFA/HW、WITCH ON THE HOLY NIGHT、WoH
- 家族：`hunex_gge`（HUNEX GGE HFA archive family; current admission is a WoH-specific title profile, not a family-wide role claim）
- 当前 adapter：`hook/adapters/hunex_gge_adapter.inc`
- 进程策略：launch=`normal_launch_observed_adapter_unverified`，attach=`existing_process_attach_observed_resource_hook_unverified`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：WoH.exe；证据：runtime_observation — The original WoH v1.0 Windows sample was observed as WoH.exe on 2026-08-30; the basename is title-profile metadata and never enables the adapter by itself.
- `pe_architectures`：x64；证据：runtime_observation — The original WoH v1.0 game process was measured as x64 on 2026-08-30.
- `resource_extensions`：.hfa、.hw；证据：real_sample — The local WoH v1.0 sample contains HUNEXGGEFA10 HFA indexes whose members use the 64-byte HW wrapper around complete Ogg streams; no game payload is committed.

文本能力：

- `luna_typemoon_dialogue_thread`：`implemented_unverified` — The WoH v1.0 original-path session observed and selected the dialogue thread, but no same-session source-audio pairing or card E2E has passed.
- codepage：UTF-16
- 线程提示：Select the observed Type-Moon dialogue lane and reject menu/help rendering lanes; this text evidence does not prove HFA resource capture.

音频优先级：

1. `hunex_hfa_hw_ogg_resource` — `implemented_unverified`；格式：complete source Ogg/Vorbis payload from a structurally validated 64-byte HW member inside a HUNEXGGEFA10 HFA archive；clean voice：not_verified

真实样本证据：


已知限制：

- The first failed boundary in the observed WoH v1.0 session is resource_observed: text and thread selection passed, while the UI still reported line_has_no_voice and zero voiced lines.
- No HFA/HW resource event, source-byte capture, clean-voice classification, text/audio pair, screenshot-card E2E or source-entry hash equality has passed on the original path. A 2026-08-31 user report claims live text and voice now work, but it is backed by no session ledger, resource event id or source-entry hash and does not raise the recorded evidence grade; see BUG-1977.
- The exact lookup provider currently fails closed while correlating the captured glyph/source descriptor with the final client-space sprite quad; single-click and Shift lookup remain implemented_unverified.
- The data04000.hfa voice role is proved only by the local WoH v1.0 archive layout and is not a HUNEX-family invariant; other titles stay disabled until their archive role is independently mapped and evidenced.
- Mono versus stereo is not a voice classifier. HW admission is structural and both channel layouts remain valid candidates until the title-scoped archive role is established.
- The profile intentionally has no executable or module hash allowlist so patched WoH executables can remain eligible for structural probing; WoH.exe and data04000.hfa names alone must never bypass HFA/HW validation.
- Deliberate 2026-08-31 graduation, recorded because it removed a guard: the x64 hydrated-image renderer/input scanner was promoted from observation-only to a production lookup provider, and the generator assertion 'HUNEX exact geometry is observation-only and must not OfferReady/PublishHit' was deleted to permit it. Only the geometry provider layer graduated. geometry.status stays implemented_unverified and the HFA/HW resource-capture and text/audio pairing gates stay not_verified; promoting the provider is not evidence for resource capture, pairing or any card E2E.
- The signature-based x64 exact provider is production-wired but remains implemented_unverified. Every ambiguous or missing renderer/input/projection anchor fails closed to attached_calibrated fallback; it must not be advertised as verified until same-session lookup/card and transaction E2E are recorded.

Fixtures：尚无（P5 补齐）

Tests：`tests/hunex_gge_adapter_test.cpp`、`tests/hunex_gge_capture_bridge_test.cpp`、`tests/hunex_gge_lookup_test.cpp`、`tests/hunex_gge_selected_text_test.cpp`、`tests/resource_audio_ready_test.cpp`、`tests/adapter_structure_test.py`、`tests/engine_support_manifest_test.py`

### smash / fzmedia (TYPE-MOON smash framework) (`smash_fzmedia`)

- 状态：`implemented_unverified`
- 别名：fsn_remastered、null-ge、fzmedia
- 家族：`smash`（TYPE-MOON smash framework (smash::fw::IGameEngine exported by null-ge-*.dll) with the fzmedia-*.dll media library; the app layer is a KAG re-implementation whose namespace differs per title (fate::app::krkrz on the measured sample), so admission is the framework structure, not a title profile）
- 当前 adapter：`hook/adapters/smash_fzmedia_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`supported`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x64；证据：runtime_observation — Fate/stay night REMASTERED v1.1.127 (fsn2-win64vc14-release.exe) was measured as a single x64 process with no child processes on 2026-09-04; the adapter is x64-only and the x86 build compiles an inert stub.
- `pe_imports`：null-ge-*.dll: ?bindGameEngine_*@@YAPEAVIGameEngine@fw@smash@@XZ；证据：runtime_observation — The main executable imports the smash framework engine factory from a DLL whose name starts with null-ge-; the adapter walks the PE64 import directory for a null-ge- module exporting a symbol containing IGameEngine@fw@smash@@ (measured 2026-09-04). No executable or module SHA-256 gate is used.
- `runtime_modules`：fzmedia-*.dll: ?create@SoundManager@sound@fz@@, ?play@SoundObject@sound@fz@@, ?getId@SoundObject@sound@fz@@, ?convertToRawFile@SoundObject@sound@fz@@, ?isReady@SoundObject@sound@fz@@；证据：runtime_observation — fzmedia-win64vc14-release-dynamic.dll was loaded by the measured sample and exports the fz::sound MSVC-decorated API; the adapter requires every listed export prefix on a loaded fzmedia- module before claiming the engine (2026-09-04).
- `resource_extensions`：.fcd；证据：runtime_observation — Character voice resource ids observed through SoundManager::create end in .fcd (FCD container: 'FCD\0', u16be version, u16be flags with bit 0 = encrypted, u32be header size); fzmedia decrypts in place and convertToRawFile yields the complete Ogg Vorbis file (2026-09-04).

文本能力：

- `engine_exact_utf16_hook`：`implemented_unverified` — The KAG TextLayerBase::layoutChar detour (anchors derived from RTTI + call shape) copies each run's UTF-16 text and per-glyph cells; paragraphs are merged across [r] runs while the CJK quote balance is open and published through the native text lane (source kind 6). Only offline synthetic-image tests exist; no same-session real-game text_ready evidence is recorded.
- `ingame_lookup_geometry`：`implemented_unverified` — Layer-unit glyph cells are projected with the uniform 1920x1080 stage fit plus a host-solved layer origin; readiness fails closed without an origin or with any inked cell outside the client rect. No real-session hit or card E2E is recorded.
- codepage：UTF-16
- 线程提示：Select the native 'smash exact' thread (ENGINE:SMASH:kag_text_layer); it carries whole paragraphs, not per-glyph draws.

音频优先级：

1. `smash_fzmedia_fcd_ogg_resource` — `implemented_unverified`；格式：ogg_vorbis；clean voice：是
2. `process_loopback` — `implemented_unverified`；格式：mixed process loopback PCM；clean voice：否

真实样本证据：


已知限制：

- XInput / joystick input has no shield; only Win32 messages, raw input and GetKeyState surfaces are covered by the generic shield plus the GLFW30 window subclass.
- The text layer origin inside the 1920x1080 stage is not readable from the layer object; it is solved by the host from a frame (PublishLookupLayerLine / ReadLookupLayerOrigin) and geometry stays unready until that solution exists for the current client size.
- Paragraphs are merged across runs by CJK quote balance (「」『』（）) with a 2500 ms continuation window; unbalanced narration or unusual quoting can split or merge lines differently from the on-screen page, and a continuation arriving after the partial publication republishes the merged text as a new text event.
- Text lane events are written when a balanced run starts (whole run text is available at index 0); glyph cells follow at run end. Voice pairing therefore uses the run-start timestamp, but a paragraph whose merged publication lands more than 1500 ms after SoundObject::play falls back to the unmarked resource filename.
- Steam retail (SteamStub) builds are unmeasured: the anchor rescan strategy exists but has not been exercised against a packed executable; the measured sample was already unpacked.
- The decrypted vector returned by convertToRawFile is released through the CRT operator delete that fzmedia imports, honouring the vc14 STL big-allocation shape; when the shape cannot be validated the buffer is intentionally leaked (kXAudioDiag2SmashVoiceBufferLeaked) rather than risk heap corruption.
- No real-session process_found -> text_ready -> resource_observed -> paired -> card E2E ledger exists yet; every capability above is offline-tested only and the convertToRawFile output has not been hash-compared with the in-place decrypted payload.

Fixtures：`tests/fixtures/smash_fzmedia_replay.json`

Tests：`tests/smash_fzmedia_adapter_test.cpp`、`tests/smash_fzmedia_lookup_test.cpp`、`tests/adapter_structure_test.py`、`tests/engine_support_manifest_test.py`、`tests/galhook_workflow_test.py`

### M2 wind3d11 runtime (STEINS;GATE RE:BOOT) (`sgre`)

- 状态：`implemented_unverified`
- 别名：SGRE、STEINS;GATE RE:BOOT、wind3d11
- 家族：`m2_wind3d11`（M2 wind3d11 audio-archive runtime）
- 当前 adapter：`hook/adapters/sgre_adapter.inc`
- 进程策略：launch=`create_suspended_preferred`，attach=`supported_for_objects_created_after_attach`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x64；证据：runtime_observation — Luna text profile config/luna_hook_profiles.tsv:5 records an x64 Steam build; the audio path has no independent hashed sample yet.
- `directory_files_all`：wind3d11data/voice_body.bin；证据：runtime_observation — The wind3d11 runtime keeps character voices in voice_body.bin next to the executable. Archive membership proves only the resource-audio capability; text/lookup may establish the engine family independently through the complete signature and object-ABI proof. No executable name, local path or hash is a family gate.
- `hashes`：75A83A0E2A7E22055417AE0474B47BE98418C4E42C695C548B558705C404B9D8；证据：runtime_observation — One measured build row in hook/adapters/sgre_anchors.h records the observed TextRender draw boundary, scenario-text vtable and DirectInput mouse-slot RVAs. The digest is diagnostic and, on that exact build, asserts that signature-derived RVAs still match the measurement; it never supplies hook addresses or rejects a hash miss. The published signatures were derived from this one sample, so cross-version runtime compatibility remains unverified.

文本能力：

- `ingame_lookup_geometry`：`implemented_unverified` — The SGRE draw adapter publishes renderer-native UTF-16 text and glyph geometry only after all-executable-section primary/corroborating signatures, decoded RIP targets, PE exception-directory bounds, scenario vtable slot 4 and object-layout gates agree. The mechanism is SHA/path/ASLR independent. 2026-09-03: original-path lookup + card E2E recorded on the measured executable (see verified_games); a second build is still not recorded.
- `ingame_lookup_directinput_shield`：`implemented_unverified` — The exact mouse-device global must be resolved independently by unique CreateDevice and immediate-poller signatures, and the live DirectInput COM vtable is validated before slot 9 is hooked. The 1,000-transaction real-build shield gate has not run.
- codepage：not_applicable
- 线程提示：The SGRE exact lane publishes game-parsed text with a stable ENGINE:SGRE:wind3d11 identity that excludes SHA, path, ASLR and resolved RVAs. The same resolved TextRender draw anchor supplies per-glyph lookup geometry; incompatible layouts publish neither lane nor provider.

音频优先级：

1. `engine_archive_resource` — `implemented_unverified`；格式：xWMA chunks taken verbatim from wind3d11data/voice_body.bin；clean voice：yes

真实样本证据：


已知限制：

- No real-game session has been run against this adapter: process_found through card_e2e are all not_run.
- Archive membership is the role proof, and it only holds while the runtime keeps character voice in a separate voice_body.bin.
- The emitted .xwma file is not byte-identical to an archive entry: the RIFF envelope is synthesised here. Only the fmt/dpds/payload chunks are verbatim.
- Only one SGRE executable has supplied measured anchor evidence. An unknown hash is admitted only when the current signature family, PE function boundary, vtable/object layout and live DirectInput ABI all agree uniquely; this is an implemented fail-closed compatibility mechanism, not evidence that arbitrary releases or compiler rebuilds are supported.
- The populated signatures were derived from that single measured binary. A non-unique signature, decoded-target mismatch, changed codegen/layout, unwind mismatch or ABI mismatch disables exact text, geometry and click interception and leaves the executable digest available for a future independently measured signature family.
- 2026-10-03 (PR #1917): the built-in Luna profile row pinned to the measured Steam x64 executable hash (HQFN-24@328E0 plus normalize-mages-controls) was removed under the no-per-game-hash rule, and with it the only Luna text fallback for that build. The fallback was deliberately given up, not replaced: the hook code is a build-specific RVA with no engine-level equivalent, and the engine-level text path is the SGRE exact lane resolved from structure. Consequence: when the exact lane does not come up (an unresolved/structurally inconsistent build, or the windowed-mode case BUG-2083 fixed in the metrics gate), Luna auto threads are the only text left and no pinned UTF-16 scenario hook backs them. Windowed-mode original-path re-test is pending: launch from the library in a 1920×1080 window, confirm the SGRE exact lane is auto-selected and publishes whole lines, and record the result; the windowed-mode E2E after BUG-2083 has not been recorded as evidence.
- MAGES control normalization (#RRGGBB; / %p; / %r) is switched on by engine identity, not by hash: the injector checks the wind3d11 voice archive next to the target executable before injection (same predicate as the adapter probe, include/sgre_family.h), so it applies from the first Luna line. A build without voice_body.bin is recognized only after injection, from the in-process text anchors via the adapter report (published at most once per second); Luna lines emitted before that report, or in sessions where the hook DLL never reports, keep the raw controls. Not measured on a real session.

Fixtures：尚无（P5 补齐）

Tests：`tests/sgre_adapter_test.cpp`、`tests/exact_lookup_signature_test.cpp`、`tests/adapter_structure_test.py`

### Unreal Engine (IoStore) (`unreal_iostore`)

- 状态：`implemented_unverified`
- 别名：Unreal Engine、UE4、UE5、アンリアルエンジン
- 家族：`unreal`（Epic Games Unreal Engine; this entry covers the IoStore (.utoc/.ucas) packaging only）
- 当前 adapter：`hook/adapters/unreal_iostore_adapter.inc`
- 进程策略：launch=`generic_launch_available`，attach=`generic_attach_available`，follow-child=`true`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：*-Win64-Shipping.exe；证据：real_sample — 昨日魔女今日的梦 1.0 汉化版 ships kinomajo\Binaries\Win64\kinomajo-Win64-Shipping.exe behind an outer kinomajo.exe launcher; static probe 2026-09-05. The name is a UE build convention and is catalogue only -- the adapter matches on the Binaries\Win64 directory shape plus IoStore archive magic, so -Win64-Test and -Win64-Debug builds are covered too
- `pe_architectures`：x64；证据：real_sample — kinomajo-Win64-Shipping.exe machine 0x8664; the launcher kinomajo.exe is x64 as well
- `directory_files_all`：Content/Paks/global.utoc、Content/Paks/global.ucas；证据：real_sample — Every IoStore build carries the global.utoc/global.ucas pair; this sample also has kinomajo-Windows.* and kinomajo-Windows_zh-CN_P.*. All three .utoc files open with the 16-byte IoStore TOC magic '-==--==--==--==-' followed by version byte 6, which is what the adapter actually matches on (any *.utoc under Content\Paks carrying that magic); measured 2026-09-05
- `pe_imports`：DSOUND.dll、WINMM.dll、OPENGL32.dll、WINHTTP.dll、MSVCP140.dll；证据：real_sample — PE import table of kinomajo-Win64-Shipping.exe (38 imports, static probe 2026-09-05). DirectSound is the only audio API imported statically; the UE tree also ships Engine\Binaries\ThirdParty\Windows\XAudio2_9\x64\xaudio2_9redist.dll for runtime loading, so the audio backend actually used at runtime was not determined
- `runtime_modules`：D3D12Core.dll、xaudio2_9redist.dll；证据：real_sample — Shipped next to the binary / under Engine\Binaries\ThirdParty; presence measured statically, runtime load not individually confirmed
- `resource_extensions`：.utoc、.ucas、.pak；证据：real_sample — Content\Paks holds paired .pak/.ucas/.utoc sets; the 2.7 GB kinomajo-Windows.ucas carries the asset payload including SoundWave assets
- `hashes`：f7018ae75f820a204bf48ac444d4688f3b7ccada51ae6b161ab701ecb0a492a2、877ff376a5e7233f903f778f6163e5e39924df1da9e5eeef055bb14b125026fd；证据：real_sample — kinomajo-Win64-Shipping.exe / kinomajo.exe launcher, catalogue only; the adapter does not hash-pin because the structural directory + IoStore magic check is the identity

文本能力：

- `luna_pc_hooks`：`implemented_unverified` — Unreal is a C++ engine with no scripting host to hook, so text goes through LunaHook's generic PC hooks. Measured both ways on the same title screen of the same build: without PC hooks text_events settled at 11, with them at 29. No dialogue line was traversed, so no thread was selected and no dialogue text is claimed.
- codepage：932
- 线程提示：Unmeasured. Only title-screen strings have been observed; the dialogue thread must be identified on a real session before any selection hint is recorded.

音频优先级：

1. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：source PCM via the generic Windows audio adapter；clean voice：engine_dependent
2. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Identity is anchored on IoStore only: the criterion requires Content\Paks\*.utoc with the 16-byte TOC magic. UE4 builds packaged as .pak alone do NOT match. This is deliberate -- the .pak magic (0x5A6F12E1) sits in a trailing footer whose offset varies by pak version, and no .pak-only sample was available to measure. Closing that gap needs a real .pak-only title.
- Per-line voice resources are SoundWave assets inside *.ucas, chunked and compressed by IoStore. No resource layer is implemented and none is claimed until a runtime post-unpack read seam is measured on a real session.
- Only title-screen strings have been observed. Dialogue text, thread selection, text/audio pairing and card E2E are all not_run.
- The runtime PCM measurement did not distinguish DirectSound from XAudio2; only 'the generic Windows audio path published PCM' is proved.
- In-game lookup sensor is not implemented; lookupAdmission stays EngineUnsupported.
- The shipping-binary criterion hard-codes the Win64 platform segment, so 32-bit UE packages under <Game>\Binaries\Win32 do NOT match and the whole Unreal path is inert for them. The measured sample is x64-only; no Win32 UE sample was available, and a platform segment is not guessed from a shape that was never measured.
- Auto-enabling LunaHook PC hooks was measured only through the explicit --luna-pchooks switch (11 vs 29 text_events). The automatic route reaches that switch by way of launcher detection plus child-process following, and is covered by offline tests only; it has not been re-measured end to end from the original launch entry.

Fixtures：`tests/fixtures/unreal_iostore_replay.json`

Tests：`tests/unreal_iostore_adapter_test.cpp`、`../../fushi/test/mining/unreal_iostore_pairing_test.dart`

### AOS / SFA (Princess Sugar, Atelier Kaguya family) (`aos_sfa`)

- 状态：`implemented_unverified`
- 别名：AOS、SFA、Princess Sugar、アトリエかぐや
- 家族：`aos_sfa`（In-house engine of the Princess Sugar / Atelier Kaguya family; no verified sibling in this repository）
- 当前 adapter：`hook/adapters/aos_sfa_adapter.inc`
- 进程策略：launch=`generic_launch_available`，attach=`generic_attach_available`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x86；证据：real_sample — The 姫様ＬＯＶＥライフ！ game executable is machine 0x14c (862720 bytes), importing DDRAW/DINPUT/DSOUND/d3d9/d3dx9_43; static probe 2026-09-05
- `directory_files_all`：scr.aos、cv.aos；证据：real_sample — Sample ships bgm/cv/grp/scr/se.aos next to the executable. All five open with four zero bytes, two little-endian u32 fields, and their own file name as NUL-terminated ASCII at offset 12 -- that self-naming header is what the adapter matches, not the extension; measured 2026-09-05
- `pe_imports`：DDRAW.dll、DINPUT.dll、DSOUND.dll、d3d9.dll、d3dx9_43.dll；证据：real_sample — PE import table of the 姫様ＬＯＶＥライフ！ executable (13 imports); DirectSound is the only audio API imported
- `resource_extensions`：.aos；证据：real_sample — cv.aos (675 MB) is the voice archive; grp.aos (2.99 GB) art, bgm/se.aos audio, scr.aos scripts
- `hashes`：fa965f070c0337098ca6abdb31c4c3d049d1480c3056a4db3b8bd43dd834b996；证据：real_sample — 姫様ＬＯＶＥライフ！ game executable, catalogue only; the adapter does not hash-pin because the self-naming archive header is the identity

文本能力：

- 不适用；文本由具体引擎 profile / Luna 线程处理。
- codepage：932
- 线程提示：Unmeasured. In the recorded session LunaHook connected but produced no output (luna_active 0, text_events 0) on the title screen; whether the vendored LunaHook carries an engine hook for this family is unverified.

音频优先级：

1. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：DirectSound source PCM via the generic Windows audio adapter；clean voice：engine_dependent
2. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- No text capability is claimed. LunaHook connected but emitted nothing in the recorded session, and the DLL does not expose engine names as strings, so there is no evidence either way yet.
- Per-line voice lives in cv.aos; no resource layer is implemented and none is claimed until the engine's own read path is measured on a real session.
- Only the title screen was reached. text_observed, text_thread_selected, paired and card_e2e are all not_run.
- The identity check requires at least one *.aos whose header names itself. Titles of this family that ship differently named or differently structured archives would not match, and none were available to measure.
- The sample was measured from a self-unpacked run directory where the exe sits beside its five *.aos archives. This is a retail disc title that was never installed, so the layout a normal installer produces was not measured: if it copies only the exe and leaves the archives on the disc, the directory criterion does not hold and the engine is simply not detected. Not guessed from a shape that was never measured.
- The recorded runtime evidence (StartupAudioHooksReady | LunaHostReady | LunaConnected plus non-silent PCM) is produced by the shared generic Windows audio path and looks identical when MatchesAosSfaProfile() returns false. It therefore does NOT confirm that the new identity criterion evaluates true on the real game; that has only been shown offline against synthetic archives.
- In-game lookup sensor is not implemented; lookupAdmission stays EngineUnsupported.

Fixtures：`tests/fixtures/aos_sfa_replay.json`

Tests：`tests/aos_sfa_adapter_test.cpp`、`../../fushi/test/mining/aos_sfa_pairing_test.dart`

### Unity (Mono runtime) (`unity_mono`)

- 状态：`implemented_unverified`
- 别名：Unity Mono、Unity 5、ユニティ
- 家族：`unity`（Same engine family as unity_il2cpp but the Mono scripting backend; the two adapters are mutually exclusive by construction）
- 当前 adapter：`hook/adapters/unity_mono_adapter.inc`
- 进程策略：launch=`generic_launch_available`，attach=`generic_attach_available`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x86、x64；证据：real_sample — カスタムメイド3D2 CHU-B LIP ships CM3D2OHx86.exe (machine 0x14c) and CM3D2OHx64.exe (machine 0x8664) side by side; static probe 2026-09-05. デスマッチラブコメ！ (KEMCO, Steam, Unity 2019.2.15f1 per <stem>_Data/app.info) ships DMLC.exe, UnityPlayer.dll and mono-2.0-bdwgc.dll all machine 0x14c; static probe 2026-09-27. センチメンタルデスループ (qureate, Steam, Unity 2021.3.10f1, Fungus) ships Sentimental Death Loop.exe, UnityPlayer.dll and MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll all machine 0x8664; the x64 Mono managed hooks ran on it 2026-09-28
- `directory_files_all`：<stem>_Data/Managed/Assembly-CSharp.dll、one of: <stem>_Data/Mono/mono.dll | MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll | MonoBleedingEdge/EmbedRuntime/mono-2.0-sgen.dll；证据：real_sample — Two runtime generations. Unity 5.x: <stem>_Data/Mono/mono.dll, present in CM3D2OHx64_Data (measured 2026-09-05). Unity 2017+ (.NET 4.x MonoBleedingEdge): the runtime sits beside the executable, not under <stem>_Data -- DMLC!/MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll with DMLC_Data/Managed/Assembly-CSharp.dll and no DMLC_Data/Mono (measured 2026-09-27; before the criterion accepted this generation neither Unity adapter claimed the sample). mono-2.0-sgen.dll is the SGen-GC build of the same runtime and is accepted by construction, not by a measured sample. The adapter additionally requires that GameAssembly.dll is ABSENT next to the executable -- that negative gate is what keeps unity_mono and unity_il2cpp mutually exclusive
- `runtime_modules`：mono.dll、mono-2.0-bdwgc.dll、mono-2.0-sgen.dll；证据：real_sample — <stem>_Data/Mono/mono.dll is the Unity 5.x Mono runtime. Note there is NO UnityPlayer.dll in that generation: it links the engine statically into the executable, which is exactly why UnityIl2CppAdapter::probe() and the injector's LooksLikeUnityRuntime() -- both of which require UnityPlayer.dll -- leave it unclaimed. The 2017+ generation loads MonoBleedingEdge/EmbedRuntime/mono-2.0-bdwgc.dll (sgen variant by construction) and does ship UnityPlayer.dll; the probe is structural on disk and does not wait for either module to load
- `resource_extensions`：.assets、.resS、.bundle；证据：real_sample — Standard Unity data layout under <stem>_Data (the 2019.2 sample additionally has resources.resource, the streamed AudioClip payload). The 2021.3 Fungus sample keeps its audio in Addressables bundles under <stem>_Data/StreamingAssets/aa/StandaloneWindows64: voice(scenario) / voice(action) / voice(gimmick) _assets_all_*.bundle (Vorbis, Compressed In Memory, mono 48 kHz) next to bgm (Streaming) / se / jingle bundles; the per-line voice layer extracts from the *voice*.bundle files the player opened
- `hashes`：5bb03fe8a924720f8da4df7a714565a8fcede94d2ef7b6f4b3b4e044f80d3eaa、7d79c2369e1a38107ccaaa9a089503506e05890edfda32d6eef25433612905c1、35416bad1a1d3132a187e45eadd197c490fccf6a674632fec7ac0816f28b5b2d、34d59c4a09cf08ca43488ffdfb601cc35a9bf3310a2b0b39b74bf64ee9219629；证据：real_sample — CM3D2OHx64.exe / CM3D2OHx86.exe / DMLC.exe / Sentimental Death Loop.exe (Steam), catalogue only; the adapter does not hash-pin because the structural Managed+Mono check is the identity

文本能力：

- `luna_hook`：`implemented_unverified` — LunaHook connected and produced output on the real sample (luna_active 1, LunaOutputObserved, text_events 7) but only title-screen strings were seen; no dialogue line was traversed and no thread was selected.
- `unity_mono_managed_text_events`：`implemented_unverified` — Offline only (2026-09-27). UnityMonoAdapter resolves managed text setters through the Mono embedding API exported by mono.dll / mono-2.0-{bdwgc,sgen}.dll (mono_assembly_foreach, mono_class_from_name, exact-signature method match, mono_compile_method on a temporarily attached HookWorker thread after Assembly-CSharp is loaded and a top-level window exists) and MinHook-detours the JIT entries of TMPro.TMP_Text.set_text + SetText(string,bool), UnityEngine.UI.Text.set_text and UnityEngine.TextMesh.set_text -- the same setters the IL2CPP path hooks -- publishing through the shared RecordUnityTextChars (same rich-text stripping, artifact gate and thread identity as IL2CPP). Detours use the Mono managed ABI (x86 cdecl with this first, x64 Win64; no trailing MethodInfo*) and read MonoString only via mono_string_length/mono_string_chars. For per-glyph TextMesh message frameworks, identified structurally in Assembly-CSharp by an instance `string Message.Mes(string, bool)` plus a static 8-parameter `Game.NewText(..., string str @3, ...)` glyph factory, the whole plain message is taken from Mes's return value and TextMesh.set_text is not hooked. Static metadata of デスマッチラブコメ！ (Unity 2019.2.15f1 x86) shows exactly that shape: no TMP or UI.Text references, TextMesh.set_text called only from Game.NewText/NewText_Center, and Message.Mes building LastMes. Covered by tests/unity_mono_text_test.cpp and adapter_structure_test; no runtime session has exercised any Mono detour.
- `unity_mono_fungus_say_events`：`implemented_unverified` — 2026-09-28. Fungus (public Unity VN framework): the whole-line entry `IEnumerator Fungus.SayDialog.DoSay(string, bool x5, AudioClip, Action)` resolved by namespace + class + full 8-parameter signature and required unique across images (Fungus.dll as its own assembly or compiled into Assembly-CSharp); both the Say command (Say -> StartCoroutine(DoSay)) and Fungus Lua `say()` (DoSay directly) pass through it. Its text argument is the line in the display language (localisation is resolved above it); Fungus `{...}` control tags are stripped with the TextTagParser rule (`\{.*?\}`, not across a line break; literal `\n` becomes a newline) and `<...>` by the shared RecordUnityTextChars, published on one scene-stable lane `Mono:Fungus.SayDialog.DoSay`. Speaker name plates stay on their own UI.Text / TMP component lanes; the SayDialog's story Text lane yields to the DoSay lane (it would repeat the whole line once per revealed glyph). Covered by tests/unity_mono_text_test.cpp. Injector-side on センチメンタルデスループ Steam x64 (Unity 2021.3.10f1, Fungus via Lua `say()`, Japanese selected in the game's own options): the DoSay lane carried the dialogue lines tag-free in Japanese (e.g. a two-line spoken line of 30 units with its trailing line break), the speaker name 「朝陽 乃愛」 arrived on the NameText component lane, and no UI.Text event of the story Text reached any lane. First runtime of the Mono managed detours on x64.
- codepage：932
- 线程提示：Fungus titles: select the `Unity Mono Fungus Say` lane (hook code Mono:Fungus.SayDialog.DoSay). Per-glyph message framework: the Message.Mes body lane. Other Mono titles unmeasured.

音频优先级：

1. `unity_audioclip_resource` — `implemented_unverified`；格式：AudioSource playback internal calls (PlayOneShotHelper / PlayHelper / Play(double); PlayOneShot / Play(ulong) on older players) -> clip name via Object.GetName -> Unity resource event with the *voice*.bundle the player opened; the injector extracts from that bundle or a sibling *voice*.bundle and caches clips found in none (BGM / SE / typing sounds); Fungus WriterAudio typing callbacks excluded, OnVoiceover always a candidate；clean voice：是
2. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：source PCM via the generic Windows audio adapter；clean voice：engine_dependent
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- This entry exists because the IL2CPP adapter and the injector's Unity heuristic both require UnityPlayer.dll, which the Unity 5.x generation does not ship. The v23 adapter readout confirmed on a live process that unity_il2cpp does not claim this family.
- Identity is structural (Managed assembly + Mono runtime, and GameAssembly.dll absent). Executable hashes are catalogued but not pinned.
- The 2017+ MonoBleedingEdge generation (デスマッチラブコメ！ x86, 2026-09-27) was unclaimed before the criterion accepted MonoBleedingEdge/EmbedRuntime/mono-2.0-{bdwgc,sgen}.dll; that session showed text only on generic MultiByteToWideChar LunaHook threads and audio fell back to process loopback (engine_pcm_unavailable). The widened identity is implemented_unverified: it has not been re-run on the sample. Unlike the 5.x generation, this generation ships UnityPlayer.dll, so the injector's LooksLikeUnityRuntime() already matches it (UnityPlayer.dll + <stem>_Data/Managed) and auto-enables LunaHook PC hooks; the identity change does not alter that.
- Per-line voice (2026-09-28, implemented_unverified): which clip is voice is proven by membership in a *voice*.bundle the player opened (the Unity-wide naming the IL2CPP path already relies on), checked out of process by the extractor; with no voice bundle seen nothing is published except a Fungus OnVoiceover clip (then the loose-asset fallback). AudioClip.GetData returned false on the sample's Compressed-In-Memory Vorbis clips, so there is no in-process PCM. Injector-side on the Fungus sample: the line's voice PlayOneShot fired in the same GetTickCount64 tick as its DoSay text event and the injector wrote <ts>_sce_0001.wav (5909 ms, mono 48 kHz, 283637 frames = the clip's sample count) and <ts>_sce_0002.wav (2662 ms) for two consecutive spoken lines (text-to-voice distance 0 ms); BGM001 / BGM006 / se_003 were extracted from no voice bundle and cached as non-voice; Fungus typing beeps produced no event. Games whose voice is not in a *voice*.bundle (loose assets, custom archives, StreamingAssets files) get no voice from this layer. The ready bit (reserved kDiagUnityAudioPlaybackHookReady) needs a Fushi runner built with the updated HasReadyGameResourceAudio.
- Only title-screen strings were observed. text_thread_selected, paired and card_e2e are all not_run.
- The Mono managed text hooks (unity_mono_managed_text_events) are offline-only: runtime gates (unity_mono adapter flags ScriptAssemblyReady / HookInstalled / DetourFired, and a text event whose hook code starts with `Mono:`) have not been observed on any game. The detours are native frames called directly from JIT code; a managed exception thrown by the original setter and caught above the detour is not unwound through them, which has not been exercised. The Message.Mes framework shape is backed by one title's static metadata only.
- In-game lookup (provider id 20) covers two structurally admitted frameworks only: the per-glyph TextMesh message framework and Fungus SayDialog on a UGUI Text; TextMeshPro story texts, World Space canvases and non-dynamic fonts are refused (lookupAdmission EngineUnsupported / sites rejected). A game's own overlay in the same scene (e.g. a Back Log panel dimming the dialog) is not modelled.

Fixtures：`tests/fixtures/unity_mono_replay.json`

Tests：`tests/unity_mono_adapter_test.cpp`、`tests/unity_mono_text_test.cpp`、`tests/unity_mono_lookup_test.cpp`、`../../fushi/test/mining/unity_mono_pairing_test.dart`

### YU-RIS (`yuris`)

- 状态：`implemented_unverified`
- 别名：YU-RIS、Yu-ris、ERIS
- 家族：`yuris`（YU-RIS script engine (YPF archives, YSTB scripts); CLOCKUP, あざらしそふと and other ERIS-based titles）
- 当前 adapter：`hook/adapters/yuris_adapter.inc`
- 进程策略：launch=`generic_launch_available`，attach=`generic_attach_available`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x86；证据：real_sample — euphoria (CLOCKUP 2011, update 1.02 executable) and アイカギ (あざらしそふと 2016) executables are machine 0x14c; static probe 2026-10-03
- `pe_imports`：GDI32.dll、USER32.dll、DSOUND.dll、d3d9.dll；证据：real_sample — Import tables of both sample executables: TextOutA is the only text API, GetKeyboardState feeds input, DirectSound plays the statically linked libvorbisfile output
- `resource_extensions`：.ypf、.ybn、.ogg；证据：real_sample — YPF members are YSTB scripts, PNG and Ogg Vorbis (zlib-packed or stored); per-line voice is the mono Ogg the script plays
- `hashes`：d30b992fc56a9e7ae8c3235664e929cd47eeaaa12ad74f8ddf8b7e15dec3184d、907cecc1b1024a8af1da691892388ab0373096bef47b140ffa6c24413259a851；证据：real_sample — euphoria.exe (update 1.02) and アイカギ.exe, catalogue only; the adapter does not hash-pin

文本能力：

- `yuris_message_text`：`implemented_unverified` — Native exact text lane (source kind 9, hook 'YU-RIS exact', ENGINE:YURIS:message_draw): the engine message text S+T (CP932, display characters only, NUL-terminated) is copied at the first DRAW call after it changed and published once per message as the engine's own text (ruby reduced to its base; a leading speaker name is kept, never stripped by shape, so narration such as 「そう言って「…」」 is not cut). Lookup splits a `NAME「…」` line only when one layer drew exactly the name and another the quoted part (the name plate is its own layer); without that structure the line is not mapped. Lane identity is the message state global, stable across runs. See lookup_support geometry for the site resolution.
- `luna_auto_or_pc_hooks`：`implemented_unverified` — LunaHook's YU-RIS engine hooks attach on euphoria (YU-RIS, YU-RIS2, YU-RIS5, YU-RIS6 threads); not used as the selected lane.
- `ingame_lookup_geometry`：`implemented_unverified` — Engine-exact message-layer provider kLookupGeometryProviderIdYuris (22), see lookup_support geometry.
- codepage：CP932
- 线程提示：Select the 'YU-RIS exact' lane.

音频优先级：

1. `yuris_decoder_input_voice_resource` — `implemented_unverified`；格式：mono Ogg Vorbis the engine hands to its statically linked ov_open_callbacks (the sound object's memory stream), named after the resource the script played；clean voice：not_verified
2. `directsound_pcm` — `implemented_unverified`；格式：generic DirectSound fallback；clean voice：engine_dependent
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Voice is taken only at the decoder input (the engine's ov_open_callbacks with its own memory-stream callbacks); no archive is read for audio. Stereo streams and streams over 1 MiB are not published; which mono clip is a voice line is left to the resource name the script played (the host's existing basename rules drop se_/bgm_ clips).
- The click claim masks the engine's GetKeyboardState table only; a build whose script advances on WM_LBUTTONDOWN directly is not covered.
- Only two titles were measured (euphoria 2011, アイカギ 2016); アイカギ was run with its loose Chinese-patch directories moved aside.
- The text lane drops the engine line-break code 0xEFF0; any other code outside CP932 fails that message closed (not published).
- Voice pairing: each newly published message binds only the last clip opened (by open order, not timestamp) within 1.5 s before it; every clip opened before a message that was refused, empty, too long or not a new page is published without an owner instead of waiting for the next line. Two consecutive identical lines (the engine opens no new page) and mono recollection/system voices can still pair with the next voiced-less line; needs a real-device check.
- Unverified on hardware: the ov_open_callbacks call site is assumed cdecl (only the read callback's shape is checked), and a build that keeps drawing glyphs while waiting for a click would refuse every press (fail closed). The stricter YPF identity (last entry exactly at index_end) must be re-checked against the euphoria v500 and アイカギ v481 archives.
- Inline ruby `≪base／reading≫` is published as its base; on such pages only glyphs of the line's largest font size are mapped (readings are drawn smaller).

Fixtures：`tests/fixtures/yuris_replay.json`

Tests：`tests/yuris_adapter_test.cpp`

### FVP (Favorite View Point) (`fvp`)

- 状态：`implemented_unverified`
- 别名：FAVORITE、Favorite View Point、FVP
- 家族：`fvp`（FAVORITE in-house HCB bytecode engine; no verified sibling）
- 当前 adapter：`hook/adapters/fvp_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`supported_before_voice_archive_open`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：World.exe、HoshimemoEH_HD.exe；证据：real_sample — Catalogue only: 2011 いろとりどりのセカイ (World.exe) and 2019 星空のメモリア Eternal Heart HD (原版备份 HoshimemoEH_HD.exe). The adapter never matches on names; identity is the self-consistent HCB script.
- `pe_architectures`：x86；证据：real_sample — Both sample executables are PE32 machine 0x14c
- `directory_files_all`：*.hcb；证据：real_sample — HCB script next to the exe (trailer: entry, globals, screen mode, title, syscall table with TextPrint/2) and the FVP .bin archives (count, names_bytes, 12-byte entries, name table, members back to back)
- `pe_imports`：DSOUND.dll、WINMM.dll、d3d9.dll、GDI32.dll；证据：real_sample — World.exe import table (GetGlyphOutlineA glyph rasterisation, mmio* archive reads, DirectSound playback); no GetAsyncKeyState / DirectInput import
- `resource_extensions`：.hcb、.bin；证据：real_sample — voice.bin: 18612 mono Ogg Vorbis members; bgm.bin stereo Ogg; se*.bin RIFF; graph*.bin hzc1 images
- `hashes`：World.exe sha256:e7749bfb633b1d536a53ef2dea07b289cb2bdc264e506d87cb2e7b9bda41d947、World.hcb sha256:8a7cdbf7345ad0e97cffdebb9d9d2456f68bc0bc61ac3eff84f4ad00b395132e、HoshimemoEH_HD.exe (原版备份) sha256:981393e8710c96d9f304bf951481d4736105db0c75b37ced06ee5fffe86c3995、HoshimemoEH_HD.hcb sha256:6d45ef890d99e72ae9af156d34f9e571eb3cf7d1db9ec01ca290c1533d867884；证据：real_sample — Catalogue only; the adapter does not hash-pin

文本能力：

- `fvp_text_print_hook`：`implemented_unverified` — Native exact text lane (source kind 10, hook 'FVP exact', ENGINE:FVP:text_print): the text object's Print, reached structurally from the TextPrint syscall handler (see lookup_acceptance.geometry), is detoured; the detour copies the CP932 string (bounded, < 512 bytes as the handler enforces) and the worker strips `[ruby|base]` ruby readings, converts to UTF-16 and publishes one lane per text buffer index. No Fushi-host text_ready run is recorded yet.
- `ingame_lookup_geometry`：`implemented_unverified` — Engine-exact text-buffer provider kLookupGeometryProviderIdFvp (23), see lookup_acceptance.geometry.
- codepage：932
- 线程提示：Select the 'FVP exact' lane of the dialogue text buffer (one lane per TextPrint buffer index).

音频优先级：

1. `fvp_decoder_input_ogg_resource` — `implemented_unverified`；格式：complete Ogg Vorbis stream the engine hands to its sound decoder (SoundLoad) from AudioPlay whose resource path has a `voice` directory component, named by that resource；clean voice：not_verified
2. `directsound_pcm` — `implemented_unverified`；格式：generic DirectSound fallback；clean voice：engine_dependent
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Single runtime sample family: the resolver is proven offline on two FAVORITE builds (2011, 2019 HD); other FVP generations may refuse and then install nothing.
- Geometry is offered only for a text prim drawn as a plain translation; rotated, scaled, UV-clipped or 3D text prims and non-zero surface origins fail closed.
- Voice is the bytes AudioPlay hands to the sound decoder (SoundLoad), copied only when the played resource path has a `voice` directory component (`voice/<entry>`, ASCII case-insensitive) and kept only as a complete Ogg Vorbis stream of at most 2 MiB; the channel count only corroborates the stream. A title that stores voice outside a `voice` directory publishes no voice, and streams longer than 2 MiB are skipped. A clip binds to the dialogue print of the same script dispatch, else to the next print in script order within 1.5 s, else it is published unowned; this assumes Print and Draw run on the game thread (otherwise only script order binds).

Fixtures：尚无（P5 补齐）

Tests：`tests/fvp_format_test.cpp`、`tests/fvp_lookup_test.cpp`

### Kogado Hy engine (`kogado_hy`)

- 状态：`implemented_unverified`
- 别名：工画堂スタジオ、Kogado Studio、Hy library
- 家族：`kogado_hy`（Kogado Studio in-house Borland C++Builder engine on its exported "Hy" runtime library; no verified sibling）
- 当前 adapter：`hook/adapters/kogado_hy_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`supported`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：SR.exe；证据：real_sample — Catalogue only: 2004 シンフォニック=レイン (SR.exe). The adapter never matches on names; identity is the exported Hy runtime library (THyRGBText::SetText, THyAlpha::BoxFill, THyAlpha::Draw).
- `pe_architectures`：x86；证据：real_sample — SR.exe is PE32 machine 0x14c
- `directory_files_all`：Script.pak、Voice/*.PAK；证据：real_sample — Catalogue only: Script.pak, Ev*.pak and Voice\srev%03d.pak next to SR.exe
- `pe_imports`：GDI32.DLL、DSOUND.DLL、DDRAW.DLL、USER32.DLL；证据：real_sample — SR.exe import table: TextOutA is the only text API (THyRGBText renders rows into an offscreen buffer), DirectSound plays, DirectDraw presents; mouse input arrives as VCL window messages
- `resource_extensions`：.pak；证据：real_sample — Voice\srev%03d.pak archives addressed by voice id / 1000000; script text is pre-wrapped rows separated by the script newline marker and closed by its page marker
- `hashes`：SR.exe sha256:04b4c08bb976c2a311d6a720433e5c20f38c24c1008464a773634c333479ce4c；证据：real_sample — Catalogue only; the adapter does not hash-pin

文本能力：

- `kogado_hy_message_page_hook`：`implemented_unverified` — Native exact text lane (source kind 11, hook 'Kogado Hy exact', ENGINE:KOGADO_HY:message_page; Fushi host run 2026-10-04: the lane is listed, folds each click unit into one line and pairs engine PCM voice with voiced lines): the message window's row renderer (the one function that renders a row through THyRGBText::SetText between THyAlpha::BoxFill and THyAlpha::Draw and whose every call site is fed by a counter-indexed page buffer) and the script's click wait (the one short game method that shows the window's wait cursor in both window modes, through the window field and mode byte the row fillers' caller reads) are detoured. A click unit runs from the row after a click wait (or row 0 of a cleared page) to the current row; the detour copies the page rows (bounded, 16 rows) and the worker drops the unit's speaker row (【name】), joins the rows, strips a continuation row's quote indent, converts from CP932 and republishes the unit so far at every row, so the host folds the rows of one unit into one line. Native run 2026-10-04 on the original path: adventure-window pages and full-screen-window paragraphs published as whole click units, speaker rows removed. No Fushi-host text_ready run is recorded yet.
- `luna_auto_or_pc_hooks`：`implemented_unverified` — LunaHook attaches only generic GDI hooks (TextOutA); each TextOutA call is one pre-wrapped row drawn seconds after the previous one, so that lane splits a page into rows. It is not used as the selected thread.
- `ingame_lookup_geometry`：`implemented_unverified` — Engine-exact message-window provider kLookupGeometryProviderIdKogadoHy (24), see lookup_support.geometry.
- codepage：932
- 线程提示：Select the 'Kogado Hy exact' lane; the TextOutA LunaHook lane splits every page into its rows.

音频优先级：

1. `directsound_pcm` — `implemented_unverified`；格式：generic DirectSound fallback；clean voice：engine_dependent
2. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Single sample: the resolver is proven offline on one executable (2004 Symphonic Rain); other Hy-engine titles may refuse and then install nothing. 37 x86 executables of RealLive, Siglus, BGI, CMVS, Leaf and other engines resolve to no Hy exports.
- The unit is the script's click unit (text between two click waits): one page of the 4-row adventure window, one paragraph of the 16-row full-screen window. If the click wait does not resolve, the adapter falls back to the page (correct for the adventure window, whole pages for the full-screen window) and logs the result.
- Voice reaches the host only through the generic DirectSound PCM capture, paired by time.

Fixtures：`tests/fixtures/kogado_hy_replay.json`

Tests：`tests/kogado_hy_adapter_test.cpp`

### LucaSystem (Prototype) (`luca`)

- 状态：`implemented_unverified`
- 别名：LucaSystem、LUCA System、Prototype
- 家族：`luca`（Prototype's Windows LucaSystem variants: x86 external boot configuration and OGGPAK members; x64 embedded configuration, packed language records and direct Ogg members. Structural implementation only; neither variant has release-eligible E2E evidence.）
- 当前 adapter：`hook/adapters/luca_adapter.inc`
- 进程策略：launch=`generic_launch_available`，attach=`generic_attach_available`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `pe_architectures`：x86、x64；证据：real_sample — Little Busters! English Edition (Steam) is Windows x86; Summer Pockets REFLECTION BLUE (Steam) is Windows x64. Protected code sites are resolved from the normally launched process's loaded executable sections, not the encrypted disk image. x64 structure and layout resolution were observed read-only on 2026-10-10; full x64 capture/lookup/card E2E remains pending.
- `directory_files_all`：files/*.PAK；证据：real_sample — x86 admission requires system.cnf with TARGET_PLATFORM and SCREEN_WIDTH/SCREEN_HEIGHT plus one fully valid PAK index. x64 builds may embed configuration and omit system.cnf: that branch requires two fully valid PAK indexes under files and installation separately requires unique x64 MESSAGE operand readers sharing the VM cursor and language-count contract. Archive voice discovery additionally scans bounded immediate subdirectories under files. No executable name, title or hash admits a profile.
- `pe_imports`：USER32.dll、GDI32.dll、DSOUND.dll、d3d11.dll、steam_api.dll；证据：real_sample — LITBUS_WIN32.exe import table: Direct3D 11 presents, DirectSound plays, mouse buttons are polled per frame through GetAsyncKeyState; catalogue only, the adapter never matches on imports
- `resource_extensions`：.pak、.ogg；证据：real_sample — Measured x86 voice members contain mono OGGPAK copies; measured x64 voice subdirectories contain PAK members beginning with complete Ogg Vorbis streams directly. Full index parsing and mono Vorbis validation govern admission; stereo BGM/SE and malformed/truncated streams are rejected. File extensions alone do not establish resource capability.
- `hashes`：LITBUS_WIN32.exe sha256:047748c47ab636b5a97954688c9cb3d0ee68de7960166eb427c4e00f6b3f172d、SummerPocketsRB.exe sha256:5eefbad2e39179f2905d066f140522663cebe7fa5dc6a13d69d5dc9a267ef0b7；证据：real_sample — Catalogue only; the adapter does not hash-pin

文本能力：

- `luca_message_text`：`implemented_unverified` — Native exact text lane (source kind 12, hook 'LucaSystem exact', ENGINE:LUCA:message): the scenario VM's MESSAGE handler is located by its operand shape (ReadU16 voice id, then a two-iteration ReadString loop for the per-language records; unique in the image, both readers end in `ret 4`) and the two operand readers are detoured, filtered by return address. The Japanese record is the one carrying kana/CJK; the `speaker@` prefix (or a lone `@`) is split off and $K keyword markers are stripped. Native run 2026-10-09 on the attached original Steam process: dialogue lines were published on the lane, protagonist lines without voice and voiced lines with their voice id. Fushi host run 2026-10-09: the 'LucaSystem exact' lane delivered clean Japanese lines; one session exported 216 per-line voice clips from VOICE0/VOICE2 and a real card was written with the matching sentence and voice (user report). Windows x64 implementation (2026-10-10, implemented_unverified): unique MESSAGE voice and language-loop shapes resolve Win64 readers, a shared VM cursor and a bounded runtime language count instead of assuming two records. The returned packed string object exposes validated UTF-8 or UTF-16LE ranges; callbacks only copy bounded bytes to preallocated slots. Worker Japanese-slot calibration uses a unique kana-bearing decoded body for the current VM and language count, excluding speaker-name kana; later CJK-only/punctuation-only bodies reuse that calibrated slot. Ambiguous or conflicting kana, VM/count changes and session shutdown invalidate calibration; before calibration, CJK alone cannot choose Japanese over Chinese. Synthetic ABI/language tests pass; read-only x64 MESSAGE resolver observations exist, while x64 native text publication and four-standard/card E2E remain pending.
- `luna_auto_or_pc_hooks`：`implemented_unverified` — LunaHook attaches generic hooks only; not used as the selected lane.
- `ingame_lookup_geometry`：`implemented_unverified` — Engine-exact text-object provider kLookupGeometryProviderIdLuca (25), see lookup_support geometry. Win64 implementation resolves the cText four-subobject reset shape, cross-checks model fields, row stride and a unique row-record accessor, and reads design dimensions from the draw routine's adjacent RIP-relative engine globals. Actual per-row drawing origins preserve alignment and vertical offsets. Both-architecture synthetic tests and the read-only x64 resolver probe passed on 2026-10-10; actual x64 click/Shift/touch/card operation remains pending.
- codepage：UTF-16LE; Win64 packed records may also carry validated UTF-8
- 线程提示：Select the 'LucaSystem exact' lane. On x64 a unique kana-bearing dialogue body must first calibrate the Japanese language slot; ambiguous/uninitialized language records are withheld.

音频优先级：

1. `luca_voice_pak_member` — `implemented_unverified`；格式：complete mono Ogg Vorbis addressed by the MESSAGE voice id in exactly one structurally validated PAK (member = voice id - archive first id); x86 OGGPAK selects the highest-rate complete copy and x64 also accepts one complete direct Ogg stream; bounded discovery covers files and its immediate subdirectories；clean voice：not_verified
2. `directsound_pcm` — `implemented_unverified`；格式：generic DirectSound fallback；clean voice：engine_dependent
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Only Windows x86 Little Busters! English Edition and Windows x64 Summer Pockets REFLECTION BLUE structural samples were measured. x64 is implemented_unverified: resolver/ABI tests and read-only structure observations do not prove actual text/voice pairing, lookup, no-advance input shielding or a real card. Other MESSAGE/cText ABIs refuse installation.
- Only the MESSAGE opcode is published; choices, titles and other text opcodes are not a lane.
- Voice comes from the PAK member addressed by the voice id, not from a played-buffer capture; a build that remaps voice ids at run time would publish the wrong member (not observed).
- The click claim samples the engine's per-frame GetAsyncKeyState poll; touch taps promoted to sub-frame WM_LBUTTONDOWN/UP passed the user's touch checklist once, but no injected-touch (InjectTouchInput) run is recorded.
- The lookup model requires exactly one live text object whose glyph records spell the selected line; ruby, multi-object pages and surrogate pairs fail closed.
- x64 Japanese language selection requires unique body-kana calibration; CJK-only or punctuation-only messages before calibration, conflicting kana and unsupported packed-string encodings are withheld. Changing VM identity/language count or ending the session clears calibration.
- Voice archive discovery is bounded to files and its immediate non-reparse subdirectories; deeper layouts and overlapping voice-id ranges fail closed or have no resource candidate. Direct Ogg must be a complete single mono Vorbis stream.

Fixtures：`tests/fixtures/luca_replay.json`

Tests：`tests/luca_adapter_test.cpp`、`tests/luca_x64_text_test.cpp`、`tests/luca_x64_lookup_test.cpp`

## 状态定义

- `verified`：已在真实游戏原始路径验证所列能力；只覆盖明确列出的版本与能力。
- `partial`：至少一条采集路径已真机验证，但仍有关键能力限制或未验证实现。
- `implemented_unverified`：代码已存在，但没有足够的真实游戏证据，不能宣称支持。
- `unavailable`：当前没有对应实现。
