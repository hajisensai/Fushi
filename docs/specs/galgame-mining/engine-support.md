# Galgame 引擎支持矩阵

> 此文件由 `engine-support.yaml` 通过 `tools/generate_engine_support.py` 自动生成，禁止手工编辑。
> 状态基线：2026-07-21；来源：`hajisensai/hibiki/docs/specs/galgame-mining/engine-adapter-plan.md`（1. 当前真相）。
> “已验证”只代表下方明确列出的真实样本、版本和能力，不外推到同家族的其它游戏。

## 总览

| ID | 引擎 / 后端 | 状态 | 文本 | 音频优先级 | 已验证样本 |
|---|---|---|---|---|---|
| `siglus` | SiglusEngine | `verified` | engine_exact_utf16_hook (implemented_unverified)；luna_hook (implemented_unverified) | resource_audio (verified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `kirikiri_z` | KiriKiriZ | `partial` | luna_auto_or_pc_hooks (implemented_unverified) | kirikiri_resource_stream (implemented_unverified)；kirikiri_decoder_pcm (implemented_unverified)；directsound_pcm (verified)；process_loopback (verified) | 1 |
| `xaudio2_directsound` | XAudio2 / DirectSound generic capture | `verified` | — | xaudio2_source_voice_pcm (verified)；directsound_buffer_pcm (verified) | 1 |
| `renpy_ffmpeg54` | Ren'Py / FFmpeg 54 | `implemented_unverified` | luna_auto_or_pc_hooks (implemented_unverified) | ffmpeg54_decoder_pcm (implemented_unverified)；process_loopback (verified) | 1 |
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

### KiriKiriZ (`kirikiri_z`)

- 状态：`partial`
- 别名：吉里吉里Z、Kirikiri Z
- 家族：`kirikiri`（KiriKiri family）
- 当前 adapter：`hook/adapters/kirikiri_adapter.inc`
- 进程策略：launch=`create_suspended_early_injection`，attach=`limited_after_audio_device_creation`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：otomeki.exe；证据：real_sample — otomeki.exe 32-bit integration run, hibiki handoff 2026-07-18
- `pe_architectures`：x86；证据：real_sample — otomeki.exe 32-bit integration run
- `runtime_modules`：dsound.dll；证据：runtime_observation — DirectSoundCreate -> CreateSoundBuffer -> Unlock observed in otomeki.exe

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — Generic Luna plumbing exists; the P0 baseline does not record a versioned text-thread replay.
- codepage：game-specific
- 线程提示：Reject metadata/per-character noise and select the stable dialogue thread manually when auto-selection is ambiguous.

音频优先级：

1. `kirikiri_resource_stream` — `implemented_unverified`；格式：engine stream / Ogg when available；clean voice：not_verified
2. `kirikiri_decoder_pcm` — `implemented_unverified`；格式：wuvorbis / wuopus decoder output when available；clean voice：not_verified
3. `directsound_pcm` — `verified`；格式：44100 Hz / stereo / signed 16-bit in the verified sample；clean voice：否
4. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **otomeki.exe sample**（x86，not recorded，2026-07-18）：Hibiki launched the game through the x86 injector and read three seconds of non-silent 44100/2/16 PCM through the real shared-memory channel. SHA-256：未记录。

已知限制：

- The verified KiriKiriZ sample software-mixes into one DirectSound output stream, so captured PCM is equivalent to loopback and includes BGM/SE.
- Clean per-channel voice has not been verified.
- The sample executable hash and engine version were not recorded; executable name alone is not a reusable engine signature.

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

### Ren'Py / FFmpeg 54 (`renpy_ffmpeg54`)

- 状态：`implemented_unverified`
- 别名：Ren'Py、libavcodec-54、libavformat-54
- 家族：`renpy`（legacy FFmpeg 1.0-era runtime）
- 当前 adapter：`hook/adapters/renpy_adapter.inc`
- 进程策略：launch=`launcher_then_child_python_requires_follow`，attach=`implemented_for_target_process_only`，follow-child=`false`

识别签名（所有非空项均带真实样本或运行时观察证据）：

- `executable_names`：Sakura Swim Club.exe；证据：real_sample — Sakura Swim Club full-card run recorded in hibiki handoff 2026-07-18
- `pe_architectures`：x86；证据：runtime_observation — Recorded Ren'Py sample launches a child python.exe targeted by the legacy hook
- `runtime_modules`：avcodec-54.dll、avformat-54.dll；证据：runtime_observation — The existing adapter targets the recorded legacy Ren'Py/FFmpeg runtime; the sample did not produce an adapter hit

文本能力：

- `luna_auto_or_pc_hooks`：`implemented_unverified` — No versioned text-thread replay is recorded for the sample.
- codepage：game-specific
- 线程提示：Select the child python process and its stable dialogue thread, not the launcher.

音频优先级：

1. `ffmpeg54_decoder_pcm` — `implemented_unverified`；格式：libavcodec/libavformat major 54 decoded PCM；clean voice：not_verified
2. `process_loopback` — `verified`；格式：host PCM fallback；clean voice：否

真实样本证据：

- **Sakura Swim Club**（x86 child python process，Ren'Py version not recorded，2026-07-18）：The end-to-end card path succeeded through process loopback; the engine adapter did not hit, so this is not evidence of FFmpeg adapter compatibility. SHA-256：未记录。

已知限制：

- Only libavcodec/libavformat major 54 with hand-maintained FFmpeg 1.0-era layouts is implemented.
- The recorded sample required following a child python process, which the injector does not yet do automatically.
- The real sample fell back to loopback; no clean decoder-level voice claim is made.

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
