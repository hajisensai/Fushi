<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="โลโก้ Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS%20%7C%20Linux-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | **ภาษาไทย** | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![ดาวน์โหลดเวอร์ชันล่าสุด](https://img.shields.io/badge/%E2%AC%87%20%E0%B8%94%E0%B8%B2%E0%B8%A7%E0%B8%99%E0%B9%8C%E0%B9%82%E0%B8%AB%E0%B8%A5%E0%B8%94%E0%B9%80%E0%B8%A7%E0%B8%AD%E0%B8%A3%E0%B9%8C%E0%B8%8A%E0%B8%B1%E0%B8%99%E0%B8%A5%E0%B9%88%E0%B8%B2%E0%B8%AA%E0%B8%B8%E0%B8%94-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![เข้าร่วม Discord](https://img.shields.io/badge/%E0%B9%80%E0%B8%82%E0%B9%89%E0%B8%B2%E0%B8%A3%E0%B9%88%E0%B8%A7%E0%B8%A1%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## การรองรับแพลตฟอร์ม

| แพลตฟอร์ม | สถานะ | หมายเหตุ |
|---|---|---|
| Android | ✅ | Android 7.0 (API 24) ขึ้นไป |
| Windows | ✅ | การ hook ข้อความและเสียงของ galgame ใช้ได้เฉพาะ Windows |
| macOS | ✅ | เฉพาะ Apple Silicon; ไม่รองรับ Mac แบบ Intel |
| iOS | ✅ ([TestFlight](https://testflight.apple.com/join/j88d69jx)) | ไม่มีการค้นหาแหล่ง แหล่งออนไลน์ และศูนย์ดาวน์โหลด (ตามแนวทางของ App Store) |
| Linux | 🔧 สร้างจากซอร์สโค้ด | ยังไม่มีรุ่นที่สร้างไว้ล่วงหน้า; ตัวอ่าน EPUB ต้องใช้ WPE WebKit |
| Fushi Server | 🧪 Beta ([fushi-server](https://github.com/hajisensai/fushi-server/releases)) | โฮสต์แบบ headless สำหรับ Linux / Windows / macOS พร้อมเว็บ UI — ดู [packages/fushi_server](../../packages/fushi_server/README.md) |

**ระบบการออกแบบ** — ทุกแพลตฟอร์มใช้ **Material 3 Expressive** เป็นค่าเริ่มต้น และสามารถเลือกระบบการออกแบบ **Cupertino** (สไตล์ Apple) ได้ที่ *การตั้งค่า › รูปลักษณ์ › ระบบการออกแบบ* เมื่อใช้ Cupertino พื้นหลังหน้าต่างจะใช้ Mica บน Windows 11 และ vibrancy บน macOS (เว้นแต่จะเปิดการลดความโปร่งใสหรือความคมชัดสูงของระบบ)

> ภาษาที่ใช้ค้นคำในพจนานุกรมจะถูกกำหนดโดยพจนานุกรมที่นำเข้าและตารางการแปลงรูปของ Yomitan โดยไม่ขึ้นกับภาษาของส่วนติดต่อผู้ใช้ iOS อัปเดตผ่าน TestFlight จึงช้ากว่าแพลตฟอร์มอื่นสองสามวัน

### ภาษาของส่วนติดต่อผู้ใช้ (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## การติดตั้ง

ดาวน์โหลดรุ่นล่าสุดได้จาก[เว็บไซต์ Fushi](https://fushi.moe/) — มี Android APK, ตัวติดตั้ง Windows และบิลด์ macOS (เฉพาะ Apple Silicon; ไม่รองรับ Mac แบบ Intel) ส่วน iOS ติดตั้งผ่าน [TestFlight](https://testflight.apple.com/join/j88d69jx) Linux ยังไม่มีรุ่นแอปที่สร้างไว้ล่วงหน้า ให้สร้างจากซอร์สโค้ดเอง Fushi Server แบบ headless เผยแพร่แยกต่างหากที่ [hajisensai/fushi-server](https://github.com/hajisensai/fushi-server/releases)

> ต้องใช้ Android 7.0 (API 24) ขึ้นไป

## การสร้าง

เตรียมความพร้อมด้วยคำสั่งเดียว (`flutter pub get` + apply patches) แล้วจึงสร้าง:

```bash
# จากรากของ repository
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# เดสก์ท็อป
flutter build windows --release
flutter build macos --release
flutter build linux --release
# iOS
flutter build ipa --release

# เซิร์ฟเวอร์ headless (จาก packages/fushi_server; ใช้ `dart build cli` ไม่ใช่ `dart compile exe`)
dart build cli
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` รวม `flutter pub get` และ `ci/apply-patches.sh` ไว้ในคำสั่งเดียว โปรเจกต์นี้ล็อกไว้ที่ Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`) Flutter รุ่นก่อนหน้าจะสร้างไม่ได้ เพราะใช้ Material และ Cupertino ในรูปแพ็กเกจ `material_ui` / `cupertino_ui` ส่วนที่พึ่งพาจาก upstream บางรายการถูก vendored ไว้ใน `third_party/` หรือถูกแพตช์โดย `ci/apply-patches.sh` — ดูรายละเอียดรวมถึงส่วนที่ต้องใช้สร้างเดสก์ท็อป Linux ได้ที่ [docs/agent/build.md](../agent/build.md)

<details>
<summary><b>เทคโนโลยีที่ใช้</b></summary>

| เลเยอร์ | เทคโนโลยี |
|---|---|
| เฟรมเวิร์ก | Flutter 3.47.6 (Dart SDK `>=3.8.0 <4.0.0`), Riverpod |
| แพลตฟอร์ม | Android / Windows / macOS / iOS / Linux รวมถึงเซิร์ฟเวอร์ headless |
| UI | `material_ui` (Material 3 Expressive) / `cupertino_ui` (Cupertino) |
| ตัวอ่าน | เอนจินแบ่งหน้าด้วย WebView (พัฒนาต่อจากตระกูล Hoshi Reader) |
| วิดีโอ | media_kit (แกนหลัก libmpv) + libplacebo |
| การจัดเก็บ | Drift (SQLite, WAL) + fushidicts (เอนจินพจนานุกรม C++ FFI) |
| NLP | ตารางการแปลงรูปของ Yomitan (การลดรูปคำหลายภาษา) + kana_kit (แปลงคานะ); การแบ่งโทเค็นผ่าน fushidicts FFI |
| AI บนอุปกรณ์ | ONNX Runtime สำหรับการรู้จำเสียงพูด (สร้างซับไตเติล) และ OCR มังงะ; อัลกอริทึมอยู่ใน [fushi-subtitles](https://github.com/hajisensai/fushi-subtitles) |
| การดาวน์โหลด | libtorrent 2.x ผ่านบริดจ์ C-ABI FFI (ใช้ qBittorrent ภายนอกเป็นทางสำรอง) |
| การซิงก์ | แบ็กเอนด์คลาวด์ + Fushi Interconnect (LAN, ที่อยู่ระยะไกล และอุโมงค์ P2P ของ iroh) |
| เอนจินที่ใช้ร่วมกัน | `fushi_engine` — แกน Dart ล้วนที่แอปและ Fushi Server ใช้ร่วมกัน |
| การสร้างการ์ด | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 ภาษา) |

</details>

<details>
<summary><b>โครงสร้างโปรเจกต์</b></summary>

```
Fushi/                      # รากของ repository (Melos workspace: fushi_workspace)
├── fushi/                  # ไดเรกทอรีหลักของแอป Flutter
│   ├── lib/
│   │   ├── i18n/            # การแปลภาษา (17 ภาษา, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # หน้าต่าง ๆ (คลังหนังสือ, ตัวอ่าน, เครื่องเล่นวิดีโอ, การตั้งค่า ฯลฯ)
│   │   │   ├── reader/      # สคริปต์ JS/CSS ของ WebView ในตัวอ่าน
│   │   │   ├── media/       # หนังสือ, มังงะ, วิดีโอ, หนังสือเสียง, แหล่งออนไลน์
│   │   │   ├── lookup/      # ป๊อปอัปและโอเวอร์เลย์ค้นหาคำ
│   │   │   ├── mining/      # การสร้างการ์ด (รวมถึงการสร้างการ์ดจาก galgame)
│   │   │   ├── sync/        # ซิงก์คลาวด์, Interconnect, เซิร์ฟเวอร์มีเดีย
│   │   │   └── models/      # โมเดลข้อมูลและการจัดการสถานะ (AppModel)
│   │   └── main.dart
│   └── android/             # โปรเจกต์ Android
├── packages/                # แพ็กเกจ Dart
│   ├── fushi_core/          #   สคีมาฐานข้อมูล, การตั้งค่า
│   ├── fushi_engine/        #   เอนจิน Dart ล้วนที่ใช้ร่วมกับเซิร์ฟเวอร์
│   ├── fushi_server/        #   CLI เซิร์ฟเวอร์ headless + เว็บ UI
│   ├── fushi_cli/           #   ไคลเอนต์บรรทัดคำสั่งสำหรับเดสก์ท็อป
│   ├── fushi_dictionary/    #   การผูกเอนจินพจนานุกรมและตัวนำเข้า
│   ├── fushi_anki/ · fushi_audio/ · fushi_platform/ · fushi_srs/
│   ├── fushi_torrent/ · fushi_p2p/   # การผูก FFI ของ libtorrent / iroh
│   └── …                    #   fork แบบ vendored (inappwebview Windows/Linux, gamepads)
├── native/                  # ซอร์สเนทีฟ: fushidicts, fushi_torrent, fushi_p2p (Rust), galgame_hook ฯลฯ
├── services/                # แบ็กเอนด์รับล็อกและกระดานผู้นำ (ดีพลอยแยกต่างหาก)
├── tools/browser-extension/ # ส่วนขยายเบราว์เซอร์สำหรับค้นหาคำ
├── third_party/             # แพ็กเกจที่แพตช์แล้วแบบ vendored (dependency_overrides)
├── ci/                      # แพตช์สำหรับการสร้างและสคริปต์ CI
├── tool/                    # สคริปต์ bootstrap / setup_worktree / ติดตามบั๊ก
└── docs/                    # เอกสารสำหรับการพัฒนา (รวมคู่มือปฏิบัติการ docs/agent/)
```

</details>

การนำเข้าวิดีโอรองรับการจัดกลุ่มตามผลงานหรือโฟลเดอร์ ดู[เวิร์กโฟลว์วิดีโอ](../specs/2026-09-07-video-library-workflow.md)และ[เมทาดาทา MAL/TMDB พร้อมแฮชไฟล์ AniDB](../specs/2026-09-07-mal-tmdb-anidb-hash.md) สำหรับการจับคู่และงานเบื้องหลัง

[การตั้งค่าบริการออนไลน์แบบเลือกได้](../specs/2026-09-07-online-services-setup.md)อธิบายตัวตนของแอปพลิเคชันที่มาพร้อมแอป ข้อมูลรับรองส่วนบุคคล และการแจ้งเตือนการตั้งค่าวิดีโอที่ปิดได้

## ความเป็นส่วนตัวและข้อมูล

Fushi จัดเก็บหนังสือ พจนานุกรม แบบอักษร ข้อมูลหนังสือเสียง วิดีโอ ความคืบหน้าการอ่าน ไฮไลต์ สถิติ และการตั้งค่าที่นำเข้าไว้ในที่จัดเก็บข้อมูลในเครื่องของแอป

- **การซิงก์** — Google Drive / OneDrive / Dropbox ใช้การลงชื่อเข้าใช้ด้วย OAuth ส่วน WebDAV / FTP / SFTP / Fushi Server ใช้ที่อยู่เซิร์ฟเวอร์และข้อมูลรับรองที่คุณระบุ Fushi Interconnect เชื่อมต่ออุปกรณ์ที่จับคู่แล้วโดยตรง (LAN, IPv6, เครือข่าย overlay หรือที่อยู่สาธารณะ) และจะสลับไปใช้อุโมงค์ P2P ของ iroh แบบเข้ารหัสตั้งแต่ต้นทางถึงปลายทางเมื่อไม่มีเส้นทางตรงใดใช้ได้ ลิงก์จับคู่จะขอการยืนยันเสมอ
- **Anki** — การสร้างการ์ดสื่อสารกับ AnkiDroid หรือที่อยู่ AnkiConnect ที่คุณกำหนดค่าไว้เท่านั้น
- **สถิติการใช้งาน** — วันละครั้ง บิลด์เดสก์ท็อปและ Android จะส่งรหัสการติดตั้งแบบสุ่ม เวอร์ชันแอป แพลตฟอร์ม และช่องทางอัปเดตไปยัง fushi.moe เพื่อนับผู้ใช้ที่ใช้งานอยู่ โดยไม่มีบัญชี คลังหนังสือ หรือข้อมูลการอ่าน และไม่เก็บที่อยู่ IP ปิดได้ด้วย *ส่งสถิติการใช้งาน* ในการตั้งค่าการอัปเดต บิลด์ iOS ไม่ส่งข้อมูลนี้
- **เฉพาะเมื่อคุณสั่ง** — การอัปโหลดล็อก (หลังจากขอความยินยอมครั้งเดียว) ความคิดเห็นในแอป และกระดานผู้นำ (ปิดเป็นค่าเริ่มต้น; อัปโหลดชื่อเรื่องในคลังและความคืบหน้าของคุณหลังจากที่คุณเลือกเปิดเท่านั้น)
- **OCR มังงะ** — เอนจินเริ่มต้นคือ Google Lens ซึ่งส่งภาพหน้าไปยัง Google; หากต้องการเก็บภาพไว้ในเครื่อง ให้สลับไปใช้โมเดลบนอุปกรณ์หรือ OCR ของระบบในการตั้งค่า
- **ฟีเจอร์ AI** — คำขอจะส่งไปยังผู้ให้บริการ LLM ที่คุณกำหนดค่าและมอบหมายให้ฟีเจอร์นั้นเท่านั้น หากไม่ได้มอบหมายผู้ให้บริการ จะไม่มีการส่งอะไรเลย
- **บริการของบุคคลที่สาม** — ฟีเจอร์เมทาดาทา ซับไตเติล และแหล่งออนไลน์จะติดต่อบริการที่ระบุไว้ใน[แหล่งเนื้อหาและการเชื่อมต่อ](#แหล่งเนื้อหาและการเชื่อมต่อ)เฉพาะเมื่อคุณใช้งานเท่านั้น

## กิจกรรมการพัฒนา

[![กิจกรรมการพัฒนา](../assets/dev-activity.svg)](https://github.com/hajisensai/Fushi/commits/develop)

งานประจำวันจะเข้าสู่ `develop` ส่วน `main` รับเฉพาะการ merge สำหรับการออกรุ่น แผนภูมิแสดงที่นี่บน `main` แต่สร้างจาก `develop` จึงสะท้อนการพัฒนาจริงมากกว่าปริมาณการ merge

ทั้งสามเลนคือช่องทางอัปเดตที่ตัวแอปมีให้ และแต่ละเลนถูกปรับสเกลตามจุดสูงสุดของตัวเอง — จำนวนบิลด์ debug มากกว่ารุ่นเสถียรสองระดับขนาด หากใช้สเกลเดียวกัน อีกสองเลนจะแบนจนมองไม่เห็น

| เลน | สิ่งที่นับ | วิธีรับ |
|---|---|---|
| **Debug (ต่อเนื่อง)** | บิลด์จากการ push ที่สำเร็จของ [release.yml](../../.github/workflows/release.yml) | รุ่นก่อนเผยแพร่แบบต่อเนื่อง เผยแพร่ใหม่ทุกครั้งที่ push |
| **Beta** | รุ่นก่อนเผยแพร่ `v<version>-beta.<seq>` | บิลด์ทดสอบที่สั่งรันด้วยตนเอง |
| **Stable** | รุ่นเผยแพร่ `v<version>` | รุ่นล่าสุด |

> แผนภูมิด้านบนสร้างขึ้นภายใน repository นี้ (ไม่ใช้บริการของบุคคลที่สาม) และถูกรีเฟรชทุกวันโดยเวิร์กโฟลว์ [Update Dev Activity Chart](../../.github/workflows/dev-activity.yml)

## ประวัติ Star

[![GitHub stars](https://img.shields.io/github/stars/hajisensai/Fushi?style=flat&logo=github&label=Stars)](https://github.com/hajisensai/Fushi/stargazers)

[![ประวัติ Star](../assets/star-history.svg)](https://github.com/hajisensai/Fushi/stargazers)

> แผนภูมิด้านบนสร้างขึ้นภายใน repository นี้ (ไม่ใช้บริการของบุคคลที่สาม) และถูกรีเฟรชทุกวันโดยเวิร์กโฟลว์ [Update Star History](../../.github/workflows/star-history.yml)

## กิตติกรรมประกาศ

Fushi สร้างขึ้นบนโปรเจกต์และระบบนิเวศต่อไปนี้:

### เครื่องมือการเรียนรู้และผลงานก่อนหน้า

| โปรเจกต์ | คำอธิบาย |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | เครื่องมือเรียนภาษาญี่ปุ่นแบบดื่มด่ำ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | ตัวอ่านภาษาญี่ปุ่นบน iOS; อ้างอิงเอนจินแบ่งหน้าของตัวอ่าน |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | ตัวอ่านภาษาญี่ปุ่นแบบเนทีฟบน Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | เอนจินพจนานุกรม C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | โซลูชันซิงก์หนังสือเสียง |
| [Tsubasa](https://github.com/SonicSandbox/Tsubasa-sync) | อัลกอริทึมจัดเวลาซับไตเติลตามแทร็กอ้างอิง (GPL-3.0); เป็นพื้นฐานของการจัดซับไตเติลที่ดาวน์โหลดให้ตรงกับแทร็กที่ฝังอยู่โดยอัตโนมัติ |
| [Yomitan](https://github.com/yomidevs/yomitan) | อ้างอิงรูปแบบพจนานุกรม ตารางการแปลงรูป และประสบการณ์การค้นหาคำ |
| [Lapis](https://github.com/donkuri/lapis) | ประเภทโน้ตของ Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | การเชื่อมต่อการสร้างการ์ดบน Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | อ้างอิงการทำงานของเสียงภายในเครื่องและการโต้ตอบกับ AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | อ้างอิงความเข้ากันได้ด้านตัวอ่าน สถิติ และการซิงก์ |
| [media_kit](https://github.com/media-kit/media-kit) | เฟรมเวิร์กเล่นวิดีโอของ Flutter (แกนหลัก libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | ชุดเครื่องมือเรียนภาษาแบบดื่มด่ำบน macOS |

### เอนจินและคอมโพเนนต์เนทีฟ

| โปรเจกต์ | คำอธิบาย |
|---|---|
| [LunaHook](https://github.com/HIllya51/LunaTranslator) | เอนจิน hook ข้อความของ galgame (DLL แบบ vendored ที่ตัว injector โหลด) |
| [MinHook](https://github.com/TsudaKageyu/minhook) | ไลบรารี inline hook ที่ injector ของ galgame ใช้ |
| [libtorrent](https://github.com/arvidn/libtorrent) | เอนจินดาวน์โหลด torrent ในตัว |
| [mpv](https://github.com/mpv-player/mpv) | แกนเล่น libmpv เบื้องหลัง media_kit |
| [FFmpeg](https://ffmpeg.org) | การตรวจสอบมีเดีย การตัดคลิป และการแยกเสียง |
| [libplacebo](https://github.com/haasn/libplacebo) | เชเดอร์วิดีโอบน GPU และ HDR tone mapping |
| [flutter_inappwebview](https://github.com/pichillilorenzo/flutter_inappwebview) | เอนจิน WebView ที่เรนเดอร์ตัวอ่าน EPUB |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) | การอนุมานบนอุปกรณ์สำหรับการรู้จำเสียงพูดและ OCR |
| [iroh](https://github.com/n0-computer/iroh) | อุโมงค์ P2P สำหรับการเชื่อมต่อ Fushi Interconnect ระยะไกล |
| [zstd](https://github.com/facebook/zstd) · [xxHash](https://github.com/Cyan4973/xxHash) · [libdeflate](https://github.com/ebiggers/libdeflate) · [glaze](https://github.com/stephenberry/glaze) · [unordered_dense](https://github.com/martinus/unordered_dense) · [utf8proc](https://github.com/JuliaStrings/utf8proc) · [utfcpp](https://github.com/nemtrif/utfcpp) | ไลบรารีที่เอนจินพจนานุกรมพึ่งพา |

### โมเดลบนอุปกรณ์

| โปรเจกต์ | คำอธิบาย |
|---|---|
| [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) | แพ็กเกจโมเดลรู้จำเสียงพูด Zipformer และบิลด์ VAD |
| [ReazonSpeech k2-v2](https://huggingface.co/reazon-research/reazonspeech-k2-v2) | โมเดลรู้จำเสียงพูดภาษาญี่ปุ่น |
| [Parakeet TDT-CTC 0.6B ja](https://huggingface.co/nvidia/parakeet-tdt_ctc-0.6b-ja) | โมเดลรู้จำเสียงพูดภาษาญี่ปุ่น |
| [Kitsune](https://huggingface.co/subthx/kitsune-onnx) | โมเดลรู้จำเสียงพูดภาษาญี่ปุ่น (CC BY-NC 4.0 ดาวน์โหลดจากรีโพ Hugging Face ของโมเดลโดยตรง) |
| [Omnilingual ASR](https://github.com/facebookresearch/omnilingual-asr) | โมเดลรู้จำเสียงพูด CTC หลายภาษา |
| [Silero VAD](https://github.com/snakers4/silero-vad) | โมเดลตรวจจับช่วงที่มีเสียงพูด |
| [comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector) | โมเดลตรวจจับข้อความและกรอบคำพูดในมังงะ |
| [manga-panel-detector-yolo26n](https://huggingface.co/leoxs22/manga-panel-detector-yolo26n) | โมเดลตรวจจับช่องภาพมังงะ ฝึกด้วย [Manga109-s](http://www.manga109.org/en/download_s.html) |
| [PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR) small det / rec · [PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga) | การตรวจจับและจดจำบรรทัดข้อความ; rec ที่ปรับแต่งสำหรับมังงะ (ฝึกด้วย [Manga109-s](http://www.manga109.org/en/download_s.html) และ [AnimeText](https://huggingface.co/datasets/deepghs/AnimeText)) เป็นตัวขับเคลื่อนโมเดล OCR ภายในเครื่องแบบ CTC ทีละคอลัมน์ |

> โมเดลตรวจจับช่องภาพมังงะและ PP-OCRv6_manga ฝึกด้วยชุดข้อมูล Manga109-s (Matsui et al. 2017; Aizawa et al. 2020) ซึ่งเงื่อนไขของชุดข้อมูลกำหนดให้ต้องระบุอย่างชัดเจนว่ามีการใช้ชุดข้อมูลนี้ PP-OCRv6_manga (Apache-2.0) ยังฝึกเพิ่มเติมด้วยชุดข้อมูล AnimeText ซึ่งอยู่ภายใต้สัญญาอนุญาต CC BY-NC-SA 4.0 แอปดาวน์โหลดโมเดลนั้นจากรีโพ Hugging Face ของโมเดลและไม่ได้แจกจ่ายซ้ำ

### แหล่งเนื้อหาและการเชื่อมต่อ

| โปรเจกต์ | คำอธิบาย |
|---|---|
| [Mihon](https://github.com/mihonapp/mihon) | ระบบนิเวศส่วนขยายแหล่งมังงะ |
| [Aniyomi](https://github.com/aniyomiorg/aniyomi) | ระบบนิเวศส่วนขยายแหล่งอนิเมะ (extensions-lib 14–16 โฮสต์บนรันไทม์เดียวกัน) |
| [M-Extension-Server](https://github.com/kodjodevf/M-Extension-Server) | รันไทม์ส่วนขยายมังงะสำหรับเดสก์ท็อป (vendored, MPL-2.0) |
| [Mangayomi](https://github.com/kodjodevf/mangayomi) | อ้างอิงการปรับส่วนขยาย Mihon / Aniyomi |
| [LNReader](https://github.com/LNReader/lnreader-plugins) | ระบบนิเวศปลั๊กอินแหล่งไลต์โนเวล |
| [Jellyfin](https://jellyfin.org) · [Emby](https://emby.media) · [Plex](https://www.plex.tv) | เซิร์ฟเวอร์มีเดียที่เรียกดูได้จากคลังวิดีโอ |
| [asbplayer](https://github.com/asbplayer/asbplayer) | อ้างอิงบริดจ์ซับไตเติลสตรีมมิงสำหรับส่วนขยายเบราว์เซอร์ |
| [Shoko Server](https://github.com/ShokoAnime/ShokoServer) | อ้างอิงสถาปัตยกรรมการระบุและดึงข้อมูลอนิเมะ |
| [ReinaManager](https://github.com/huoshen80/ReinaManager) | อ้างอิงสถาปัตยกรรมข้อมูลของคลัง galgame |
| [AniDB](https://anidb.net) | การระบุตัวตนของอนิเมะ ตอน และไฟล์ |
| [MyAnimeList](https://myanimelist.net) (ผ่าน [Jikan](https://jikan.moe)) | เมทาดาทาอนิเมะ |
| [TMDB](https://www.themoviedb.org) | เมทาดาทาและภาพเสริม |
| [VNDB](https://vndb.org) | เมทาดาทาวิชวลโนเวล |
| [Jimaku](https://jimaku.cc) | แหล่งซับไตเติลภาษาญี่ปุ่น |
| [OpenSubtitles](https://www.opensubtitles.com) | แหล่งซับไตเติล |

> แอปพลิเคชันนี้ใช้ TMDB และ TMDB API แต่ไม่ได้รับการรับรอง การรับรอง หรือการอนุมัติจาก TMDB

## สัญญาอนุญาต

เผยแพร่ภายใต้ GNU General Public License v3.0 ดูรายละเอียดได้ที่ [LICENSE](../../LICENSE)

## ผู้ดูแล

Fushi ดูแลโดย [hajisensai](https://github.com/hajisensai) เว็บไซต์: [fushi.moe](https://fushi.moe) ติดต่อ: [contact@fushi.moe](mailto:contact@fushi.moe)

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | **ภาษาไทย** | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
