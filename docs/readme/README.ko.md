<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Android용 일본어 몰입형 리더</p>
<p align="center">EPUB · 사전 · Anki · 오디오북 동기화</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <b>한국어</b> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## 소개

**hibiki**는 일본어 학습자를 위한 Android 독서 앱입니다.

## 기능

### EPUB 리더
- WebView에서 EPUB 렌더링 ([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)에서 파생된 페이지네이션 엔진)
- 탭하여 단어 검색, 텍스트 선택하여 분석
- 사용자 정의 글꼴, 테마 (라이트/다크)
- 독서 통계 및 북마크
- 연속 스크롤 / 페이지 넘김 두 가지 모드

### 사전
- [Yomitan](https://github.com/yomidevs/yomitan) 형식 사전 가져오기 (구 Yomichan)
- 악센트 표기 및 어휘 빈도 정보 지원
- 다중 사전 병렬 검색, 검색 기록
- Ve 활용형 복원

### Anki 카드 만들기
- [AnkiDroid](https://github.com/ankidroid/Anki-Android)로 원탭 내보내기
- 문맥 문장 자동 입력
- 녹음, 스크린샷 자르기 지원
- 다중 내보내기 프로필, 사용자 정의 필드 매핑
- 퀵 액션으로 한 단계 카드 생성

### 오디오북 동기화 (Sasayaki)
- 자막 형식: SRT / LRC / VTT / ASS
- 자막 텍스트를 EPUB 본문에 자동 정렬
- 추적 하이라이트, 오디오 동기화 페이지 넘김
- 재생 컨트롤 바 (진행률, 이동, 배속)

### 기타
- 17종 인터페이스 언어
- 다중 사용자 프로필
- 시크릿 모드
- 다른 앱에서 텍스트 공유하여 바로 단어 검색

## 지원 언어

인터페이스는 다음 언어를 지원합니다:

| 언어 | 코드 |
|---|---|
| English | `en` |
| 简体中文 | `zh-CN` |
| 繁體中文 | `zh-HK` |
| 日本語 | `ja` |
| 한국어 | `ko` |
| Español | `es` |
| Français | `fr` |
| Deutsch | `de` |
| Português (Brasil) | `pt-BR` |
| Русский | `ru` |
| Tiếng Việt | `vi` |
| ภาษาไทย | `th` |
| Bahasa Indonesia | `id` |
| Italiano | `it` |
| Nederlands | `nl` |
| Türkçe | `tr` |
| العربية | `ar` |

## 기술 스택

| 계층 | 기술 |
|---|---|
| 프레임워크 | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| 플랫폼 | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino 적응형) |
| 리더 | WebView 페이지네이션 엔진 ([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)에서 파생) |
| 스토리지 | Drift (SQLite, WAL) + hoshidicts (C++ FFI 사전 엔진) |
| NLP | Ve (활용형 복원) |
| 카드 생성 | AnkiDroid API |
| 국제화 | Slang (17개 언어) |
| 최소 버전 | Android 7.0 (API 24) |

## 빌드

원커맨드 준비 (`flutter pub get` + 패치 적용) 후 빌드합니다:

```bash
# 저장소 루트에서
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # 또는 (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1`은 두 가지 작업을 한 커맨드로 묶습니다: ①`flutter pub get`; ②`ci/apply-patches.sh` 실행. `melos bootstrap`도 post hook으로 동일한 작업을 수행합니다 (Windows에서는 melos에 CJK 인코딩 버그가 있으므로 `tool/bootstrap.ps1`을 사용하세요).

> **패치 설명:** `ci/apply-patches.sh`는 `ci/patches/` 아래의 변경 사항을 실제 pub cache에 덮어씁니다. pub cache를 초기화하거나 `flutter pub get`을 다시 실행할 때마다 다시 실행해야 합니다 (bootstrap에 이 단계가 포함되어 있습니다). 스크립트는 패치 대상을 찾지 못하면 성공한 척하지 않고 건너뛰고 경고합니다.

## 의존성 및 패치

이 프로젝트는 Flutter 3.44.0으로 고정되어 있으며, 일부 업스트림 의존성은 아직 호환되지 않습니다. 패치는 두 가지 메커니즘으로 나뉩니다: ① 빌드 입력으로 필요하고 머신 간에 일관되게 재현해야 하는 패키지는 `third_party/`에 직접 vendor하고 `dependency_overrides`로 지정합니다 (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, pub-cache 패치 **불필요**); ② 나머지 패키지는 `ci/apply-patches.sh`가 pub cache 소스를 패치합니다. 메커니즘 세부 사항은 [docs/agent/build.md](../agent/build.md)를 참조하세요. 아래 접기 표는 변경 내용별로 분류한 과거 목록이며, 메커니즘 ①과 겹치는 패키지는 vendored 버전이 우선합니다.

<details>
<summary><b>Flutter API 변경 패치</b></summary>

| 패키지 | 변경 내용 |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; 제거된 `imageCache.putIfAbsent` 대체 |
| `flutter_blurhash` 0.7.0 | 동일한 `loadImage` / `hashValues` / `ImmutableBuffer` 변경 |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | 내부 import에 `hide CarouselController` 추가하여 이름 충돌 방지 |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` nullable 수정 |

</details>

<details>
<summary><b>v1 Embedding 제거 패치</b></summary>

Flutter 3.44.0에서는 v1 embedding API (`PluginRegistry.Registrar`)가 완전히 제거되었습니다. 다음 플러그인에서 관련 참조를 삭제해야 합니다:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin 패치</b></summary>

| 대상 | 변경 내용 |
|---|---|
| `android/build.gradle` afterEvaluate | 서브프로젝트에 `compileSdk` 강제 적용 (기본 36, 일부 34); `-Werror` 제거 |
| `audio_session` 0.1.14 | `-Werror`, `-Xlint:deprecation` 제거 |
| `package_info_plus` 4.0.2 | Kotlin null 안전성 수정 |
| `receive_intent` (git) | Kotlin null 안전성 수정 |

</details>

<details>
<summary><b>Git 의존성</b></summary>

| 패키지 | 출처 |
|---|---|
| `blurrycontainer` | [arianneorpilla/blurry_container](https://github.com/arianneorpilla/blurry_container/) |
| `filesystem_picker` | [arianneorpilla/filesystem_picker](https://github.com/arianneorpilla/filesystem_picker) |
| `flutter_inappwebview` | [arianneorpilla/flutter_inappwebview](https://github.com/arianneorpilla/flutter_inappwebview) |
| `material_floating_search_bar` | [arianneorpilla/material_floating_search_bar](https://github.com/arianneorpilla/material_floating_search_bar) |
| `ruby_text` | [arianneorpilla/RubyText](https://github.com/arianneorpilla/RubyText) |
| `spaces` | [arianneorpilla/spaces](https://github.com/arianneorpilla/spaces) |
| `ve_dart` | [arianneorpilla/ve_dart](https://github.com/arianneorpilla/ve_dart) |
| `receive_intent` | [arianneorpilla/receive_intent](https://github.com/arianneorpilla/receive_intent) |
| `wakelock` | [diegotori/wakelock](https://github.com/diegotori/wakelock) |

</details>

## 프로젝트 구조

```
hibiki/                      # 저장소 루트 (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter 앱 메인 디렉토리
│   ├── lib/
│   │   ├── i18n/            # 국제화 (17개 언어, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # 페이지 (책장, 리더, 사전, 설정 등)
│   │   │   ├── reader/      # 리더 WebView JS/CSS 스크립트
│   │   │   ├── media/       # 오디오북, 자막 파싱, reader source
│   │   │   └── models/      # 데이터 모델 및 상태 관리 (AppModel)
│   │   └── main.dart
│   └── android/             # Android 프로젝트 (manifest, native hoshidicts)
├── packages/                # 내부 패키지 + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # vendored 패치 패키지 (dependency_overrides가 지정)
├── ci/                      # 빌드 패치 및 통합 테스트 스크립트
├── tool/                    # bootstrap / i18n_sync 등의 스크립트
└── docs/                    # 개발 문서 (docs/agent/ 에이전트 운영 매뉴얼 포함)
```

## 감사의 말

| 프로젝트 | 설명 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 일본어 몰입형 학습 도구 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 일본어 리더 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 사전 엔진 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 일본어 리더 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 오디오북 동기화 솔루션 |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB 렌더링 엔진 |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu 커뮤니티 유지보수 버전 (SvelteKit v2), hibiki fork의 업스트림 베이스 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 사전 형식 출처 |

## 라이선스

[GNU General Public License v3.0](../../LICENSE)
