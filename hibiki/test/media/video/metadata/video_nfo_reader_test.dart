import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/metadata/video_nfo_reader.dart';
import 'package:path/path.dart' as p;

void main() {
  test('third-party tvshow and episode NFO become structured work data',
      () async {
    final Directory root = await Directory.systemTemp.createTemp('nfo-read-');
    addTearDown(() => root.delete(recursive: true));
    final Directory show = Directory(p.join(root.path, 'Show'))..createSync();
    final String episode = p.join(show.path, 'Show.S02E03.mkv');
    File(episode).writeAsBytesSync(<int>[0]);
    File(p.join(show.path, 'tvshow.nfo')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<tvshow>
  <title>系列标题</title><originaltitle>Original</originaltitle>
  <plot>作品简介 &amp; 详情</plot><year>2024</year><rating>8.6</rating>
  <runtime>24</runtime><mpaa>PG-13</mpaa>
  <uniqueid type="tmdb" default="true">123</uniqueid>
  <genre>Animation</genre><studio>Studio A</studio><country>JP</country>
  <actor><name>声优甲</name><role>角色乙</role><type>voice_actor</type></actor>
</tvshow>''');
    File(p.setExtension(episode, '.nfo')).writeAsStringSync('''
<episodedetails><title>第三集</title><season>2</season><episode>3</episode>
<plot>分集简介</plot><aired>2024-04-01</aired></episodedetails>''');

    final work = await const VideoNfoReader().readForPaths(
      sourceRoot: root.path,
      fallbackTitle: 'fallback',
      videoPaths: <String>[episode],
    );

    expect(work, isNotNull);
    expect(work!.title, '系列标题');
    expect(work.plot, '作品简介 & 详情');
    expect(work.ids.single.value, '123');
    expect(work.studios, <String>['Studio A']);
    expect(work.credits.single.person.name, '声优甲');
    expect(work.credits.single.character?.name, '角色乙');
    expect(work.seasons.single.seasonNumber, 2);
    expect(work.seasons.single.episodes.single.title, '第三集');
  });
}
