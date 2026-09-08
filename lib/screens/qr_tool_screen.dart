import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zxing2/qrcode.dart';

import '../widgets/app_toast.dart';
import 'qr_scan_screen.dart';

/// 二级页：文本与二维码互转工具。
///
/// - 生成：qr_flutter（qr 包）按输入文本实时生成二维码，可保存为 PNG；
/// - 识别：两种入口。
///   1. 扫一扫（仅 Android）：mobile_scanner 调起摄像头实时识别；
///   2. 图片识别：file_picker 选图 → image 包解码 → zxing2 定位并解码二维码，
///      解码在后台 isolate 执行避免卡顿。
class QrToolScreen extends StatefulWidget {
  const QrToolScreen({super.key});

  @override
  State<QrToolScreen> createState() => _QrToolScreenState();
}

enum _ToolMode { encode, decode }

class _QrToolScreenState extends State<QrToolScreen> {
  static const _errorCorrectionLevel = QrErrorCorrectLevel.M;

  final TextEditingController _controller = TextEditingController();
  _ToolMode _mode = _ToolMode.encode;

  String _qrData = '';
  String _encodeMessage = '';
  bool _encodeOk = false;
  Timer? _debounce;

  bool _decoding = false;
  String? _decodeResult;
  String _decodeMessage = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  // ---------- 生成 ----------

  void _onTextChanged(String _) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), _generateLive);
  }

  void _generateLive() {
    if (!mounted) return;
    final text = _controller.text;
    if (text.trim().isEmpty) {
      setState(() {
        _qrData = '';
        _encodeMessage = '';
      });
      return;
    }
    final valid = QrValidator.validate(
      data: text,
      version: QrVersions.auto,
      errorCorrectionLevel: _errorCorrectionLevel,
    ).isValid;
    setState(() {
      _qrData = valid ? text : '';
    });
  }

  void _generate() {
    final text = _controller.text;
    if (text.trim().isEmpty) {
      setState(() {
        _qrData = '';
        _encodeMessage = '请输入文本';
        _encodeOk = false;
      });
      return;
    }
    final result = QrValidator.validate(
      data: text,
      version: QrVersions.auto,
      errorCorrectionLevel: _errorCorrectionLevel,
    );
    setState(() {
      if (result.isValid) {
        _qrData = text;
        _encodeMessage = '已生成二维码';
        _encodeOk = true;
      } else {
        _qrData = '';
        _encodeMessage = result.status == QrValidationStatus.contentTooLong
            ? '文本过长，超出二维码容量上限'
            : '生成失败：${result.error}';
        _encodeOk = false;
      }
    });
  }

  Future<void> _saveQr() async {
    if (_qrData.isEmpty) return;
    const size = 512.0;
    final painter = QrPainter(
      data: _qrData,
      version: QrVersions.auto,
      errorCorrectionLevel: _errorCorrectionLevel,
      gapless: true,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Colors.black,
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Colors.black,
      ),
    );
    final picture = painter.toPicture(size);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, size, size),
      Paint()..color = Colors.white,
    );
    canvas.drawPicture(picture);
    final image = await recorder.endRecording().toImage(size.toInt(), size.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (byteData == null) return;

    final uri = await FilePicker.saveFile(
      dialogTitle: '保存二维码图片',
      fileName: 'qrcode.png',
      mimeType: 'image/png',
      type: FileType.image,
      allowedExtensions: const ['png'],
      bytes: byteData.buffer.asUint8List(),
    );
    if (uri != null && mounted) {
      _showSnack('已保存二维码图片');
    }
  }

  // ---------- 识别 ----------

  /// 摄像头扫码仅 Android 提供（mobile_scanner 无 Windows 实现）
  bool get _canScanCamera => !kIsWeb && Platform.isAndroid;

  Future<void> _scanCamera() async {
    final result = await Navigator.push<String>(
      context,
      MaterialPageRoute(builder: (_) => const QrScanScreen()),
    );
    if (!mounted || result == null || result.isEmpty) return;
    setState(() {
      _decoding = false;
      _decodeResult = result;
      _decodeMessage = '识别成功';
    });
  }

  Future<void> _pickAndDecode() async {
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: '选择二维码图片',
        type: FileType.image,
      );
      if (file == null || !mounted) return;
      setState(() {
        _decoding = true;
        _decodeResult = null;
        _decodeMessage = '正在识别…';
      });
      final bytes = await file.readAsBytes();
      final result = await compute(_decodeQrBytes, bytes);
      if (!mounted) return;
      setState(() {
        _decoding = false;
        if (result != null && result.isNotEmpty) {
          _decodeResult = result;
          _decodeMessage = '识别成功';
        } else {
          _decodeMessage = '未识别到二维码，请尝试更清晰的图片';
        }
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _decoding = false;
        _decodeMessage = '读取图片失败';
      });
    }
  }

  void _copyResult() {
    final text = _decodeResult;
    if (text == null || text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    _showSnack('已复制到剪贴板');
  }

  void _showSnack(String message) {
    showAppToast(context, message);
  }

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('文本与二维码互转')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              Center(
                child: SegmentedButton<_ToolMode>(
                  segments: const [
                    ButtonSegment(
                      value: _ToolMode.encode,
                      label: Text('生成二维码'),
                      icon: Icon(Icons.qr_code_2),
                    ),
                    ButtonSegment(
                      value: _ToolMode.decode,
                      label: Text('识别二维码'),
                      icon: Icon(Icons.document_scanner_outlined),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) => setState(() => _mode = s.first),
                ),
              ),
              const SizedBox(height: 12),
              if (_mode == _ToolMode.encode) ..._buildEncode(),
              if (_mode == _ToolMode.decode) ..._buildDecode(),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _buildEncode() {
    final theme = Theme.of(context);
    return [
      Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                maxLines: 6,
                minLines: 3,
                onChanged: _onTextChanged,
                decoration: const InputDecoration(
                  hintText: '输入要编码的文本…',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _generate,
                    icon: const Icon(Icons.qr_code),
                    label: const Text('生成二维码'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _encodeMessage,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: _encodeOk
                            ? theme.colorScheme.primary
                            : theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _qrData.isEmpty
                    ? SizedBox(
                        height: 220,
                        child: Center(
                          child: Text(
                            '二维码将显示在这里',
                            style: TextStyle(color: Colors.grey.shade600),
                          ),
                        ),
                      )
                    : QrImageView(
                        data: _qrData,
                        version: QrVersions.auto,
                        errorCorrectionLevel: _errorCorrectionLevel,
                        size: 220,
                        gapless: true,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                        errorStateBuilder: (c, error) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(
                              '文本过长，无法生成',
                              style: TextStyle(color: Colors.grey.shade700),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _qrData.isEmpty ? null : _saveQr,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('保存为图片'),
                ),
              ),
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildDecode() {
    final theme = Theme.of(context);
    return [
      Card(
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_canScanCamera) ...[
                FilledButton.icon(
                  onPressed: _scanCamera,
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫一扫'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _decoding ? null : _pickAndDecode,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('选择图片'),
                ),
              ] else
                FilledButton.icon(
                  onPressed: _decoding ? null : _pickAndDecode,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('选择图片'),
                ),
              const SizedBox(height: 8),
              Text(
                '支持调起摄像头实时识别，或选择包含二维码的截图 / 照片（PNG、JPG 等）',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_decoding) ...[
                const SizedBox(height: 12),
                const Center(child: CircularProgressIndicator()),
              ] else if (_decodeMessage.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _decodeMessage,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _decodeResult != null
                        ? theme.colorScheme.primary
                        : theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      if (_decodeResult != null && _decodeResult!.isNotEmpty) ...[
        const SizedBox(height: 12),
        Card(
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '识别结果',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    IconButton(
                      tooltip: '复制结果',
                      onPressed: _copyResult,
                      icon: const Icon(Icons.copy, size: 20),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    _decodeResult!,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    ];
  }
}

/// 后台 isolate：解码图片中的二维码，返回文本；识别失败返回 null。
String? _decodeQrBytes(Uint8List bytes) {
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
    // 常规 + 反色各尝试一次（兼容深色底/反色二维码）
    final bitmaps = <BinaryBitmap>[
      BinaryBitmap(HybridBinarizer(source)),
      BinaryBitmap(HybridBinarizer(InvertedLuminanceSource(source))),
    ];
    for (final bitmap in bitmaps) {
      try {
        final text = _cleanDecodeText(reader.decode(bitmap));
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

/// zxing2 对无 ECI 头的 UTF-8 字节流可能按 ISO-8859-1 猜测导致中文乱码。
/// 这里优先取 byteSegments 原始字节并按 UTF-8 严格解码；失败则沿用猜测文本。
String _cleanDecodeText(Result result) {
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