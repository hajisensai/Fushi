# 히라사와 유이도 5분이면 설정하는 Fushi 사용 설명서

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | **한국어** | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> 간체 중국어 가이드는 Feishu에 호스팅되어 있습니다(위 링크). 영어 가이드는 [GitHub](https://github.com/hajisensai/Fushi/blob/main/docs/user-guide.md)에서도 볼 수 있습니다.

## 소개

**Fushi——정주행과 몰아 읽기를 그대로 언어 인풋으로.**

소설을 읽을 때, 애니메이션을 볼 때, 오디오북을 들을 때 단어를 탭하기만 하면 바로 찾아볼 수 있고, 새로운 단어를 그 단어가 나온 문장과 함께 Anki로 보낼 수 있습니다.

미리 정해진 단어 목록은 없습니다——실제로 만난 단어만 복습합니다. 어떤 언어에서도 사용할 수 있습니다.

- 📖 EPUB 읽기 · 탭해서 바로 검색
- 🎧 오디오북 문장 단위 하이라이트
- 🎬 동영상 자막 검색 및 카드 만들기
- 🃏 원탭 Anki 카드 만들기 + 복습 통계
- 📚 만화 보기 · OCR로 화면에서 바로 단어 검색
- ⬇️ 애니메이션과 만화를 앱 안에서 원탭 다운로드——자동으로 라이브러리에 추가되고, 다운로드 중에도 재생할 수 있습니다
- 🎮 Galgame 음성 마이닝(Windows) · 원본 음성이 텍스트와 함께 카드에 들어갑니다

지원 플랫폼: Android / Windows / macOS / iOS(Linux는 소스에서 빌드할 수 있지만, 아직 미리 빌드된 패키지는 없습니다)

### 프로젝트 URL

https://github.com/hajisensai/Fushi

활발히 개발 중입니다——여러분의 피드백은 신속하게 처리됩니다. 버그 신고와 기능 요청을 환영합니다. Fushi가 유용하다고 느끼신다면 다른 사람에게 공유하거나 저장소에 ⭐를 남겨 주시면 감사하겠습니다.

### 다운로드

https://github.com/hajisensai/Fushi/releases/latest

사용하는 플랫폼에 맞는 파일을 선택하세요: **Android**——`arm64-v8a` APK(최근 몇 년간의 스마트폰은 모두 이것을 사용합니다. 오래된 기기만 `armeabi-v7a`가 필요하고, 에뮬레이터는 `x86_64`를 사용합니다), **Windows**——`windows-setup.exe`, **macOS**——`macos.zip`, **iOS**——`ios.ipa`. **Linux**는 아직 미리 빌드된 패키지가 없으므로 소스에서 직접 빌드해야 합니다.

이름이 `bridge-`로 시작하는 APK는 **기존 Hibiki 사용자**를 위한 마이그레이션 브리지이므로 무시하셔도 됩니다.

## 설정 튜토리얼

### 1. 추천 사전(단어 + 고저 악센트 + 빈도 사전)과 로컬 오디오(일본어 및 영어 오디오 데이터베이스) 가져오기(초보자에게 강력 추천!!! · 선택 사항)

[Google Drive](https://drive.google.com/file/d/1W0Civ-b9NAyCu6LpXYMcNI_wZJWB9xjp/view?usp=sharing) · [Cloudflare 다운로드(9.5 GB)](https://dl.wrds.xyz/fushi-recommended-2026-08-14.fushi.zip)

앱에서: 설정 -> 동기화 및 백업 -> **백업 가져오기**를 탭합니다.

![백업 가져오기 화면](static-assets/user-guide/import-backup.png)

### 2. Anki 공식 사이트에서 Anki 다운로드 및 설정

Anki——「暗記(あんき)」에서 유래——는 전 세계에서 가장 널리 쓰이는 [간격 반복 시스템(SRS)](https://en.wikipedia.org/wiki/Spaced_repetition)이며 매우 중요한 도구입니다.

링크: [Anki 공식 사이트](https://apps.ankiweb.net/) · [매뉴얼(중국어)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(중국어)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

![Anki 다운로드 페이지](static-assets/user-guide/anki-download.png)

외우고 싶은 자료를 Anki에 맡기면, 최소한의 학습 시간으로 최고의 기억 유지 효과를 얻을 수 있습니다.

Anki에는 [FSRS](https://github.com/open-spaced-repetition/fsrs4anki)가 내장되어 있습니다——세계 최고 수준의 간격 반복 알고리즘 중 하나입니다.

**하지만!!!** Anki의 기본 알고리즘은 SM2로, 30년도 더 된 성능이 떨어지는 알고리즘입니다. Anki가 사용하는 알고리즘을 반드시 **FSRS**로 전환하세요.

#### Anki

##### Android

1. Anki를 설치하고 엽니다.
2. Fushi로 돌아가 설정 -> 카드 만들기로 이동합니다.
3. **덱 및 노트 유형 새로 고침**(이미지의 "1")을 탭합니다. Fushi가 권한을 요청하면——「허용」을 탭합니다.
4. **Lapis 덱 만들기**(이미지의 "2")를 탭합니다.
5. 빨간색 경고나 오류가 없으면 설정에 성공한 것입니다.

![Anki Android 설정](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Anki를 설치하고 엽니다.
2. 왼쪽 상단의 **도구(Tools)**를 클릭합니다.

![Windows의 Anki 도구 메뉴](static-assets/user-guide/anki-windows-tools-menu.png)

3. 아래 Anki 애드온 코드를 붙여넣어 설치합니다: `2055492159`
4. Fushi로 돌아가 설정 -> 카드 만들기로 이동합니다.
5. **덱 및 노트 유형 새로 고침**("1")을 탭합니다.
6. **Lapis 덱 만들기**("2")를 탭합니다.
7. 빨간색 경고나 오류가 없으면 설정에 성공한 것입니다.

![Anki Windows 설정](static-assets/user-guide/anki-windows-setup.png)

### 3. 설정의 각 옵션을 살펴보고 조정하고 싶은 항목이 있는지 확인하세요.(선택 사항)

이제 이머전을 시작할 시간입니다.

## 추천 기능

### 앱 밖에서 단어 찾기

**Android:** 단어를 선택한 다음 선택 메뉴에서 **번역** 또는 **Fushi**를 탭합니다.

**Windows:** 단어를 선택한 다음 **Ctrl+Alt+D**를 누릅니다(단축키는 설정 -> 단축키에서 변경할 수 있습니다).

### 클립보드 검색

복사한 내용은 자동으로 검색됩니다. 표시 방식은 **플로팅 패널**과 **투명 텍스트 창** 두 가지가 있으며, 모두 설정 -> 단어 검색에서 설정할 수 있습니다.

### 브라우저 검색 / 스트리밍 자막 카드 만들기(Netflix)

Fushi 홈페이지에서 브라우저 확장 프로그램을 설치하세요.

## 감사의 말

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
