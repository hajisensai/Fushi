<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Android için sürükleyici Japonca okuyucu</p>
<p align="center">EPUB · Sözlük · Anki · Sesli kitap senkronizasyonu</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <b>Türkçe</b> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Hakkında

**hibiki**, Japonca öğrenenler için bir Android okuma uygulamasıdır.

## Özellikler

### EPUB Okuyucu
- EPUB'u WebView'de oluşturma ([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) türevi sayfalama motoru)
- Dokunarak sözlükte arama, seçim yaparak analiz
- Özel yazı tipleri, temalar (açık/koyu)
- Okuma istatistikleri ve yer imleri
- Sürekli kaydırma / sayfalı mod

### Sözlük
- [Yomitan](https://github.com/yomidevs/yomitan) biçiminde sözlük içe aktarma (eski adı Yomichan)
- Ton vurgusu ve frekans verisi desteği
- Çoklu sözlükte paralel arama, arama geçmişi
- Ve çekim geri dönüşümü

### Anki Kartları
- [AnkiDroid](https://github.com/ankidroid/Anki-Android)'a tek dokunuşla dışa aktarma
- Otomatik bağlam cümlesi doldurma
- Ses kaydı, ekran görüntüsü kırpma
- Çoklu dışa aktarma profilleri, özel alan eşleştirme
- Hızlı eylemler (Quick Actions) ile tek adımda kart oluşturma

### Sesli kitap senkronizasyonu (Sasayaki)
- Altyazı biçimleri: SRT / LRC / VTT / ASS
- Altyazı metnini EPUB içeriği ile otomatik hizalama
- Senkronize vurgulama, ses ile senkronize sayfa çevirme
- Oynatma kontrolleri (ilerleme, atlama, hız)

### Diğer
- 17 arayüz dili
- Çoklu kullanıcı profili
- Gizli mod
- Diğer uygulamalardan metin paylaşarak arama

## Desteklenen diller

Arayüz aşağıdaki dilleri destekler:

| Dil | Kod |
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

## Teknoloji yığını

| Katman | Teknoloji |
|---|---|
| Çerçeve | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Platform | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino uyarlanabilir) |
| Okuyucu | WebView sayfalama motoru ([Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) türevi) |
| Depolama | Drift (SQLite, WAL) + hoshidicts (C++ FFI sözlük motoru) |
| NLP | Ve (çekim geri dönüşümü) |
| Kartlar | AnkiDroid API |
| Uluslararasılaştırma | Slang (17 dil) |
| Minimum sürüm | Android 7.0 (API 24) |

## Derleme

Tek komutla hazırlık (`dart_defines.env` otomatik seed + `flutter pub get` + yama uygulama), ardından derleyin:

```bash
# depo kök dizininde
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # veya (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi \
  --dart-define-from-file=dart_defines.env
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` üç işi tek komutta toplar: ① `hibiki/dart_defines.env` yoksa `dart_defines.env.example` dosyasından otomatik üretilir (yer tutucu OAuth değerleri derleme için yeterlidir, gerçek değerler yalnızca Google Drive yedeklemesi için gerekir); ② `flutter pub get`; ③ `ci/apply-patches.sh` çalıştırma. `melos bootstrap`, post hook aracılığıyla aynı ②③ adımlarını yapar (Windows'ta melos'ta CJK kodlama hatası vardır, bu yüzden `tool/bootstrap.ps1` kullanın).

> **Yamalar hakkında:** `ci/apply-patches.sh`, `ci/patches/` altındaki değişiklikleri gerçek pub cache üzerine uygular. Her pub cache temizliğinden veya yeni bir `flutter pub get` işleminden sonra yeniden çalıştırılmalıdır (bootstrap bu adımı zaten içerir). Betik herhangi bir yama hedefi bulamazsa, başarıyı taklit etmek yerine bir uyarıyla atlar.

## Bağımlılıklar ve yamalar

Bu proje Flutter 3.41.6'ya kilitlenmiştir ve bazı upstream bağımlılıkları henüz uyarlanmamıştır. Yamalar iki yoldan gider: ① derleme girdisi olması ve makineler arasında birebir yeniden üretilmesi gereken paketler `third_party/` altına vendored edilir ve `dependency_overrides` ile gösterilir (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, pub-cache yaması **gerektirmez**); ② diğer paketler `ci/apply-patches.sh` tarafından pub cache kaynak kodunda yamalanır. Mekanizma ayrıntıları için [docs/agent/build.md](../agent/build.md) bölümüne bakın. Aşağıdaki katlanabilir tablolar değişikliğe göre düzenlenmiş tarihsel bir listedir; mekanizma ① ile çakışan paketlerde vendored sürüm geçerlidir.

<details>
<summary><b>Flutter API değişiklik yamaları</b></summary>

| Paket | Değişiklikler |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; kaldırılan `imageCache.putIfAbsent` değiştirildi |
| `flutter_blurhash` 0.7.0 | Aynı: `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Ad çatışmasını önlemek için dahili import'a `hide CarouselController` eklendi |
| `fading_edge_scrollview` 3.0.0 | `PageView.controller` nullable düzeltmesi |

</details>

<details>
<summary><b>v1 Embedding kaldırma yamaları</b></summary>

Flutter 3.41.6, v1 embedding API'sini (`PluginRegistry.Registrar`) tamamen kaldırmıştır. Aşağıdaki eklentilerin ilgili referanslarının silinmesi gerekmektedir:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Gradle / Kotlin yamaları</b></summary>

| Hedef | Değişiklikler |
|---|---|
| `android/build.gradle` afterEvaluate | Alt projelere `compileSdk` zorlanması (varsayılan 36, bazıları 34); `-Werror` kaldırılması |
| `audio_session` 0.1.14 | `-Werror`, `-Xlint:deprecation` kaldırılması |
| `package_info_plus` 4.0.2 | Kotlin null safety düzeltmesi |
| `receive_intent` (git) | Kotlin null safety düzeltmesi |

</details>

<details>
<summary><b>Git bağımlılıkları</b></summary>

| Paket | Kaynak |
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

## Proje yapısı

```
hibiki/                      # Depo kökü (Melos workspace: hibiki_workspace)
├── hibiki/                  # Flutter uygulama ana dizini
│   ├── lib/
│   │   ├── i18n/            # Uluslararasılaştırma (17 dil, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Sayfalar (kitaplık, okuyucu, sözlük, ayarlar vb.)
│   │   │   ├── reader/      # Okuyucu WebView JS/CSS betikleri
│   │   │   ├── media/       # Sesli kitaplar, altyazı ayrıştırma, reader source
│   │   │   └── models/      # Veri modelleri ve durum yönetimi (AppModel)
│   │   └── main.dart
│   └── android/             # Android projesi (manifest, native hoshidicts)
├── packages/                # Dahili package'lar + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # vendored yama paketleri (dependency_overrides ile gösterilir)
├── ci/                      # Derleme yaması ve entegrasyon testi betikleri
├── tool/                    # bootstrap / i18n_sync vb. betikler
└── docs/                    # Geliştirme dokümantasyonu (docs/agent/ agent el kitabı dahil)
```

## Teşekkürler

| Proje | Açıklama |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Japonca sürükleyici öğrenme aracı |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Android Japonca okuyucu |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | C++ sözlük motoru |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | iOS Japonca okuyucu |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Sesli kitap senkronizasyon şeması |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | EPUB oluşturma motoru |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | ttu topluluk bakım sürümü (SvelteKit v2), hibiki fork'unun upstream temeli |
| [Yomitan](https://github.com/yomidevs/yomitan) | Sözlük biçimi kaynağı |

## Lisans

[GNU General Public License v3.0](../../LICENSE)
