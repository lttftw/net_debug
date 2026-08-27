// 临时诊断测试：逐章节渲染 MarkdownBody，定位触发
// flutter_markdown '_inlines.isEmpty' 断言的章节。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

final headingRe = RegExp(r'^ {0,3}(#{1,4})\s+(.*)$');

class _FakePreBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    return Text(text.text, style: preferredStyle);
  }

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    return Text(element.textContent);
  }
}

void main() {
  testWidgets('各章节独立渲染不抛 _inlines 断言（懒加载回归）', (tester) async {
    // 完整版本地可选，缺失时回退公开版示范文档
    final full = File('assets/docs/TCP_JSON_PROTOCOL.full.md');
    final file = full.existsSync()
        ? full
        : File('assets/docs/TCP_JSON_PROTOCOL.md');
    final raw = file
        .readAsStringSync()
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');

    final sections = <String>[];
    final buf = <String>[];
    var inFence = false;
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        buf.add(line);
        continue;
      }
      final m = inFence ? null : headingRe.firstMatch(line);
      if (m != null) {
        if (buf.isNotEmpty) sections.add(buf.join('\n'));
        buf.clear();
      }
      buf.add(line);
    }
    if (buf.isNotEmpty) sections.add(buf.join('\n'));

    final failures = <int>[];
    for (var i = 0; i < sections.length; i++) {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarkdownBody(
            data: sections[i],
            selectable: true,
            builders: {'pre': _FakePreBuilder()},
          ),
        ),
      ));
      await tester.pump();
      final e = tester.takeException();
      // 布局溢出是固定测试窗口的渲染警告（真实页面可滚动），不算失败
      final isOverflow = e is FlutterError &&
          e.diagnostics.any((d) => d.toString().contains('overflowed'));
      if (e != null && !isOverflow) {
        failures.add(i);
        final first = sections[i].split('\n').first;
        // ignore: avoid_print
        print('失败章节 $i: $first\n  异常: $e');
      }
    }
    expect(failures, isEmpty, reason: '共 ${failures.length} 个章节渲染失败');
  });
}
