# Galgame 引擎支持矩阵

> 此文件由 `engine-support.yaml` 通过 `tools/generate_engine_support.py` 自动生成，禁止手工编辑。
> 状态基线：2026-07-23；来源：`hajisensai/hibiki/docs/specs/galgame-mining/engine-adapter-plan.md`（1. 当前真相）。
> “已验证”只代表下方明确列出的真实样本、版本和能力，不外推到同家族的其它游戏。

## 总览

| ID | 引擎 / 后端 | 状态 | 文本 | 音频优先级 | 已验证样本 |
|---|---|---|---|---|---|
| `siglus` | SiglusEngine | `verified` | engine_exact_utf16_hook (implemented_unverified)；luna_hook (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | resource_audio (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `elf_ai6` | elf AI6 | `implemented_unverified` | luna_textouta_hook (implemented_unverified) | ai6_voice_arc_resource (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `reallive` | RealLive / old VisualArt's | `implemented_unverified` | luna_hook (implemented_unverified) | visual_arts_ovk_resource (implemented_unverified)；xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `cmvs` | CMVS (Purple Software) | `implemented_unverified` | luna_hook (implemented_unverified) | xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `kirikiri_z` | KiriKiri2 / KiriKiriZ | `partial` | luna_auto_or_pc_hooks (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | kirikiri_resource_stream (implemented_unverified)；kirikiri_decoder_pcm (implemented_unverified)；directsound_pcm (verified)；process_loopback (verified) | 2 |
| `xaudio2_directsound` | XAudio2 / DirectSound generic capture | `verified` | — | xaudio2_source_voice_pcm (verified)；directsound_buffer_pcm (verified)；xwma_compressed_resource (implemented_unverified) | 1 |
| `renpy_ffmpeg` | Ren'Py / FFmpeg | `implemented_unverified` | luna_auto_or_pc_hooks (implemented_unverified) | ffmpeg_resource_event (implemented_unverified)；ffmpeg54_decoder_pcm (implemented_unverified)；process_loopback (verified) | 1 |
| `tyrano_nwjs` | TyranoScript / NW.js | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | tyrano_asar_voice_resource (verified)；ffmpeg_resource_event (implemented_unverified)；process_loopback (verified) | 1 |
| `bgi_ethornell` | BGI / Ethornell | `implemented_unverified` | luna_auto_or_pc_hooks (implemented_unverified) | bgi_arc20_voice_resource (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `artemis_pfs` | Artemis Engine / PF8 | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | artemis_pf8_voice_resource (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `catsystem2` | CatSystem2 / KIF INT | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | catsystem2_unencrypted_kif_voice_resource (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `malie_libp` | Malie System / LIBP CFI | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | malie_libp_cfi_voice_resource (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `qlie_filepack` | QLIE / FilePack | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | qlie_wuvorbis_per_source_pcm (verified)；qlie_wuvorbis_float_per_source_pcm (implemented_unverified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `unity_il2cpp` | Unity IL2CPP | `verified` | luna_pc_hooks (verified)；unity_tmp_events (verified)；unity_legacy_text_events (implemented_unverified) | unity_audioclip_resource (verified)；xaudio2_source_voice_pcm (verified)；process_loopback (verified) | 1 |
| `leaf_aquaplus` | Leaf / AQUAPLUS (WHITE ALBUM2 exact profile) | `implemented_unverified` | luna_exact_cp932_thread (implemented_unverified)；ingame_lookup_geometry (implemented_unverified)；ingame_lookup_sampled_input_shield (implemented_unverified) | leaf_lac_voice_resource (implemented_unverified)；directsound_pcm (implemented_unverified) | 0 |
| `hunex_gge` | HUNEX GGE / HFA-HW | `implemented_unverified` | luna_typemoon_dialogue_thread (implemented_unverified) | hunex_hfa_hw_ogg_resource (implemented_unverified) | 0 |
| `smash_fzmedia` | smash / fzmedia (TYPE-MOON smash framework) | `implemented_unverified` | engine_exact_utf16_hook (implemented_unverified)；ingame_lookup_geometry (implemented_unverified) | smash_fzmedia_fcd_ogg_resource (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `sgre` | M2 wind3d11 runtime (STEINS;GATE RE:BOOT) | `implemented_unverified` | ingame_lookup_geometry (implemented_unverified)；ingame_lookup_directinput_shield (implemented_unverified) | engine_archive_resource (implemented_unverified) | 0 |
| `unreal_iostore` | Unreal Engine (IoStore) | `implemented_unverified` | luna_pc_hooks (implemented_unverified) | xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `aos_sfa` | AOS / SFA (Princess Sugar, Atelier Kaguya family) | `implemented_unverified` | — | xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `unity_mono` | Unity (Mono runtime) | `implemented_unverified` | luna_hook (implemented_unverified) | xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |

## 无 OCR 内嵌查词矩阵

> 仅限 Windows x86/x64。OCR 被协议与范围守卫禁止；`xaudio2_directsound` 是通用音频后端，不计作引擎。

| 引擎 | 几何 provider | geometry | verified shield | risky left click |
|---|---|---|---|---|
| `kirikiri_z` | runtime_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `renpy_ffmpeg` | runtime_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `tyrano_nwjs` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `unity_il2cpp` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `elf_ai6` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `reallive` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `bgi_ethornell` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `catsystem2` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `malie_libp` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `qlie_filepack` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `artemis_pfs` | attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `siglus` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `leaf_aquaplus` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `hunex_gge` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `sgre` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |
| `smash_fzmedia` | engine_exact_layout、attached_calibrated | `implemented_unverified` | `implemented_unverified` | `implemented_unverified` |

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
- `reallive` geometry：The calibrated fallback is implemented offline; positioned GDI lineage has not been admitted for this engine.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `bgi_ethornell` geometry：The calibrated fallback is implemented offline; positioned GDI/DWrite lineage has not been admitted for this engine.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `catsystem2` geometry：The calibrated fallback is implemented offline; positioned GDI/DWrite lineage has not been admitted for this engine.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `malie_libp` geometry：The calibrated fallback is implemented offline; positioned GDI/DWrite lineage has not been admitted for this engine.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `qlie_filepack` geometry：The calibrated fallback is implemented offline; positioned GDI/DWrite lineage has not been admitted for this engine.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `artemis_pfs` geometry：The calibrated fallback is implemented offline; no uniquely traced hybrid positioned-text provider is admitted.
  - verified shield：The generic standard-surface shield is present, without the required real-build transaction corpus.
  - risky left click：Risk is accepted unconditionally (BUG-2154 removed the per-executable consent gate, which was unsatisfiable: the generic shield can never reach Verified); allow_risk still crosses the IPC contract, but no measured real-build click-leak rate is recorded.
- `siglus` geometry：The portable exact SHA-256 identity is followed by a hydrated-image gate that requires one glyph signature and one build-specific input signature across all executable sections, exact profile RVAs, and internal callgraph boundaries. Zero/multiple candidates and unknown hashes fail closed; lookup/card E2E is not recorded.
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

- `engine_exact_utf16_hook`：`implemented_unverified` — The current hook contains the Siglus exact-text path, but P0 has no matching real-game evidence record.
- `luna_hook`：`implemented_unverified` — Generic Luna integration exists; version-specific Siglus verification is not recorded in the P0 baseline.
- `ingame_lookup_geometry`：`implemented_unverified` — The recorded anemoi 1.1.141.3 and Summer Pockets Reflection Blue 1.1.134.0 x86 SHA-256 profiles contain no install path or absolute virtual address. At runtime, the hydrated-image gate aggregates masked glyph/input candidates across every executable PE section, requires exactly one of each at the profile RVAs, admits only the measured 0xDC/0xEC glyph stack ABIs, and validates dialogue, exact-text, GetKeyState and input-message call boundaries before hooking. The protected on-disk anemoi image cannot prove hydrated uniqueness offline, and no original-path lookup/card E2E is recorded, so the capability remains implemented_unverified.
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
- In-game lookup geometry and input interception are hash-pinned exact profiles for the recorded anemoi SiglusEngine 1.1.141.3 x86 executable (including its measured virtualized .org self-read hash) and Summer Pockets Reflection Blue SiglusEngine 1.1.134.0 x86 executable SHA-256 190DF9A72929BD6B6327E773952B5C507C69052BC6D3FF16A4868BD1FF1791FD. SHA-256 identifies the same bytes on any machine; it is not tied to a local path. Unknown hashes, non-unique hydrated signatures, wrong RVAs or failed callgraph checks all reject lookup. Native offline coverage does not replace an original-path lookup and same-session card-mining E2E, so this capability remains implemented_unverified.
- The Summer Pockets Reflection Blue profile retains its exact SHA-256/RVA admission and its measured shared glyph plus build-specific input pattern, but no currently available hydrated real process was used to re-prove image-wide uniqueness in this change. It therefore remains implemented_unverified and is not generalized to another Siglus build.

Fixtures：尚无（P5 补齐）

Tests：`tests/siglus_ovk_test.cpp`、`tests/siglus_launch_test.cpp`、`tests/siglus_text_test.cpp`、`tests/siglus_lookup_test.cpp`、`tests/exact_lookup_signature_test.cpp`、`tests/adapter_structure_test.py`

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

- `resource_extensions`：.ovk；证据：real_sample — anemoi VisualArt's/Siglus koe/*.ovk proves the shared container path only; it is not RealLive compatibility evidence

文本能力：

- `luna_hook`：`implemented_unverified` — A RealLive dialogue-thread fixture and real sample are still required.
- codepage：game-specific
- 线程提示：Select a stable RealLive/Luna dialogue thread after real-sample probing.

音频优先级：

1. `visual_arts_ovk_resource` — `implemented_unverified`；格式：strict u32 count + 16-byte entries + complete Ogg/EOS；clean voice：not_verified
2. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：generic source PCM fallback；clean voice：engine_dependent
3. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Format sharing with verified Siglus OVK is not evidence that a RealLive title is compatible.
- NWK/KOE/NWA remain unevaluated because no real old VisualArt's sample is available; no parser or support claim is added for them.
- A real original-path run must add executable/module hashes, text-thread evidence and byte-identity proof before promotion.

Fixtures：`tests/fixtures/reallive_replay.json`

Tests：`tests/reallive_adapter_test.cpp`

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

- `luna_hook`：`implemented_unverified` — Vendored LunaHook32/64 both carry the EmbedCMVS engine hook; no real-session dialogue thread has been observed yet.
- codepage：932
- 线程提示：Prefer the LunaHook EmbedCMVS thread once observed; the adapter installs no text hook of its own.

音频优先级：

1. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：DirectSound source PCM via the generic Windows audio adapter；clean voice：engine_dependent
2. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- Per-line voice resources live inside CPZ6-encrypted voice.cpz / voice2.cpz; no resource layer is implemented and none is claimed until a runtime decrypt-read seam is measured on a real session.
- Identity is structural (cmvs.cfg section + CPZ archive magic); executable hashes are catalogued but not pinned.
- In-game lookup sensor is not implemented; lookupAdmission stays EngineUnsupported.

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

- `luna_auto_or_pc_hooks`：`implemented_unverified` — Generic Luna plumbing is present; no stable BGI dialogue thread has been selected on the official sample yet.
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

真实样本证据：

- **CatSystem2 入門セット v3.01 — local voice replay**（x86，cs2_open.exe 2.6.1.67，2026-07-23）：ARES official engine and MakeInt tool with a locally generated 4.183220-second TTS voice. Real pcm playback exported D0213_02_001.ogg (26,897 bytes, SHA-256 D3D7C4A1F08B2A82DB1B4E4416B257B88047A774CAD8EBB6DDFD0728A5BA9E00), exactly matching both the source and KIF member. This verifies the unencrypted developer KIF path, not encrypted commercial-title compatibility. SHA-256：D1889D60DBE3350B068605F94A49AE8E93EB388CE66E7ABC36607EED2EDA7010。

已知限制：

- Encrypted commercial KIF archives containing __key__.dat use title-specific Blowfish material and are deliberately rejected; no commercial-title resource-audio claim is made.
- Only Ogg members in pcm_*.int are classified as voice; loose developer-mode files and non-Ogg voice formats fall back to source PCM or loopback.
- Audio is verified for the official starter-kit replay, but stable automatic CatSystem2 text-thread selection remains unverified.

Fixtures：尚无（P5 补齐）

Tests：—

### Malie System / LIBP CFI (`malie_libp`)

- 状态：`partial`
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

- `luna_auto_or_pc_hooks`：`implemented_unverified` — The resource-audio run disabled Luna; no stable Malie dialogue thread is claimed.
- codepage：CP932 / localized build dependent
- 线程提示：Select a complete-line Malie dialogue thread after enabling Luna on a supported title.

音频优先级：

1. `malie_libp_cfi_voice_resource` — `verified`；格式：complete decrypted Ogg member from title-scoped data2.dat；clean voice：是
2. `directsound_pcm` — `verified`；格式：generic source PCM fallback；clean voice：engine_dependent
3. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **Dies irae ~Amantes amentes~ — free common route**（x86，Malie System 1.0.0.5; Steam build 21665074，2026-07-23）：Official free Steam release. Suspended direct launch captured v_ma2056.ogg (62,028 bytes, 44.1 kHz mono Vorbis, SHA-256 4FEFD3841D465BE76DBC41566E0BC26EDBA09F189EC533C213A450FA8A777FAD), exactly matching the corresponding GARbro-decrypted data\voice\ma\v_ma2056.ogg member at offset 737,280. SHA-256：CFDAA598422245A36B2333F1E923C8E808412D0360C86EF83D914ADF4D6EA926。

已知限制：

- CFI keys and rotation words are title/version specific. This implementation is deliberately limited to the measured non-HD Dies irae ~Amantes amentes~ scheme; HD, 4:3 patch, and other Malie titles require separate evidence.
- Only data2.dat is classified as voice for the verified title. data1.dat BGM and data3.dat environment Ogg files are deliberately excluded.
- Default Steam protocol attach can miss startup-prefetched resource reads. Clean capture is verified with explicit --force-direct-launch; titles that reject inherited AppID direct launch retain DirectSound/loopback fallback.
- Audio is verified, but stable automatic Malie text-thread selection remains unverified.

Fixtures：尚无（P5 补齐）

Tests：—

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
- `unity_legacy_text_events`：`implemented_unverified` — Sasasa.exe was exercised through Hibiki launch/capture and produced complete Unity TextMesh lines; full offline gates were skipped by request.
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

- `pe_architectures`：x86、x64；证据：real_sample — カスタムメイド3D2 CHU-B LIP ships CM3D2OHx86.exe (machine 0x14c) and CM3D2OHx64.exe (machine 0x8664) side by side; static probe 2026-09-05
- `directory_files_all`：<stem>_Data/Managed/Assembly-CSharp.dll、<stem>_Data/Mono/mono.dll；证据：real_sample — Both present in CM3D2OHx64_Data. The adapter additionally requires that GameAssembly.dll is ABSENT next to the executable -- that negative gate is what keeps unity_mono and unity_il2cpp mutually exclusive. Measured 2026-09-05
- `runtime_modules`：mono.dll；证据：real_sample — <stem>_Data/Mono/mono.dll is the Mono runtime. Note there is NO UnityPlayer.dll: this Unity 5.x generation links the engine statically into the executable, which is exactly why UnityIl2CppAdapter::probe() and the injector's LooksLikeUnityRuntime() -- both of which require UnityPlayer.dll -- leave this family unclaimed
- `resource_extensions`：.assets、.resS；证据：real_sample — Standard Unity data layout under <stem>_Data; no per-line voice extraction is implemented for it
- `hashes`：5bb03fe8a924720f8da4df7a714565a8fcede94d2ef7b6f4b3b4e044f80d3eaa、7d79c2369e1a38107ccaaa9a089503506e05890edfda32d6eef25433612905c1；证据：real_sample — CM3D2OHx64.exe / CM3D2OHx86.exe, catalogue only; the adapter does not hash-pin because the structural Managed+Mono check is the identity

文本能力：

- `luna_hook`：`implemented_unverified` — LunaHook connected and produced output on the real sample (luna_active 1, LunaOutputObserved, text_events 7) but only title-screen strings were seen; no dialogue line was traversed and no thread was selected.
- codepage：932
- 线程提示：Unmeasured. Only title-screen strings have been observed.

音频优先级：

1. `xaudio2_or_directsound_pcm` — `implemented_unverified`；格式：source PCM via the generic Windows audio adapter；clean voice：engine_dependent
2. `process_loopback` — `implemented_unverified`；格式：host PCM fallback；clean voice：否

真实样本证据：


已知限制：

- This entry exists because the IL2CPP adapter and the injector's Unity heuristic both require UnityPlayer.dll, which the Unity 5.x generation does not ship. The v23 adapter readout confirmed on a live process that unity_il2cpp does not claim this family.
- Identity is structural (Managed assembly + Mono runtime, and GameAssembly.dll absent). Executable hashes are catalogued but not pinned.
- Per-line voice resources are Unity AudioClip assets; unity_events stayed 0 on the sample, so the existing Unity resource extractor produces nothing here. No resource layer is implemented and none is claimed.
- Only title-screen strings were observed. text_thread_selected, paired and card_e2e are all not_run.
- In-game lookup sensor is not implemented; lookupAdmission stays EngineUnsupported.

Fixtures：`tests/fixtures/unity_mono_replay.json`

Tests：`tests/unity_mono_adapter_test.cpp`、`../../fushi/test/mining/unity_mono_pairing_test.dart`

## 状态定义

- `verified`：已在真实游戏原始路径验证所列能力；只覆盖明确列出的版本与能力。
- `partial`：至少一条采集路径已真机验证，但仍有关键能力限制或未验证实现。
- `implemented_unverified`：代码已存在，但没有足够的真实游戏证据，不能宣称支持。
- `unavailable`：当前没有对应实现。
