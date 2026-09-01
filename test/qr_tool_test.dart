// 二维码工具核心路径回归测试：
// qr 编码 → image 渲染 PNG → zxing2 解码，验证像素格式与解码链路一致。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:qr/qr.dart';
import 'package:zxing2/qrcode.dart';

/// 与 qr_tool_screen.dart 中 _decodeQrBytes 相同的解码管线。
String? decodeQrBytes(Uint8List bytes) {
  try {
    final image = img.decodeImage(bytes);
    if (image == null) return null;

    var w = image.width;
    var h = image.height;
    var processed = image;
    const maxSide = 1600;
    if (w > maxSide || h > maxSide) {
      final scale = maxSide / (w > h ? w : h);
      processed = img.copyResize(
        image,
        width: (w * scale).round(),
        height: (h * scale).round(),
        interpolation: img.Interpolation.average,
      );
      w = processed.width;
      h = processed.height;
    }

    final rgba = processed.getBytes(order: img.ChannelOrder.rgba);
    final pixels = Int32List(w * h);
    for (var i = 0; i < pixels.length; i++) {
      final o = i * 4;
      pixels[i] = (rgba[o] << 16) | (rgba[o + 1] << 8) | rgba[o + 2];
    }

    final source = RGBLuminanceSource(w, h, pixels);
    final reader = QRCodeReader();
    final bitmaps = <BinaryBitmap>[
      BinaryBitmap(HybridBinarizer(source)),
      BinaryBitmap(HybridBinarizer(InvertedLuminanceSource(source))),
    ];
    for (final bitmap in bitmaps) {
      try {
        final text = cleanDecodeText(reader.decode(bitmap));
        if (text.isNotEmpty) return text;
      } on ReaderException {
        // 尝试下一种
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}

String cleanDecodeText(Result result) {
  final segments = result.resultMetadata[ResultMetadataType.byteSegments];
  if (segments is List<Int8List> && segments.isNotEmpty) {
    final length = segments.fold<int>(0, (sum, seg) => sum + seg.length);
    final bytes = Uint8List(length);
    var offset = 0;
    for (final seg in segments) {
      bytes.setRange(offset, offset + seg.length, seg);
      offset += seg.length;
    }
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // 非 UTF-8 字节流，沿用 zxing 猜测的文本
    }
  }
  return result.text;
}

/// 用 qr 包生成矩阵并用 image 包渲染为 PNG（带白色静区）。
Uint8List renderQrPng(String text, {int scale = 8}) {
  final code = QrCode.fromData(
    data: text,
    errorCorrectLevel: QrErrorCorrectLevel.M,
  );
  final image = QrImage(code);
  final n = image.moduleCount;
  final quiet = 4 * scale;
  final size = n * scale + quiet * 2;

  final canvas = img.Image(width: size, height: size);
  img.fill(canvas, color: img.ColorRgb8(255, 255, 255));
  for (var row = 0; row < n; row++) {
    for (var col = 0; col < n; col++) {
      if (image.isDark(row, col)) {
        img.fillRect(
          canvas,
          x1: quiet + col * scale,
          y1: quiet + row * scale,
          x2: quiet + col * scale + scale - 1,
          y2: quiet + row * scale + scale - 1,
          color: img.ColorRgb8(0, 0, 0),
        );
      }
    }
  }
  return img.encodePng(canvas);
}

void main() {
  test('二维码生成与识别往返（含中文）', () {
    const texts = [
      'hello world',
      'http://192.168.1.100:8080/api/config',
      '传感器ID=SEN-001&温度=25.5&湿度=60%',
      '中文二维码测试：协议调试工具',
    ];
    for (final text in texts) {
      final png = renderQrPng(text);
      expect(png, isNotEmpty);
      final decoded = decodeQrBytes(png);
      expect(decoded, text, reason: '解码结果与原文不一致');
    }
  });

  test('非二维码图片返回 null', () {
    final canvas = img.Image(width: 64, height: 64);
    img.fill(canvas, color: img.ColorRgb8(128, 128, 128));
    final png = img.encodePng(canvas);
    expect(decodeQrBytes(png), isNull);
  });
}