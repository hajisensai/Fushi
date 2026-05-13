<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Lecteur immersif de japonais pour Android</p>
<p align="center">EPUB · Dictionnaire · Anki · Synchronisation de livres audio</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <a href="README.es.md">Español</a> · <b>Français</b> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introduction

**hibiki** est une application de lecture Android pour les apprenants du japonais.

## Fonctionnalités

### Lecture EPUB
- Rendu EPUB intégré via [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) (WebView)
- Appuyez pour chercher un mot, sélectionnez pour analyser
- Polices et thèmes personnalisables (clair/sombre)
- Statistiques de lecture et signets
- Deux modes : défilement continu / pagination

### Dictionnaire
- Importation de dictionnaires au format [Yomitan](https://github.com/yomidevs/yomitan) (anciennement Yomichan)
- Prise en charge des accents tonals et des données de fréquence
- Recherche parallèle multi-dictionnaires, historique de recherche
- Déconjugaison Ve

### Cartes Anki
- Export en un clic vers [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Remplissage automatique des phrases de contexte
- Enregistrement audio et recadrage de captures d'écran
- Profils d'export multiples, mappage de champs personnalisé
- Actions rapides (Quick Actions) pour créer une carte en un geste

### Synchronisation de livres audio (Sasayaki)
- Formats de sous-titres : SRT / LRC / VTT / ASS
- Alignement automatique des sous-titres avec le texte EPUB
- Surlignage en lecture suivie, changement de page synchronisé avec l'audio
- Barre de contrôle de lecture (progression, navigation, vitesse)

### Autres
- 17 langues d'interface
- Profils utilisateur multiples
- Mode incognito
- Recherche directe par partage de texte depuis d'autres applications

## Langues prises en charge

L'interface prend en charge les langues suivantes :

| Langue | Code |
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

## Stack technique

| Couche | Technologie |
|---|---|
| Framework | Flutter 3.41.6 / Dart 3.11.4 |
| Lecteur | ttu Ebook Reader (WebView, [fork](https://github.com/hdjsadgfwtg/ttu-fork)) |
| Stockage | Isar + Drift (SQLite) + hoshidicts (moteur de dictionnaires C++ FFI) |
| NLP | Ve (déconjugaison) |
| Création de cartes | AnkiDroid API |
| Internationalisation | Slang |
| Version minimale | Android 8.0 (API 26) |

## Compilation

```bash
cd hibiki/hibiki
flutter pub get
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> **Les patchs du pub cache doivent être appliqués avant la première compilation.** Si le pub cache est effacé ou si vous relancez `pub get`, tous les patchs doivent être réappliqués. Voir [Dépendances et patchs](#dépendances-et-patchs) ci-dessous.

## Dépendances et patchs

Ce projet est verrouillé sur Flutter 3.41.6. Certaines dépendances en amont ne sont pas encore adaptées et nécessitent des corrections manuelles dans le code source du pub cache.

<details>
<summary><b>Patchs de changements d'API Flutter</b></summary>

| Package | Modifications |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage` ; `DecoderCallback` → `ImageDecoderCallback` ; `hashValues` → `Object.hash` ; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor` ; remplacement de `imageCache.putIfAbsent` supprimé |
| `flutter_blurhash` 0.7.0 | Idem `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge` ; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Ajout de `hide CarouselController` aux imports internes pour éviter les conflits de noms |
| `fading_edge_scrollview` 3.0.0 | Correction nullable de `PageView.controller` |

</details>

<details>
<summary><b>Patchs de suppression de l'embedding v1</b></summary>

Flutter 3.41.6 a entièrement supprimé l'API d'embedding v1 (`PluginRegistry.Registrar`). Les plugins suivants nécessitent la suppression des références correspondantes :

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Patchs Gradle / Kotlin</b></summary>

| Cible | Modifications |
|---|---|
| `android/build.gradle` afterEvaluate | Forcer `compileSdkVersion 34` pour les sous-projets ; suppression de `-Werror` |
| `audio_session` 0.1.14 | Suppression de `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Correction de la sécurité null Kotlin |
| `receive_intent` (git) | Correction de la sécurité null Kotlin |

</details>

<details>
<summary><b>Dépendances Git</b></summary>

| Package | Source |
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

## Structure du projet

```
hibiki/
├── hibiki/                  # Répertoire principal de l'application Flutter
│   ├── lib/
│   │   ├── i18n/            # Internationalisation (17 langues)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bibliothèque, lecteur, dictionnaire, paramètres, etc.)
│   │   │   ├── media/       # Pont livres audio, analyse des sous-titres
│   │   │   ├── dictionary/  # Moteur de recherche de dictionnaire
│   │   │   ├── models/      # Modèles de données et gestion d'état
│   │   │   └── language/    # Couche d'abstraction linguistique
│   │   └── main.dart
│   ├── assets/
│   │   └── ttu-ebook-reader/ # Artefacts de build du fork ttu
│   └── android/
│       └── app/src/main/cpp/ # Moteur de dictionnaires C++ hoshidicts
├── docs/                    # Documentation de développement
└── chisa/                   # Référence des premières versions de jidoujisho
```

## Remerciements

| Projet | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Outil d'apprentissage immersif du japonais |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lecteur japonais Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Moteur de dictionnaires C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lecteur japonais iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solution de synchronisation de livres audio |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Moteur de rendu EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Version communautaire de ttu (SvelteKit v2), base amont du fork hibiki |
| [Yomitan](https://github.com/yomidevs/yomitan) | Source du format de dictionnaire |

## Licence

[GNU General Public License v3.0](../../LICENSE)
