import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// 全屏扫码页：调起摄像头连续识别二维码，识别到一条结果后立即返回。
///
/// 仅在支持的平台（Android）上打开；权限拒绝或相机异常时在页面内给出提示。
class QrScanScreen extends StatefulWidget {
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController();
  bool _torchOn = false;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || !mounted) return;
    for (final barcode in capture.barcodes) {
      final text = _decodeBarcodeText(barcode);
      if (text == null || text.isEmpty) continue;
      _done = true;
      Navigator.pop(context, text);
      return;
    }
  }

  /// 优先取 rawValue；字节型条码（无文本表示）按 UTF-8 解码原始字节。
  String? _decodeBarcodeText(Barcode barcode) {
    final raw = barcode.rawValue;
    if (raw != null && raw.isNotEmpty) return raw;
    final bytes = switch (barcode.rawDecodedBytes) {
      DecodedBarcodeBytes(:final bytes) => bytes,
      DecodedVisionBarcodeBytes(:final bytes) => bytes,
      _ => null,
    };
    if (bytes == null || bytes.isEmpty) return null;
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return null;
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (_) {
      // 部分设备无闪光灯，忽略
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: const Text('扫描二维码'),
        actions: [
          IconButton(
            tooltip: _torchOn ? '关闭手电筒' : '打开手电筒',
            icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
            onPressed: _toggleTorch,
          ),
        ],
      ),
      body: Stack(
        alignment: Alignment.center,
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _buildError(context, error),
          ),
          // 视觉取景框：仅提示对准区域，识别范围为整个画面
          IgnorePointer(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            bottom: 48,
            left: 24,
            right: 24,
            child: Text(
              '对准二维码即可自动识别',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError(BuildContext context, MobileScannerException error) {
    final denied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              denied ? Icons.no_photography_outlined : Icons.videocam_off_outlined,
              size: 40,
              color: Colors.white54,
            ),
            const SizedBox(height: 12),
            Text(
              denied ? '未授予相机权限' : '无法启动相机',
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
            const SizedBox(height: 6),
            Text(
              denied
                  ? '请在系统设置中允许本应用使用相机后重试'
                  : '设备可能没有可用摄像头，可改用图片识别',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }
}
