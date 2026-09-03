<div align="center">

# Fushi

<img src="../static-assets/fushi-logo.png" alt="logo de Fushi" width="160">

![Platform](https://img.shields.io/badge/platform-Android%20%7C%20Windows%20%7C%20macOS%20%7C%20iOS-lightgrey)
![License](https://img.shields.io/badge/license-GPLv3-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.44.0-02569B?logo=flutter&logoColor=white)

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | **Español** | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

[![fushi.moe](https://img.shields.io/badge/%F0%9F%8C%90%20fushi.moe-0969DA?style=for-the-badge)](https://fushi.moe/)

[![Descargar la última versión](https://img.shields.io/badge/%E2%AC%87%20Descargar%20la%20%C3%BAltima%20versi%C3%B3n-2EA44F?style=for-the-badge)](https://fushi.moe/)
[![Únete a Discord](https://img.shields.io/badge/%C3%9Anete%20a%20Discord-5865F2?style=for-the-badge&logo=discord&logoColor=white)](https://discord.gg/WhjwyGmm7f)

</div>


## Compatibilidad de plataformas

| Plataforma | Estado | Renderizado / Interfaz |
|---|---|---|
| Android | ✅ | Material Design 3 |
| Windows | ✅ | Material Design 3 |
| macOS | ✅ | Material Design 3 |
| Linux | 🔧 (build from source) | Material Design 3 |
| iOS | ✅ | Material Design 3 |

> Mínimo Android 7.0 (API 24). Los idiomas disponibles para la búsqueda en diccionarios los determinan los diccionarios importados y las tablas de transformación de Yomitan, con independencia del idioma de la interfaz.

### Idiomas de interfaz (17)

English · 简体中文 · 繁體中文 · 日本語 · 한국어 · Español · Français · Deutsch · Português (Brasil) · Русский · Tiếng Việt · ภาษาไทย · Bahasa Indonesia · Italiano · Nederlands · Türkçe · العربية

## Instalación y compilación

Preparación con un solo comando (`flutter pub get` + aplicar parches), luego compila:

```bash
# Desde la raíz del repositorio
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1

cd fushi
# Android
flutter build apk --release --target-platform android-arm64 --split-per-abi
# Escritorio Windows
flutter build windows --release
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` agrupan `flutter pub get` y `ci/apply-patches.sh` en un único comando. Este proyecto está fijado a Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`); algunas dependencias upstream están incluidas en `third_party/` o parcheadas por `ci/apply-patches.sh`; consulta [docs/agent/build.md](../agent/build.md) para más detalles.

<details>
<summary><b>Pila tecnológica</b></summary>

| Capa | Tecnología |
|---|---|
| Framework | Flutter 3.44.0 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plataformas | Android / Windows / macOS / iOS (Material Design 3) |
| Lector | Motor de paginación WebView (derivado de la familia Hoshi Reader) |
| Vídeo | media_kit (libmpv core) |
| Almacenamiento | Drift (SQLite, WAL) + fushidicts (motor de diccionarios FFI en C++) |
| PLN | Tablas de transformación de Yomitan (lematización multilingüe) + kana_kit (conversión de kana); tokenización mediante fushidicts FFI |
| Creación de tarjetas | AnkiDroid API + AnkiConnect |
| i18n | Slang (17 idiomas) |

</details>

<details>
<summary><b>Estructura del proyecto</b></summary>

```
Fushi/                      # Raíz del repositorio (espacio de trabajo Melos: fushi_workspace)
├── fushi/                  # Directorio principal de la aplicación Flutter
│   ├── lib/
│   │   ├── i18n/            # Internacionalización (17 idiomas, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Páginas (estantería, lector, diccionario, ajustes, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS del WebView del lector
│   │   │   ├── media/       # Audiolibros, análisis de subtítulos, fuente del lector
│   │   │   └── models/      # Modelos de datos y gestión de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Proyecto Android (manifest, fushidicts nativo)
├── packages/                # Paquetes internos + flutter_inappwebview_windows (fork) + gamepads_android_stub
├── native/                  # Motor de diccionarios en C++ fushidicts (FFI)
├── third_party/             # Paquetes parcheados incluidos (dependency_overrides)
├── ci/                      # Parches de compilación y scripts de pruebas de integración
├── tool/                    # Scripts bootstrap / i18n_sync y otros
└── docs/                    # Documentación de desarrollo (incl. manual de operaciones docs/agent/)
```

</details>

## Privacidad y datos

Fushi almacena los libros importados, diccionarios, fuentes, datos de audiolibros, vídeos, progreso de lectura, resaltados, estadísticas y ajustes en el almacenamiento local de la aplicación.

La sincronización en la nube (Google Drive / OneDrive / Dropbox) utiliza credenciales OAuth configuradas por el usuario; WebDAV / FTP / SFTP usa direcciones de servidor y credenciales proporcionadas por el usuario; Fushi Interconnect se conecta directamente mediante una dirección configurada por el usuario. La creación de tarjetas Anki se comunica con AnkiDroid o con una dirección de AnkiConnect configurada.

## Agradecimientos

Fushi se apoya en los siguientes proyectos y ecosistema:

| Proyecto | Descripción |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Herramienta de aprendizaje inmersivo de japonés |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lector de japonés para iOS; referencia del motor de paginación del lector |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lector de japonés nativo para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motor de diccionarios en C++ |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solución de sincronización de audiolibros |
| [Yomitan](https://github.com/yomidevs/yomitan) | Referencia de formato de diccionario, tablas de transformación y experiencia de búsqueda |
| [Lapis](https://github.com/donkuri/lapis) | Tipo de nota de Anki |
| [AnkiDroid](https://github.com/ankidroid/Anki-Android) | Integración de creación de tarjetas en Android |
| [Ankiconnect Android](https://github.com/KamWithK/AnkiconnectAndroid) | Referencia de audio local e interacción con AnkiDroid |
| [ッツ Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Referencia de compatibilidad de lector, estadísticas y sincronización |
| [media_kit](https://github.com/media-kit/media-kit) | Framework de reproducción de vídeo de Flutter (núcleo libmpv) |
| [Niratan](https://github.com/W1ght/Niratan) | Suite de aprendizaje inmersivo de idiomas para macOS |

## Licencia

Distribuido bajo la Licencia Pública General de GNU v3.0. Consulta [LICENSE](../../LICENSE) para más detalles.

<div align="center">

<br>

[简体中文](../../README.zh-CN.md) | [English](../../README.md) | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | **Español** | [Français](README.fr.md) | [Deutsch](README.de.md) | [Português](README.pt-BR.md) | [Русский](README.ru.md) | [Tiếng Việt](README.vi.md) | [ภาษาไทย](README.th.md) | [Bahasa Indonesia](README.id.md) | [Italiano](README.it.md) | [Nederlands](README.nl.md) | [Türkçe](README.tr.md) | [العربية](README.ar.md)

</div>
