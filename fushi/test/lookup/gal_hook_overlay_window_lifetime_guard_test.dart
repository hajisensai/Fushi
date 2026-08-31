import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('BUG-1981 Hook 浮窗在 HWND 生命周期结束后清句柄并可重建', () {
    final String source = File(
      'windows/runner/floating_lyric_window.cpp',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');
    final String header = File(
      'windows/runner/floating_lyric_window.h',
    ).readAsStringSync().replaceAll(RegExp(r'\s+'), '');

    expect(header, contains('boolOwnsLiveWindow()const;'));
    expect(
      source,
      contains('GetWindowLongPtr(hwnd_,GWLP_USERDATA))==this;'),
      reason: 'IsWindow 单独不足以排除 HWND 被系统复用，必须核对实例 back-pointer',
    );
    expect(
      source,
      contains('if(hwnd_!=nullptr&&!OwnsLiveWindow()){hwnd_=nullptr;'),
      reason: 'Show 必须先丢弃死/被复用句柄，随后走 CreateWindowExW 重建',
    );
    expect(
      source,
      contains('if(!SetWindowPos(hwnd_,topmost_?HWND_TOPMOST:HWND_NOTOPMOST'),
      reason: '抬窗失败必须回 false，不能让 Dart 把无窗口记成已显示',
    );
    expect(
      source,
      contains('caseWM_NCDESTROY:'),
      reason: '窗口生命周期结束点必须同步清 Dart 复用对象持有的原生句柄',
    );
    expect(
      source,
      contains('SetWindowLongPtr(destroyed,GWLP_USERDATA,0);hwnd_=nullptr;'),
      reason: 'WM_NCDESTROY 必须同时撤回 back-pointer 与成员句柄',
    );
  });
}
