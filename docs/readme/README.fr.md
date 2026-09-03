<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Télécharger la dernière version](https://img.shields.io/badge/%E2%AC%87%20T%C3%A9l%C3%A9charger%20la%20derni%C3%A8re%20version-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Rejoindre le Discord](https://img.shields.io/badge/Rejoindre%20le%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Prise en charge des plateformes

| Plateforme | État | Rendu / Interface |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Minimum Android 7.0 (API 24). Les langues disponibles pour la recherche dans les dictionnaires sont déterminées par les dictionnaires importés et les tables de transformation de Yomitan, indépendamment de la langue de l'interface.

### Langues d'interface (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Installation et compilation

Préparation en une seule commande (`flutter pub get` + application des correctifs), puis compilez :

```bash
# Depuis la racine du dépôt
bash tool/bootstrap.sh          # Windows PowerShell : .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Bureau Windows
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` regroupent `flutter pub get` et `ci/apply-patches.sh` en une seule commande. Ce projet est verrouillé sur Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) ; certaines dépendances upstream sont incluses dans `third_party/` ou corrigées par `ci/apply-patches.sh` — voir [docs/agent/build.md](../agent/build.md) pour plus de détails.

<details>
<summary><b>Pile technique</b></summary>

| Couche | Technologie |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plateformes | Android / Windows / macOS / iOS (Material Design 3) |
| Lecteur | Moteur de pagination WebView (dérivé de la famille Hoshi Reader) |
| Vidéo | media_kit (libmpv core) |
| Stockage | Drift (SQLite, WAL) + fushidicts (moteur de dictionnaires FFI en C++) |
| TAL | Tables de transformation de Yomitan (lemmatisation multilingue) + kana_kit (conversion de kana) ; tokenisation via fushidicts FFI |
| Création de cartes | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 langues) |

</details>

<details>
<summary><b>Structure du projet</b></summary>

```
Fushi/                      # Racine du dépôt (espace de travail Melos : fushi_workspace)
├── fushi/                  # Répertoire principal de l'application Flutter
│   ├── lib/
│   │   ├── i18n/            # Internationalisation (17 langues, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Pages (bibliothèque, lecteur, dictionnaire, paramètres, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS du WebView du lecteur
│   │   │   ├── media/       # Livres audio, analyse des sous-titres, source du lecteur
│   │   │   └── models/      # Modèles de données et gestion d'état (AppModel)
│   │   └── main.dart
│   └── android/             # Projet Android (manifest, fushidicts natif)
├── packages/                # Paquets internes + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Moteur de dictionnaires en C++ fushidicts (FFI)
├── third_party/             # Paquets corrigés inclus (dependency_overrides)
├── ci/                      # Correctifs de compilation et scripts de tests d'intégration
├── tool/                    # Scripts bootstrap / i18n_sync et autres
└── docs/                    # Documentation de développement (incl. manuel d'exploitation docs/agent/)
```

</details>

## Confidentialité et données

Fushi stocke les livres importés, les dictionnaires, les polices, les données des livres audio, les vidéos, la progression de lecture, les surlignages, les statistiques et les paramètres dans le stockage local de l'application.

La synchronisation cloud (Google Drive / OneDrive / Dropbox) utilise des identifiants OAuth configurés par l'utilisateur ; WebDAV / FTP / SFTP utilise les adresses de serveur et les identifiants fournis par l'utilisateur ; Fushi Interconnect se connecte directement via une adresse configurée par l'utilisateur. La création de cartes Anki communique avec AnkiDroid ou avec une adresse AnkiConnect configurée.

## Remerciements

Fushi s'appuie sur les projets et l'écosystème suivants :

| Projet | Description |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Outil d'apprentissage immersif du japonais |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lecteur de japonais pour iOS ; référence du moteur de pagination du lecteur |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lecteur de japonais natif pour Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Moteur de dictionnaires en C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solution de synchronisation des livres audio |
| [Yomitan](https://github.com/yomidevs/yomitan) | Référence de format de dictionnaire, tables de transformation et expérience de recherche |
| [Lapis](https://github.com/donkuri/lapis) | Type de note Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Intégration de création de cartes sur Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Référence d'audio local et d'interaction avec AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Référence de compatibilité de lecteur, statistiques et synchronisation |
| [media_kit](https://github.com/media-kit/media-kit) | Framework de lecture vidéo de Flutter (cœur libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Suite d'apprentissage immersif des langues pour macOS |

## Licence

Distribué sous la licence publique générale GNU v3.0. Voir [LICENSE](../../LICENSE) pour plus de détails.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | **Français** | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
