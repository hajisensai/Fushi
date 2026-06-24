<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center"><b>책 한 권을 읽고, 모든 새 단어를 내 것으로 만드세요.</b></p>
<p align="center">멀티 플랫폼 · 다국어 몰입형 리더 —— EPUB 읽기 · 탭하여 단어 검색 · Anki 카드 만들기 · 오디오북 동기화 · 동영상 자막 단어 검색</p>

<p align="center">
  <img src="https://img.shields.io/badge/Android-3DDC84?logo=android&logoColor=white" alt="Android">
  <img src="https://img.shields.io/badge/iOS-000000?logo=apple&logoColor=white" alt="iOS">
  <img src="https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=white" alt="macOS">
  <img src="https://img.shields.io/badge/Windows-0078D6?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-FCC624?logo=linux&logoColor=black" alt="Linux">
  &nbsp;·&nbsp;
  <img src="https://img.shields.io/badge/Flutter-02569B?logo=flutter&logoColor=white" alt="Flutter">
  <img src="https://img.shields.io/badge/license-GPLv3-blue" alt="GPLv3">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>📖 프로젝트 홈페이지 (GitHub Pages)</b></a>
</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <b>한국어</b> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## 소개

**hibiki**는 멀티 플랫폼 몰입형 언어 학습 리더입니다. EPUB 본문 안에서 **탭하여 단어를 검색하고, 선택하여 분석**하며, 모르는 단어를 원탭으로 Anki 카드로 만들 수 있습니다. 오디오북 오디오를 본문과 한 문장씩 동기화하여 하이라이트하고, 심지어 동영상 자막에서 바로 단어를 검색하고 카드를 만들 수도 있습니다. 하나의 도구로 「읽기 · 듣기 · 보기」 세 가지 몰입형 입력을 모두 다룹니다.

사전 검색은 [Yomitan](https://github.com/yomidevs/yomitan)의 **모든 변환 언어**(활용 해제 + 검색 전 텍스트 정규화)를 지원하며, 인터페이스는 **17개 언어**로 현지화되어 있고, **Android / iOS / macOS / Windows / Linux** 다섯 플랫폼을 지원합니다.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-home.png" alt="책장" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-dictionaries.png" alt="단어 검색" width="300">
  &nbsp;
  <img src="../static-assets/screenshots/hibiki-readme-settings.png" alt="설정 및 테마" width="300">
</p>
<p align="center"><sub>책장 · 단어 검색 · 설정 및 테마</sub></p>

---

## 주요 기능

### 📖 EPUB 읽기, 탭하여 검색

WebView로 렌더링되는 EPUB 리더([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)에서 파생된 페이지네이션 엔진)로, 아무 단어나 탭하면 즉시 검색하고 선택 영역을 바로 분석합니다. 연속 스크롤과 페이지 넘김 두 가지 모드, 사용자 정의 글꼴과 테마(라이트 / 다크 / 순흑 / 사용자 정의), 후리가나, 독서 통계와 북마크까지 모두 갖추고 있습니다.

<p align="center">
  <img src="../static-assets/screenshots/hibiki-readme-reader.png" alt="세로쓰기 읽기 · 후리가나 · 오디오북 동기화" width="300">
</p>
<p align="center"><sub>세로쓰기 본문 · 후리가나 · 선택 하이라이트 · 하단 오디오북 동기화 컨트롤 바</sub></p>

### 🔍 탭하여 검색, Yomitan의 모든 변환 언어 지원

**Yomitan**(구 Yomichan) / **ABBYY Lingvo (DSL)** / **MDict (MDX)** / **Migaku** 등 여러 형식의 사전을 가져올 수 있습니다. 다국어 활용형 복원(Yomitan 변환표) + 검색 전 텍스트 정규화(대소문자 / 발음 구별 기호 / 아랍어 harakat)를 지원하며, 코드 포인트로 구동되어 언어 전환이 필요 없습니다. 다중 사전 병렬 검색, 하위 출처 우선순위와 켜고 끄기, 악센트 표기, 어휘 빈도——모두 하나의 팝업에서 해결됩니다.

### 🎴 원탭 Anki 카드 만들기

모르는 단어를 찾으면 [AnkiDroid](https://github.com/ankidroid/Anki-Android)와 AnkiConnect로 한 번에 내보냅니다. 내장된 [Lapis](https://github.com/donkuri/lapis) 노트 타입 schema(vendored 1.7.0)로 앱 안에서 직접 카드 템플릿과 덱을 만들 수 있습니다. 문맥 문장을 자동 입력하고, 녹음과 스크린샷 자르기, 다중 내보내기 프로필(Profile), 사용자 정의 필드 매핑, 퀵 액션을 통한 원스텝 카드 생성을 지원합니다.

### 🎧 오디오북 동기화 (Sasayaki)

SRT / LRC / VTT / ASS 자막을 지원하며, 자막 텍스트를 EPUB 본문에 자동으로 정렬합니다. 재생 시 **추적 하이라이트와 오디오 동기화 페이지 넘김**으로 들으면서 본문이 한 문장씩 켜집니다. 재생 컨트롤 바(진행률, 이동, 배속)와 함께——이 페이지 상단의 읽기 스크린샷 하단에 있는 컨트롤 바가 바로 이 기능입니다.

### 🎬 동영상 자막 단어 검색

media_kit / libmpv 기반의 동영상 플레이어를 내장하여 내장 자막과 외부 자막을 모두 지원합니다. 동영상 재생 중 **자막에서 바로 단어를 검색하고 카드를 만들** 수 있어, 영상 자료도 몰입형 입력에 포함합니다. 시청 시간과 카드 생성 수 통계도 기록합니다.

<!-- TODO-782: 待补视频播放器截图 -->
<p align="center"><sub>📹 동영상 플레이어 스크린샷은 추후 추가 예정 —— 실제 기기 / 포그라운드에서 캡처해야 합니다(동영상 화면 + 자막 바 + 단어 검색 팝업, 아래 설명 참조).</sub></p>

### 🔗 더 보기

- **17종 인터페이스 언어**, 전 플랫폼 현지화
- **Hibiki 상호 연결**: 기기 간 책 / 사전 / 오디오북 / 독서 진행률 동기화
- **다중 사용자 프로필(Profile)**, 책마다 자동 전환
- **시크릿 모드**; 다른 앱에서 **텍스트를 공유하여 바로 단어 검색**

---

## 플랫폼 지원

| 플랫폼 | 상태 | 렌더링 / UI |
|---|---|---|
| Android | ✅ | Material Design 3 |
| iOS | ✅ | Cupertino |
| Windows | ✅ | Material(fork한 `flutter_inappwebview_windows`로 EPUB 렌더링) |
| macOS | ✅ | Material |
| Linux | ✅ | Material |

> 최소 Android 7.0(API 24). 사전 검색의 언어는 가져온 사전과 Yomitan 변환표에 따라 결정되며, 인터페이스 언어와는 독립적입니다.

### 인터페이스 언어 (17종)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

---

## 설치 및 빌드

원커맨드 준비(`flutter pub get` + 패치 적용) 후 빌드합니다:

```bash
# 在仓库根目录
bash tool/bootstrap.sh          # Windows PowerShell：.\tool\bootstrap.ps1
                                # 或（Linux/macOS）：dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1`은 ①`flutter pub get`과 ②`ci/apply-patches.sh`를 한 커맨드로 묶습니다. 이 프로젝트는 Flutter 3.44.0(Dart SDK `>=3.5.0 <4.0.0`)으로 고정되어 있으며, 일부 업스트림 의존성은 `third_party/`에 vendor되거나 `ci/apply-patches.sh`로 패치됩니다——메커니즘 세부 사항, 5개 플랫폼 빌드, 의존성과 패치 목록은 [docs/agent/build.md](../agent/build.md)를 참조하세요.

<details>
<summary><b>기술 스택 한눈에 보기</b></summary>

| 계층 | 기술 |
|---|---|
| 프레임워크 | Flutter 3.44.0(Dart SDK `>=3.5.0 <4.0.0`) |
| 플랫폼 | Android / iOS / macOS / Windows / Linux(Material 3 + Cupertino 적응형) |
| 리더 | WebView 페이지네이션 엔진([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)에서 파생) |
| 동영상 | media_kit / libmpv |
| 스토리지 | Drift(SQLite, WAL) + hoshidicts(C++ FFI 사전 엔진) |
| NLP | Yomitan 변환표(다국어 활용형 복원) + kana_kit(가나 변환); 형태소 분석은 hoshidicts FFI |
| 카드 생성 | AnkiDroid API + AnkiConnect |
| 국제화 | Slang(17개 언어) |

</details>

<details>
<summary><b>프로젝트 구조</b></summary>

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
├── native/                  # hoshidicts C++ 사전 엔진 (FFI)
├── third_party/             # vendored 패치 패키지 (dependency_overrides가 지정)
├── ci/                      # 빌드 패치 및 통합 테스트 스크립트
├── tool/                    # bootstrap / i18n_sync 등의 스크립트
└── docs/                    # 개발 문서 (docs/agent/ 에이전트 운영 매뉴얼 포함)
```

</details>

---

## 감사의 말

| 프로젝트 | 설명 |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | 일본어 몰입형 학습 도구 |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android 일본어 리더 |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ 사전 엔진 |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS 일본어 리더 |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | 오디오북 동기화 솔루션 |
| [Yomitan](https://github.com/yomidevs/yomitan) | 사전 형식과 변환표 출처 |
| [Lapis](https://github.com/donkuri/lapis) | Anki 노트 타입 |

## 라이선스

[GNU General Public License v3.0](../../LICENSE)

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <b>한국어</b> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>
