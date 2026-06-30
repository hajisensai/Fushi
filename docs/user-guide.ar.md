# دليل مستخدم hibiki

[English](user-guide.md) | [简体中文](https://ncnies6wfjok.feishu.cn/wiki/OZbww3T3IiEAx5kBhHkcF07vncb) | [繁體中文](user-guide.zh-Hant.md) | [日本語](user-guide.ja.md) | [한국어](user-guide.ko.md) | [Español](user-guide.es.md) | [Français](user-guide.fr.md) | [Deutsch](user-guide.de.md) | [Português](user-guide.pt-BR.md) | [Русский](user-guide.ru.md) | [Tiếng Việt](user-guide.vi.md) | [ภาษาไทย](user-guide.th.md) | [Bahasa Indonesia](user-guide.id.md) | [Italiano](user-guide.it.md) | [Nederlands](user-guide.nl.md) | [Türkçe](user-guide.tr.md) | **العربية**

> دليل الصينية المبسّطة مُستضاف على Feishu (الرابط أعلاه). الدليل الإنجليزي متوفّر أيضًا [على GitHub](https://github.com/hajisensai/hibiki/blob/main/docs/user-guide.md).

## مقدمة

هذا برنامج مجاني لنظامي Android / Windows (يُخطَّط لدعم iOS / macOS) — تطبيق مفتوح المصدر متعدّد المنصّات ورائد، يجمع بين قراءة الروايات وتشغيل الكتب الصوتية وتشغيل الفيديو والبحث في القواميس.

### رابط المشروع

https://github.com/hajisensai/hibiki

قيد التطوير النشط — ستُعالَج ملاحظاتك على الفور. نرحّب بتقارير الأخطاء وطلبات الميزات. إذا وجدت Hibiki مفيدًا، فسنكون ممتنّين إذا شاركته مع الآخرين أو منحت المستودع نجمة ⭐.

### التنزيل

https://github.com/hajisensai/hibiki/releases/latest

‏Android: اختر **arm64**. ‏Windows: اختر ملف **.exe**.

## دليل الإعداد

### 1. استيراد القواميس المُوصى بها والصوت المحلي (اختياري)

[OneDrive](https://zfile.kanochi.cn/dl/Public/%E6%9D%82%E9%A1%B9/hibiki-backup-2026-06-29.hibiki.zip) / [Google Drive](https://drive.google.com/file/d/1JYzv6dXB5sDPQBxttFLJzlmN3XTTo79S/view?usp=sharing)

داخل التطبيق: الإعدادات -> المزامنة والنسخ الاحتياطي -> اضغط على **استيراد نسخة احتياطية**.

**ملاحظة: استيراد نسخة احتياطية سيمسح البيانات المحلية. سيُحسَّن هذا المسار في تحديث مستقبلي.**

![شاشة استيراد النسخة الاحتياطية](static-assets/user-guide/import-backup.png)

### 2. تنزيل Anki وإعداده من موقع Anki الرسمي

‏Anki — المُسمّى نسبةً إلى 暗記 (あんき) — هو [نظام التكرار المتباعد (SRS)](https://en.wikipedia.org/wiki/Spaced_repetition) الأكثر استخدامًا في العالم، وأداة مهمة جدًا.

الروابط: [موقع Anki الرسمي](https://apps.ankiweb.net/) · [الدليل (بالصينية)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/) · [الأسئلة الشائعة](https://eaa9gdwuyv7.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f) [(بالصينية)](https://open-spaced-repetition.github.io/anki-manual-zh-CN/)

*[صورة: توضيح / مفتاح الرموز]*

يمكنك أن تعطي Anki أي مادة تريد حفظها، فيتيح لك تحقيق أفضل احتفاظ بالمعلومات بأقل وقت دراسة.

يحتوي Anki على [FSRS](https://github.com/open-spaced-repetition/fsrs4anki) مدمجًا — أحد أفضل خوارزميات التكرار المتباعد في العالم.

**لكن!!!** الخوارزمية الافتراضية في Anki هي SM2، وهي خوارزمية عمرها أكثر من 30 عامًا وأداؤها ضعيف. يُرجى التأكد من تبديل الخوارزمية التي يستخدمها Anki إلى **FSRS**.

#### Anki

##### Android

1. ثبّت Anki وافتحه.
2. عُد إلى hibiki، وانتقل إلى الإعدادات -> إنشاء البطاقات.
3. اضغط على **تحديث المجموعات وأنواع الملاحظات** (المُعلَّمة بـ "1" في الصورة)؛ سيطلب hibiki إذنًا — اضغط على السماح.
4. اضغط على **إنشاء مجموعة Lapis** (المُعلَّمة بـ "2" في الصورة).
5. إذا لم يظهر أي تحذير أو خطأ باللون الأحمر، فقد نجح الإعداد.

![إعداد Anki على Android](static-assets/user-guide/anki-android-setup.png)

##### Windows

1. ثبّت Anki وافتحه.
2. انقر على **أدوات (Tools)** في أعلى اليسار.

![قائمة أدوات Anki على Windows](static-assets/user-guide/anki-windows-tools-menu.png)

3. الصق رمز إضافة Anki أدناه لتثبيتها: `2055492159`
4. عُد إلى hibiki، وانتقل إلى الإعدادات -> إنشاء البطاقات.
5. اضغط على **تحديث المجموعات وأنواع الملاحظات** (المُعلَّمة بـ "1").
6. اضغط على **إنشاء مجموعة Lapis** (المُعلَّمة بـ "2").
7. إذا لم يظهر أي تحذير أو خطأ باللون الأحمر، فقد نجح الإعداد.

![إعداد Anki على Windows](static-assets/user-guide/anki-windows-setup.png)

### 3. تصفّح خيارات التهيئة في الإعدادات وتحقّق مما إذا كان هناك شيء ترغب في تعديله. (اختياري)

## شكر وتقدير

- [平泽唯也能看懂的yomitan/Lapis/mpvacious/ShareX配置教程](https://dcnyv3xgibev.feishu.cn/wiki/Qa1HwnZJBiGyyLk4mO4cw4Nhn0d)
- [基于二语习得理论的日语学习指南](https://my.feishu.cn/wiki/YeOSwsG7giLuQxkcDFscUXVZn2f)
