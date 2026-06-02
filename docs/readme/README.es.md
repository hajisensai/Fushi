<h3 align="center">hibiki</h3>
<p align="center">
  <img src="../static-assets/hibiki-logo.png" alt="hibiki logo" width="160">
</p>

<p align="center">
  <a href="https://hdjsadgfwtg.github.io/hibiki/"><b>GitHub Pages</b></a>
</p>

<p align="center">Lector inmersivo de japonés para Android</p>
<p align="center">EPUB · Diccionarios · Anki · Sincronización de audiolibros</p>

<p align="center">
  <a href="../../README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a> · <b>Español</b> · <a href="README.fr.md">Français</a> · <a href="README.de.md">Deutsch</a> · <a href="README.pt-BR.md">Português</a> · <a href="README.ru.md">Русский</a> · <a href="README.it.md">Italiano</a> · <a href="README.nl.md">Nederlands</a> · <a href="README.tr.md">Türkçe</a> · <a href="README.vi.md">Tiếng Việt</a> · <a href="README.th.md">ภาษาไทย</a> · <a href="README.id.md">Bahasa Indonesia</a> · <a href="README.ar.md">العربية</a> · <a href="README.zh-Hant.md">繁體中文</a>
</p>

---

## Introducción

**hibiki** es una aplicación de lectura para Android diseñada para estudiantes de japonés.

## Funciones

### Lector EPUB
- Renderizado de EPUB en WebView (motor de paginación derivado de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader))
- Toca para buscar palabras, selecciona texto para analizar
- Fuentes personalizadas, temas (claro/oscuro)
- Estadísticas de lectura y marcadores
- Desplazamiento continuo / modo paginado

### Diccionarios
- Importa diccionarios en formato [Yomitan](https://github.com/yomidevs/yomitan) (antes Yomichan)
- Información de acento tonal y frecuencia de palabras
- Búsqueda paralela en múltiples diccionarios, historial de búsqueda
- Lematización con Ve

### Creación de tarjetas Anki
- Exportación con un toque a [AnkiDroid](https://github.com/ankidroid/Anki-Android)
- Autocompletado de oraciones de contexto
- Soporte para grabación de audio y recorte de capturas de pantalla
- Múltiples perfiles de exportación, mapeo de campos personalizado
- Acciones rápidas (Quick Actions) para crear tarjetas en un paso

### Sincronización de audiolibros (Sasayaki)
- Formatos de subtítulos: SRT / LRC / VTT / ASS
- Alineación automática de subtítulos con el texto del EPUB
- Resaltado de seguimiento, paso de página sincronizado con el audio
- Barra de controles de reproducción (progreso, saltar, velocidad)

### Otros
- 17 idiomas de interfaz
- Múltiples perfiles de usuario
- Modo incógnito
- Compartir texto desde otras aplicaciones para buscar palabras directamente

## Idiomas soportados

La interfaz es compatible con los siguientes idiomas:

| Idioma | Código |
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

## Stack tecnológico

| Capa | Tecnología |
|---|---|
| Framework | Flutter 3.41.6 (Dart SDK `>=3.5.0 <4.0.0`) |
| Plataforma | Android / iOS / macOS / Windows / Linux (Material 3 + Cupertino adaptativo) |
| Lector | Motor de paginación WebView (derivado de [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader)) |
| Almacenamiento | Drift (SQLite, WAL) + hoshidicts (motor de diccionarios C++ FFI) |
| NLP | Ve (lematización) |
| Creación de tarjetas | AnkiDroid API |
| Internacionalización | Slang (17 idiomas) |
| Versión mínima | Android 7.0 (API 24) |

## Compilación

Preparación con un solo comando (`flutter pub get` + aplica los parches), luego compilar:

```bash
# en la raíz del repositorio
bash tool/bootstrap.sh          # Windows PowerShell: .\tool\bootstrap.ps1
                                # o (Linux/macOS): dart run melos bootstrap

cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

`tool/bootstrap.sh` / `tool/bootstrap.ps1` reúne dos pasos en un solo comando: ① `flutter pub get`; ② ejecución de `ci/apply-patches.sh`. `melos bootstrap` hace lo mismo mediante un post-hook (en Windows melos tiene un bug de codificación CJK, así que usa `tool/bootstrap.ps1`).

> **Nota sobre los parches:** `ci/apply-patches.sh` sobrescribe el pub cache real con los cambios de `ci/patches/`. Debe volver a ejecutarse tras cada limpieza del pub cache o nuevo `flutter pub get` (bootstrap ya incluye este paso). Si el script no encuentra ningún objetivo de parche, lo omite y avisa en lugar de fingir éxito.

## Dependencias y parches

Este proyecto está fijado a Flutter 3.41.6; algunas dependencias upstream aún no se han adaptado. Las correcciones siguen dos vías: ① los paquetes que deben servir como entrada de compilación y reproducirse de forma coherente entre máquinas se vendorizan directamente en `third_party/` y se referencian mediante `dependency_overrides` (`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`, **sin** necesidad de parchear el pub cache); ② el resto de paquetes los parchea `ci/apply-patches.sh` en el código fuente del pub cache. Detalles del mecanismo en [docs/agent/build.md](../agent/build.md). Las tablas plegables siguientes son un listado histórico agrupado por cambio; cuando se solapan con el mecanismo ①, prevalece la versión vendorizada.

<details>
<summary><b>Parches de cambios en la API de Flutter</b></summary>

| Paquete | Cambios |
|---|---|
| `network_to_file_image` 4.0.1 | `load` → `loadImage`; `DecoderCallback` → `ImageDecoderCallback`; `hashValues` → `Object.hash`; `instantiateImageCodec` → `ImmutableBuffer` + `ImageDescriptor`; reemplazar `imageCache.putIfAbsent` eliminado |
| `flutter_blurhash` 0.7.0 | Mismos cambios de `loadImage` / `hashValues` / `ImmutableBuffer` |
| `RubyText` (git) | `MediaQuery.boldTextOverride` → `boldTextOf` |
| `material_floating_search_bar` (git) | `headline6` → `titleLarge`; `subtitle1` → `titleMedium` |
| `win32` 4.1.4 | `UnmodifiableUint8ListView` → `Uint8List` |
| `carousel_slider` 4.2.1 | Agregado `hide CarouselController` en imports internos para evitar conflictos de nombres |
| `fading_edge_scrollview` 3.0.0 | Corrección de `PageView.controller` nullable |

</details>

<details>
<summary><b>Parches de eliminación del v1 Embedding</b></summary>

Flutter 3.41.6 eliminó completamente la API de v1 embedding (`PluginRegistry.Registrar`). Los siguientes plugins requieren la eliminación de las referencias relacionadas:

`flutter_plugin_android_lifecycle` · `file_picker` · `flutter_inappwebview` · `fluttertoast` · `image_picker_android` · `mecab_dart` · `permission_handler_android` · `url_launcher_android` · `path_provider_android` · `sqflite` · `record_mp3_plus`

</details>

<details>
<summary><b>Parches de Gradle / Kotlin</b></summary>

| Objetivo | Cambios |
|---|---|
| `android/build.gradle` afterEvaluate | Forzar `compileSdk` (por defecto 36, algunos 34) en subproyectos; eliminar `-Werror` |
| `audio_session` 0.1.14 | Eliminar `-Werror`, `-Xlint:deprecation` |
| `package_info_plus` 4.0.2 | Corrección de seguridad null en Kotlin |
| `receive_intent` (git) | Corrección de seguridad null en Kotlin |

</details>

<details>
<summary><b>Dependencias Git</b></summary>

| Paquete | Fuente |
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

## Estructura del proyecto

```
hibiki/                      # Raíz del repositorio (workspace Melos: hibiki_workspace)
├── hibiki/                  # Directorio principal de la aplicación Flutter
│   ├── lib/
│   │   ├── i18n/            # Internacionalización (17 idiomas, Slang)
│   │   ├── src/
│   │   │   ├── pages/       # Páginas (estantería, lector, diccionario, ajustes, etc.)
│   │   │   ├── reader/      # Scripts JS/CSS de la WebView del lector
│   │   │   ├── media/       # Audiolibros, análisis de subtítulos, reader source
│   │   │   └── models/      # Modelos de datos y gestión de estado (AppModel)
│   │   └── main.dart
│   └── android/             # Proyecto Android (manifest, hoshidicts nativo)
├── packages/                # Paquetes internos + flutter_inappwebview_windows(fork) + gamepads_android_stub
├── third_party/             # Paquetes de parches vendorizados (referenciados por dependency_overrides)
├── ci/                      # Parches de compilación y scripts de pruebas de integración
├── tool/                    # Scripts bootstrap / i18n_sync, etc.
└── docs/                    # Documentación de desarrollo (incluye el manual de agente docs/agent/)
```

## Agradecimientos

| Proyecto | Descripción |
|---|---|
| [jidoujisho](https://github.com/arianneorpilla/jidoujisho) | Herramienta de aprendizaje inmersivo de japonés |
| [Hoshi Reader Android](https://github.com/HuangAntimony/Hoshi-Reader-Android) | Lector de japonés para Android |
| [hoshidicts](https://github.com/Manhhao/hoshidicts) | Motor de diccionarios C++ |
| [Hoshi Reader](https://github.com/Manhhao/Hoshi-Reader) | Lector de japonés para iOS |
| [Sasayaki](https://github.com/Manhhao/Hoshi-Reader/blob/develop/SASAYAKI.md) | Solución de sincronización de audiolibros |
| [ttu Ebook Reader](https://github.com/ttu-ttu/ebook-reader) | Motor de renderizado EPUB |
| [kamperemu/ebook-reader](https://github.com/kamperemu/ebook-reader) | Versión mantenida por la comunidad de ttu (SvelteKit v2), base upstream del fork de hibiki |
| [Yomitan](https://github.com/yomidevs/yomitan) | Fuente del formato de diccionarios |

## Licencia

[GNU General Public License v3.0](../../LICENSE)
