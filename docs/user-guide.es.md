# Guía de usuario de hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | **Español** | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> La guía en chino simplificado está alojada en Feishu (enlace arriba). La guía en inglés también está disponible [en GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Introducción

Este es software gratuito para Android / Windows (iOS / macOS en planificación): una aplicación de código abierto multiplataforma e innovadora que combina la lectura de novelas, la reproducción de audiolibros, la reproducción de vídeo y la búsqueda en diccionarios.

### URL del proyecto

https://github.com/hajisensai/hibiki

En desarrollo activo: tus comentarios se atenderán con prontitud. Los informes de errores y las solicitudes de funciones son bienvenidos. Si Hibiki te resulta útil, te agradeceríamos que lo compartieras con otras personas o que dejaras una ⭐ en el repositorio.

### Descarga

https://github.com/hajisensai/hibiki/releases/latest

Android: elige **arm64**. Windows: elige el archivo **.exe**.

## Tutorial de configuración

### 1. Importar los diccionarios recomendados y el audio local (opcional)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

En la aplicación: Ajustes -> Sincronización y copia de seguridad -> toca **Importar copia de seguridad**.

**Nota: importar una copia de seguridad borrará los datos locales. Este flujo se mejorará en una futura actualización.**

![Pantalla de importación de copia de seguridad](static-assets/user-guide/import-backup.png)

### 2. Descargar y configurar Anki desde el sitio oficial de Anki

Anki —cuyo nombre proviene de 暗記 (あんき)— es el [sistema de repetición espaciada (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) más utilizado del mundo y una herramienta muy importante.

Enlaces: [Sitio oficial de Anki](https://apps.ankiweb.net/) · [Manual (chino)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [Preguntas frecuentes](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(chino)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Imagen: ilustración / leyenda]*

Puedes darle a Anki cualquier material que quieras memorizar, y te permite lograr la mejor retención con el menor tiempo de estudio.

Anki incorpora [FSRS](https://github.com/open-spaced-repetition/fsrs4anki), uno de los mejores algoritmos de repetición espaciada del mundo.

**¡PERO!!!** El algoritmo predeterminado de Anki es SM2, un algoritmo de hace más de 30 años que rinde mal. Asegúrate de cambiar el algoritmo que usa Anki a **FSRS**.

#### Anki

##### Android

1. Instala y abre Anki.
2. Vuelve a hibiki y ve a Ajustes -> Creación de tarjetas.
3. Toca **Actualizar mazos y tipos de nota** (marcado con un "1" en la imagen); hibiki solicitará permiso: toca Permitir.
4. Toca **Crear mazo Lapis** (marcado con un "2" en la imagen).
5. Si no aparece ninguna advertencia ni error en rojo, la configuración fue exitosa.

![Configuración de Anki en Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Instala y abre Anki.
2. Haz clic en **Herramientas (Tools)** en la parte superior izquierda.

![Menú Herramientas de Anki en Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Pega el siguiente código del complemento de Anki para instalarlo: `2055492159`
4. Vuelve a hibiki y ve a Ajustes -> Creación de tarjetas.
5. Toca **Actualizar mazos y tipos de nota** (marcado con "1").
6. Toca **Crear mazo Lapis** (marcado con "2").
7. Si no aparece ninguna advertencia ni error en rojo, la configuración fue exitosa.

![Configuración de Anki en Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Revisa las opciones de configuración en Ajustes y comprueba si hay algo que quieras ajustar. (Opcional)

## Agradecimientos

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
