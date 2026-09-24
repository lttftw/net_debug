import 'package:debug_tools/widgets/message_log_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// 固定行高 40、可视高度 200 的消息区，便于精确验证滚动位置
  Widget host(List<String> entries) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 200,
          child: MessageLogView<String>(
            entries: entries,
            keyOf: ObjectKey.new,
            empty: const Text('空'),
            itemBuilder: (context, i, entry) =>
                SizedBox(height: 40, child: Text(entry)),
          ),
        ),
      ),
    );
  }

  testWidgets('空列表展示占位视图', (tester) async {
    await tester.pumpWidget(host(const []));
    expect(find.text('空'), findsOneWidget);
  });

  testWidgets('首次渲染直接定位到最新一条', (tester) async {
    await tester.pumpWidget(host(List.generate(20, (i) => 'msg-$i')));
    await tester.pumpAndSettle();
    expect(find.text('msg-19'), findsOneWidget);
    expect(find.text('msg-0'), findsNothing);
    // 停在底部时不显示回到底部浮标
    expect(find.text('回到底部'), findsNothing);
  });

  testWidgets('向上翻阅历史时不被新消息拉回底部，浮标提示未读并可回到底部', (tester) async {
    final entries = List.generate(20, (i) => 'msg-$i');
    await tester.pumpWidget(host(entries));
    await tester.pumpAndSettle();

    // 拖到顶部阅读历史
    await tester.drag(find.byType(ListView), const Offset(0, 700));
    await tester.pumpAndSettle();
    expect(find.text('msg-0'), findsOneWidget);
    expect(find.text('回到底部'), findsOneWidget);

    // 新消息到达：不应改变当前阅读位置
    await tester.pumpWidget(host([...entries, 'new-1']));
    await tester.pumpAndSettle();
    expect(find.text('msg-0'), findsOneWidget);
    expect(find.text('1 条新消息'), findsOneWidget);

    // 点击浮标回到底部
    await tester.tap(find.text('1 条新消息'));
    await tester.pumpAndSettle();
    expect(find.text('new-1'), findsOneWidget);
    expect(find.text('回到底部'), findsNothing);
  });

  testWidgets('copyMessages 逐行拼接并写入剪贴板', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await copyMessages(ctx, const ['a', 'b']);
    final setCall = calls.firstWhere((c) => c.method == 'Clipboard.setData');
    expect((setCall.arguments as Map)['text'], 'a\nb');

    // 走完提示动画与自动消失的定时器，避免遗留 Timer
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
