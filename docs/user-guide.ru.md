# Руководство пользователя hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | **Русский** | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | [العربية](user-guide.ar.md)

> Руководство на упрощённом китайском размещено на Feishu (ссылка выше). Руководство на английском также доступно [на GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## Введение

Это бесплатное программное обеспечение для Android / Windows (iOS / macOS в планах) — революционное кроссплатформенное приложение с открытым исходным кодом, объединяющее чтение книг, воспроизведение аудиокниг, воспроизведение видео и поиск по словарям.

### URL проекта

https://github.com/hajisensai/hibiki

Активно разрабатывается — ваши отзывы будут оперативно обработаны. Сообщения об ошибках и предложения функций приветствуются. Если Hibiki оказался вам полезен, будем благодарны, если вы поделитесь им или поставите ⭐ репозиторию.

### Загрузка

https://github.com/hajisensai/hibiki/releases/latest

Android: выберите **arm64**. Windows: выберите файл **.exe**.

## Руководство по настройке

### 1. Импорт рекомендуемых словарей и локального аудио (необязательно)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

В приложении: Настройки -> Синхронизация и резервное копирование -> нажмите **Импортировать резервную копию**.

**Примечание: импорт резервной копии удалит локальные данные. Этот процесс будет улучшен в будущем обновлении.**

![Экран импорта резервной копии](static-assets/user-guide/import-backup.png)

### 2. Скачайте и настройте Anki с официального сайта Anki

Anki — название происходит от 暗記 (あんき) — это самая распространённая в мире [система интервальных повторений (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) и очень важный инструмент.

Ссылки: [Официальный сайт Anki](https://apps.ankiweb.net/) · [Руководство (китайский)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [ЧаВо](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(китайский)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[Изображение: иллюстрация / легенда]*

Вы можете передать Anki любой материал, который хотите запомнить, и он позволит добиться наилучшего запоминания при минимальном времени обучения.

В Anki встроен [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) — один из лучших в мире алгоритмов интервальных повторений.

**НО!!!** Алгоритм Anki по умолчанию — SM2, алгоритм более чем 30-летней давности с низкой эффективностью. Обязательно переключите используемый Anki алгоритм на **FSRS**.

#### Anki

##### Android

1. Установите и откройте Anki.
2. Вернитесь в hibiki, перейдите в Настройки -> Создание карточек.
3. Нажмите **Обновить колоды и типы заметок** (отмечено цифрой «1» на изображении); hibiki запросит разрешение — нажмите «Разрешить».
4. Нажмите **Создать колоду Lapis** (отмечено цифрой «2» на изображении).
5. Если нет красных предупреждений или ошибок, настройка прошла успешно.

![Настройка Anki на Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. Установите и откройте Anki.
2. Нажмите **Инструменты (Tools)** в левом верхнем углу.

![Меню «Инструменты» Anki в Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. Вставьте приведённый ниже код дополнения Anki, чтобы установить его: `2055492159`
4. Вернитесь в hibiki, перейдите в Настройки -> Создание карточек.
5. Нажмите **Обновить колоды и типы заметок** (отмечено «1»).
6. Нажмите **Создать колоду Lapis** (отмечено «2»).
7. Если нет красных предупреждений или ошибок, настройка прошла успешно.

![Настройка Anki в Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. Просмотрите параметры в Настройках и проверьте, не хотите ли вы что-то изменить. (Необязательно)

## Благодарности

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
