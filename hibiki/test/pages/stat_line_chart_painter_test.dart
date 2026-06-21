import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_charts.dart';

StatLineChartPainter _painter({
  List<StatLineSeries>? series,
  List<String>? xLabels,
  List<bool>? anomalies,
  Color anomalyColor = const Color(0xFFFF0000),
  Color labelColor = const Color(0xFF000000),
  int labelEvery = 5,
}) =>
    StatLineChartPainter(
      series: series ??
          <StatLineSeries>[
            const StatLineSeries(
                values: <double>[1, 2, 3], color: Color(0xFF0000FF)),
          ],
      xLabels: xLabels ?? <String>['a', 'b', 'c'],
      anomalies: anomalies ?? <bool>[false, false, true],
      anomalyColor: anomalyColor,
      labelColor: labelColor,
      labelStyle: const TextStyle(fontSize: 10),
      labelFormatter: formatStatCphAxis,
      labelEvery: labelEvery,
    );

void main() {
  group('StatLineChartPainter.shouldRepaint', () {
    test('identical inputs -> no repaint', () {
      expect(_painter().shouldRepaint(_painter()), isFalse);
    });

    test('changed series values -> repaint', () {
      final StatLineChartPainter a = _painter();
      final StatLineChartPainter b = _painter(
        series: <StatLineSeries>[
          const StatLineSeries(
              values: <double>[1, 2, 9], color: Color(0xFF0000FF)),
        ],
      );
      expect(b.shouldRepaint(a), isTrue);
    });

    test('changed series color -> repaint', () {
      final StatLineChartPainter a = _painter();
      final StatLineChartPainter b = _painter(
        series: <StatLineSeries>[
          const StatLineSeries(
              values: <double>[1, 2, 3], color: Color(0xFF00FF00)),
        ],
      );
      expect(b.shouldRepaint(a), isTrue);
    });

    test('changed dashed flag -> repaint', () {
      final StatLineChartPainter a = _painter();
      final StatLineChartPainter b = _painter(
        series: <StatLineSeries>[
          const StatLineSeries(
              values: <double>[1, 2, 3],
              color: Color(0xFF0000FF),
              dashed: true),
        ],
      );
      expect(b.shouldRepaint(a), isTrue);
    });

    test('changed anomalies -> repaint', () {
      final StatLineChartPainter a = _painter();
      final StatLineChartPainter b =
          _painter(anomalies: <bool>[true, false, false]);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('changed xLabels -> repaint', () {
      final StatLineChartPainter a = _painter();
      final StatLineChartPainter b = _painter(xLabels: <String>['x', 'y', 'z']);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('changed labelEvery -> repaint', () {
      final StatLineChartPainter a = _painter();
      final StatLineChartPainter b = _painter(labelEvery: 1);
      expect(b.shouldRepaint(a), isTrue);
    });

    test('changed anomalyColor -> repaint', () {
      final StatLineChartPainter a = _painter();
      final StatLineChartPainter b =
          _painter(anomalyColor: const Color(0xFF112233));
      expect(b.shouldRepaint(a), isTrue);
    });
  });

  group('StatLineChartPainter.paint does not crash on edge cases', () {
    void paintOnce(StatLineChartPainter painter, Size size) {
      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      painter.paint(canvas, size);
      recorder.endRecording();
    }

    test('empty series', () {
      final StatLineChartPainter p = StatLineChartPainter(
        series: const <StatLineSeries>[],
        xLabels: const <String>[],
        anomalies: const <bool>[],
        anomalyColor: const Color(0xFFFF0000),
        labelColor: const Color(0xFF000000),
        labelStyle: const TextStyle(fontSize: 10),
        labelFormatter: formatStatCphAxis,
      );
      paintOnce(p, const Size(200, 120));
    });

    test('single point series', () {
      final StatLineChartPainter p = _painter(
        series: <StatLineSeries>[
          const StatLineSeries(values: <double>[42], color: Color(0xFF0000FF)),
        ],
        xLabels: <String>['only'],
        anomalies: <bool>[false],
      );
      paintOnce(p, const Size(200, 120));
    });

    test('all-zero values (degenerate max)', () {
      final StatLineChartPainter p = _painter(
        series: <StatLineSeries>[
          const StatLineSeries(
              values: <double>[0, 0, 0], color: Color(0xFF0000FF)),
        ],
        anomalies: <bool>[false, false, false],
      );
      paintOnce(p, const Size(200, 120));
    });
  });
}
