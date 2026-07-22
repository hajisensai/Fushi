# Galgame 引擎支持矩阵

> 此文件由 `engine-support.yaml` 通过 `tools/generate_engine_support.py` 自动生成，禁止手工编辑。
> 状态基线：2026-07-23；来源：`hajisensai/hibiki/docs/specs/galgame-mining/engine-adapter-plan.md`（1. 当前真相）。
> “已验证”只代表下方明确列出的真实样本、版本和能力，不外推到同家族的其它游戏。

## 总览

| ID | 引擎 / 后端 | 状态 | 文本 | 音频优先级 | 已验证样本 |
|---|---|---|---|---|---|
| `siglus` | SiglusEngine | `verified` | engine_exact_utf16_hook (implemented_unverified)；luna_hook (implemented_unverified) | resource_audio (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `reallive` | RealLive / old VisualArt's | `implemented_unverified` | luna_hook (implemented_unverified) | visual_arts_ovk_resource (implemented_unverified)；xaudio2_or_directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `kirikiri_z` | KiriKiri2 / KiriKiriZ | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | kirikiri_resource_stream (implemented_unverified)；kirikiri_decoder_pcm (implemented_unverified)；directsound_pcm (verified)；process_loopback (verified) | 2 |
| `xaudio2_directsound` | XAudio2 / DirectSound generic capture | `verified` | — | xaudio2_source_voice_pcm (verified)；directsound_buffer_pcm (verified) | 1 |
| `renpy_ffmpeg` | Ren'Py / FFmpeg | `implemented_unverified` | luna_auto_or_pc_hooks (implemented_unverified) | ffmpeg_resource_event (implemented_unverified)；ffmpeg54_decoder_pcm (implemented_unverified)；process_loopback (verified) | 1 |
| `tyrano_nwjs` | TyranoScript / NW.js | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | tyrano_asar_voice_resource (verified)；ffmpeg_resource_event (implemented_unverified)；process_loopback (verified) | 1 |
| `bgi_ethornell` | BGI / Ethornell | `implemented_unverified` | luna_auto_or_pc_hooks (implemented_unverified) | bgi_arc20_voice_resource (implemented_unverified)；directsound_pcm (implemented_unverified)；process_loopback (implemented_unverified) | 0 |
| `artemis_pfs` | Artemis Engine / PF8 | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | artemis_pf8_voice_resource (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `unity_il2cpp` | Unity IL2CPP | `verified` | luna_pc_hooks (verified)；unity_tmp_events (verified) | unity_audioclip_resource (verified)；xaudio2_source_voice_pcm (verified)；process_loopback (verified) | 1 |

## 识别与能力明细

### SiglusEngine (`siglus`)

- 状态：`verified`
- 别名：Siglus 3、VisualArt's Siglus
- 家族：`visualarts`（VisualArt's / Key 系引擎）
- 当前 adapter：`hook/adapters/siglus_adapter.inc`
- 进程策略：launch=`normal_launch_then_delayed_attach_after_game_window`，attach=`supported`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：SiglusEngine.exe；证据：real_sample — anemoi 正式版，hibiki handoff 2026-07-19
- `pe_architectures`：x86；证据：real_sample — anemoi SiglusEngine 1.1.141.3
- `directory_files_all`：Gameexe.dat、Scene.pck；证据：real_sample — renamed Siglus executable regression fixed by hibiki-hook d1601b9
- `runtime_modules`：dsound.dll；证据：runtime_observation — anemoi used DirectSound through CoCreateInstance
- `resource_extensions`：.ovk；证据：real_sample — anemoi koe/*.ovk entries exported byte-identically
- `hashes`：algorithm=sha256, scope=game_executable, value=D94C94EB132FB1FCD6C20F35DD16552ED1301708B7A83DE07B275AD26C97D059, version=1.1.141.3；证据：real_sample — hibiki handoff 2026-07-19

文本能力：

- `engine_exact_utf16_hook`：`implemented_unverified` — The current hook contains the Siglus exact-text path, but P0 has no matching real-game evidence record.
- `luna_hook`：`implemented_unverified` — Generic Luna integration exists; version-specific Siglus verification is not recorded in the P0 baseline.
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

Fixtures：尚无（P5 补齐）

Tests：`tests/siglus_ovk_test.cpp`、`tests/siglus_launch_test.cpp`、`tests/siglus_text_test.cpp`

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

Fixtures：尚无（P5 补齐）

Tests：`tests/resource_audio_ready_test.cpp`

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

真实样本证据：

- **Recorded real-game set**（x86 verified; x64 build covered，mixed，2026-07-18/19）：The generic capture path produced non-silent PCM on the KiriKiriZ and Siglus samples; the baseline also records XAudio2 real-game verification without a versioned sample hash. SHA-256：未记录。

已知限制：

- A backend hit does not prove clean voice: software-mixed buffers can be equivalent to loopback.
- Attach cannot retroactively hook already-created engine/source objects.
- The P0 baseline does not contain a named, hashed XAudio2 sample, so compatibility must be re-verified per engine.

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

### Unity IL2CPP (`unity_il2cpp`)

- 状态：`verified`
- 别名：Unity、UnityPlayer IL2CPP
- 家族：`unity`（IL2CPP runtime）
- 当前 adapter：`hook/adapters/unity_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`supported_with_reduced_audio_coverage`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：manosaba.exe；证据：real_sample — manosaba_game runtime recorded in hibiki-hook README
- `pe_architectures`：x64；证据：real_sample — manosaba_game Unity IL2CPP sample
- `directory_files_all`：UnityPlayer.dll、GameAssembly.dll、*_Data/il2cpp_data/Metadata/global-metadata.dat；证据：real_sample — manosaba_game directory inspection recorded in hibiki-hook README
- `runtime_modules`：UnityPlayer.dll、GameAssembly.dll；证据：runtime_observation — manosaba_game Unity IL2CPP sample

文本能力：

- `luna_pc_hooks`：`verified` — PC hooks are auto-enabled for the recorded Unity IL2CPP layout.
- `unity_tmp_events`：`verified` — The baseline records TMP/text and AudioClip resource pairing on a real IL2CPP sample.
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

Tests：`tests/unity_event_cursor_test.cpp`、`tests/il2cpp_thread_scope_test.cpp`、`tests/resource_audio_ready_test.cpp`

## 状态定义

- `verified`：已在真实游戏原始路径验证所列能力；只覆盖明确列出的版本与能力。
- `partial`：至少一条采集路径已真机验证，但仍有关键能力限制或未验证实现。
- `implemented_unverified`：代码已存在，但没有足够的真实游戏证据，不能宣称支持。
- `unavailable`：当前没有对应实现。
