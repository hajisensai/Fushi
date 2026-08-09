// 源码守卫：gal 台词浮窗 / 剪切板文字窗的振假名渲染结构。
//
// 两个浮窗都不是 Flutter widget，而是 runner 自有的 Win32 分层窗（Direct2D +
// DirectWrite 直绘），C++ 无法在 Dart 测试里执行，故在源码层锁死这次改动赖以成立
// 的四条结构性前提：
//   ① 注音几何复用 HitTestTextRange（与高亮背景框同一套），不自建第二套排版；
//   ② text_ 里**不含**任何注音字符，CharIndexAt 仍直接回传 DirectWrite 的
//      textPosition —— 点字查词的 UTF-16 index 契约一个字都没改；
//   ③ 没有注音时完全不走注音分支（行距不动、不额外绘制），逐像素回到今天；
//   ④ 两个通道的 updateText 都把 rubySpans 解包下发，且越界区间被丢弃。
//
// ① 是这次能用「附加绘制」而不是「重写渲染路径」的全部原因：一旦有人改成自建
// 布局或自定义 IDWriteTextRenderer，折行 / 滚动 / 高亮 / dim 四处几何就会各走各的，
// 点字 index 也会跟着漂。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String window =
      File('windows/runner/floating_lyric_window.cpp').readAsStringSync();
  final String header =
      File('windows/runner/floating_lyric_window.h').readAsStringSync();
  final String channelHost =
      File('windows/runner/flutter_window.cpp').readAsStringSync();

  test('① 注音几何复用 HitTestTextRange，不自建排版', () {
    expect(
      window.contains('ruby_spans_'),
      isTrue,
      reason: '注音区间成员必须存在，否则这套渲染根本没接上',
    );
    // 注音绘制段必须出现在同一个 text_layout_ 上的 HitTestTextRange 调用。
    expect(
      RegExp(r'for \(const RubySpan& span : ruby_spans_\)[\s\S]{0,400}?'
              r'text_layout_->HitTestTextRange')
          .hasMatch(window),
      isTrue,
      reason: '注音必须问 text_layout_ 要基准字矩形（与高亮框同一套几何）；'
          '自己排版会让折行/滚动/高亮/dim 四处几何分叉',
    );
    for (final String forbidden in <String>[
      'IDWriteTextRenderer',
      'SetInlineObject',
    ]) {
      expect(
        window.contains(forbidden),
        isFalse,
        reason: '$forbidden 会改变布局位置与原文位置的对应关系，'
            '必须同时补一张 index 映射表，CharIndexAt 契约就守不住了',
      );
    }
  });

  test('② text_ 只存纯基准文本，CharIndexAt 仍直回 textPosition', () {
    expect(
      window.contains('return static_cast<int>(metrics.textPosition);'),
      isTrue,
      reason: '点字 index 必须仍是 DirectWrite 的 UTF-16 textPosition；'
          '一旦这里变成经过映射的值，Dart 侧的 wordFromIndex 就会错位',
    );
    // 注音文本只从 span.ruby 取，绝不拼进 text_。
    expect(
      RegExp(r'text_\s*(\+=|\.append|\.insert)').hasMatch(window),
      isFalse,
      reason: 'text_ 一旦被追加注音字符，显示串就不再等于 Dart 侧的 entry.text，'
          'gal 浮窗 _onLookupText 的等值守卫会恒真，点字直接失效',
    );
  });

  test('③ 无注音时不走任何注音分支', () {
    expect(
      window.contains('const bool has_ruby = !ruby_spans_.empty();'),
      isTrue,
      reason: '必须有一个统一的 has_ruby 门，空注音时行距与绘制都不动',
    );
    expect(
      RegExp(r'if \(has_ruby && text_layout_ != nullptr\)[\s\S]{0,600}?'
              r'SetLineSpacing')
          .hasMatch(window),
      isTrue,
      reason: '加高行距必须挂在 has_ruby 门后；无条件改行距会让所有老浮窗观感变化',
    );
    expect(
      RegExp(r'if \(has_ruby && ruby_format_ != nullptr\)').hasMatch(window),
      isTrue,
      reason: '注音绘制同样必须挂在 has_ruby 门后',
    );
  });

  test('④ 两个通道解包 rubySpans，且越界区间被丢弃', () {
    expect(
      'rubySpans'.allMatches(channelHost).length,
      greaterThanOrEqualTo(2),
      reason: 'gal 台词窗与剪切板文字窗两处 updateText 都要解包 rubySpans',
    );
    expect(
      RegExp(r'gal_hook_text_window_->UpdateText\([\s\S]{0,200}?'
              r'RubySpansFromValue\(args, "rubySpans"\)')
          .hasMatch(channelHost),
      isTrue,
      reason: 'gal 台词浮窗必须下发注音区间',
    );
    expect(
      RegExp(r'clipboard_text_window_->UpdateText\([\s\S]{0,200}?'
              r'RubySpansFromValue\(args, "rubySpans"\)')
          .hasMatch(channelHost),
      isTrue,
      reason: '剪切板文字窗必须下发注音区间',
    );
    // 越界保护：UpdateText 必须按最终文本长度过滤，绝不让错位注音飘在别的字上。
    expect(
      RegExp(r'span\.start \+ span\.length > text_length').hasMatch(window),
      isTrue,
      reason: '注音区间必须按新文本长度校验；越界的要丢掉而不是照画',
    );
    // 缺省参数 = 老 payload 行为不变。
    expect(
      RegExp(r'const std::vector<RubySpan>& ruby_spans =\s*'
              r'std::vector<RubySpan>\(\)')
          .hasMatch(header),
      isTrue,
      reason: 'UpdateText 的注音参数必须有空缺省值，旧调用点（歌词条）零改动',
    );
  });
}
