/// 发现域的字节数可读格式（`1.2 GiB` / `512 B`）。
///
/// 发现页条目副标题、下载页直链任务行与「AI 下视频」的资源卡片共用；原先是发现
/// 页的私有静态方法，任务行要显示「已收/总」时抄一份就是两份真相源。与语言无关，
/// 所以住在引擎（互联 host 与无头服务端投影会话快照时也要用）。
String formatDiscoveryBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = <String>['KiB', 'MiB', 'GiB', 'TiB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(value >= 100 ? 0 : 1)} ${units[unit]}';
}
