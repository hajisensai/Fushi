/// 查词空态导入面的三种方式（[DictionaryImportAction]）：查词主页的空态把它交给
/// `AppModel.showDictionaryMenu(initialAction:)`，词典管理页一打开就跑对应动作；
/// 管理页自己的空态直接调。单独一个文件，不带界面依赖（`app_model.dart` 也引用）。
library;

/// 导入词典文件 / 导入文件夹词典 / 下载推荐词典。
enum DictionaryImportAction { files, folder, download }
