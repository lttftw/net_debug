import 'package:debug_tools/models/message_display_style.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('original style preserves message exactly', () {
    const message = ' {"value":1} ';
    expect(
      formatMessageForDisplay(message, MessageDisplayStyle.original),
      message,
    );
  });

  test('formatted JSON style indents valid JSON', () {
    expect(
      formatMessageForDisplay(
        '{"value":1,"nested":{"ok":true}}',
        MessageDisplayStyle.formattedJson,
      ),
      '{\n  "value": 1,\n  "nested": {\n    "ok": true\n  }\n}',
    );
  });

  test('formatted JSON style preserves non-JSON text', () {
    const message = 'device connected';
    expect(
      formatMessageForDisplay(message, MessageDisplayStyle.formattedJson),
      message,
    );
  });
}
