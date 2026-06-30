# hibiki 사용 설명서

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | **한국어** | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> 간체 중국어 가이드는 Feishu에 호스팅되어 있습니다(위 링크). 영어 가이드는 [GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md)에서도 볼 수 있습니다.

## 소개

이것은 Android / Windows(iOS / macOS 계획 중)용 무료 소프트웨어입니다——소설 읽기, 오디오북 재생, 동영상 재생, 사전 검색을 하나로 결합한 획기적인 멀티플랫폼 오픈 소스 앱입니다.

### 프로젝트 URL

https://github.com/hajisensai/hibiki

활발히 개발 중입니다——여러분의 피드백은 신속하게 처리됩니다. 버그 신고와 기능 요청을 환영합니다. Hibiki가 유용하다고 느끼신다면 다른 사람에게 공유하거나 저장소에 ⭐를 남겨 주시면 감사하겠습니다.

### 다운로드

https://github.com/hajisensai/hibiki/releases/latest

Android: **arm64**를 선택하세요. Windows: **.exe** 파일을 선택하세요.

## 설정 튜토리얼

### 1. 추천 사전과 로컬 오디오 가져오기(선택 사항)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

앱에서: 설정 -> 동기화 및 백업 -> **백업 가져오기**를 탭합니다.

**참고: 백업을 가져오면 로컬 데이터가 삭제됩니다. 이 흐름은 향후 업데이트에서 개선될 예정입니다.**

![백업 가져오기 화면](static-assets/user-guide/import-backup.png)

### 2. Anki 공식 사이트에서 Anki 다운로드 및 설정

Anki——「暗記(あんき)」에서 유래——는 전 세계에서 가장 널리 쓰이는 [간격 반복 시스템(SRS)](https://en.wikipedia.org/wiki/Spaced_repetition)이며 매우 중요한 도구입니다.

링크: [Anki 공식 사이트](https://apps.ankiweb.net/) · [매뉴얼(중국어)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [FAQ](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(중국어)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[이미지: 일러스트 / 범례]*

외우고 싶은 자료를 Anki에 맡기면, 최소한의 학습 시간으로 최고의 기억 유지 효과를 얻을 수 있습니다.

Anki에는 [FSRS](https://github.com/open-spaced-repetition/fsrs4anki)가 내장되어 있습니다——세계 최고 수준의 간격 반복 알고리즘 중 하나입니다.

**하지만!!!** Anki의 기본 알고리즘은 SM2로, 30년도 더 된 성능이 떨어지는 알고리즘입니다. Anki가 사용하는 알고리즘을 반드시 **FSRS**로 전환하세요.

#### Anki

##### Android

1. Anki를 설치하고 엽니다.
2. hibiki로 돌아가 설정 -> 카드 만들기로 이동합니다.
3. **덱 및 노트 유형 새로 고침**(이미지의 "1")을 탭합니다. hibiki가 권한을 요청하면——「허용」을 탭합니다.
4. **Lapis 덱 만들기**(이미지의 "2")를 탭합니다.
5. 빨간색 경고나 오류가 없으면 설정에 성공한 것입니다.

![Anki Android 설정](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Anki를 설치하고 엽니다.
2. 왼쪽 상단의 **도구(Tools)**를 클릭합니다.

![Windows의 Anki 도구 메뉴](static-assets/user-guide/anki-windows-tools-menu.png)

3. 아래 Anki 애드온 코드를 붙여넣어 설치합니다: `2055492159`
4. hibiki로 돌아가 설정 -> 카드 만들기로 이동합니다.
5. **덱 및 노트 유형 새로 고침**("1")을 탭합니다.
6. **Lapis 덱 만들기**("2")를 탭합니다.
7. 빨간색 경고나 오류가 없으면 설정에 성공한 것입니다.

![Anki Windows 설정](static-assets/user-guide/anki-windows-setup.png)

### 3. 설정의 각 옵션을 살펴보고 조정하고 싶은 항목이 있는지 확인하세요.(선택 사항)

## 감사의 말

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
