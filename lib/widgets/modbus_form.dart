import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/modbus_command.dart';
import 'app_toast.dart';

/// Modbus 指令表单构造器：功能码下拉 + 动态字段，发送时构造 [ModbusCommand]。
///
/// 通过 `GlobalKey<ModbusFormState>` 调用 [ModbusFormState.setCommand] 回填
/// （快捷指令点选后填充表单）；[onSend] 收到构造好的指令后由页面负责发送。
class ModbusForm extends StatefulWidget {
  final Future<bool> Function(ModbusCommand cmd) onSend;
  final bool sending;

  const ModbusForm({
    super.key,
    required this.onSend,
    this.sending = false,
  });

  @override
  State<ModbusForm> createState() => ModbusFormState();
}

class ModbusFormState extends State<ModbusForm> {
  ModbusFunction _function = ModbusFunction.readHoldingRegisters;
  final TextEditingController _unitCtrl = TextEditingController(text: '1');
  final TextEditingController _addrCtrl = TextEditingController();
  final TextEditingController _countCtrl = TextEditingController();
  final TextEditingController _valueCtrl = TextEditingController();
  final TextEditingController _valuesCtrl = TextEditingController();
  bool _coilValue = true;
  bool _asU32 = false;

  @override
  void dispose() {
    _unitCtrl.dispose();
    _addrCtrl.dispose();
    _countCtrl.dispose();
    _valueCtrl.dispose();
    _valuesCtrl.dispose();
    super.dispose();
  }

  /// 回填一条指令（快捷指令点选后调用）。
  void setCommand(ModbusCommand cmd) {
    setState(() {
      _function = cmd.function;
      _unitCtrl.text = '${cmd.unit}';
      _addrCtrl.text = cmd.address == 0 ? '0' : '${cmd.address}';
      _countCtrl.text = cmd.count != null ? '${cmd.count}' : '';
      _asU32 = cmd.asType == 'u32';
      if (cmd.function == ModbusFunction.writeSingleCoil) {
        _coilValue = cmd.coilValue == true;
      } else if (cmd.function == ModbusFunction.writeSingleRegister) {
        _valueCtrl.text = '${cmd.registerValue ?? 0}';
      } else if (cmd.function == ModbusFunction.writeMultipleCoils) {
        _valuesCtrl.text = (cmd.coilValues ?? [])
            .map((v) => v ? '1' : '0')
            .join(',');
      } else if (cmd.function == ModbusFunction.writeMultipleRegisters) {
        _valuesCtrl.text = (cmd.registerValues ?? []).join(',');
      } else {
        _valueCtrl.clear();
        _valuesCtrl.clear();
      }
    });
  }

  int? _parseInt(String text, {required String label, int min = 0, int max = 65535}) {
    final v = int.tryParse(text.trim());
    if (v == null || v < min || v > max) {
      showAppToast(context, '$label 需为 $min–$max 的整数');
      return null;
    }
    return v;
  }

  /// 校验并构造指令；非法时返回 null（已 toast 提示）。
  ModbusCommand? buildCommand() {
    final unit = _parseInt(_unitCtrl.text, label: '从站地址', min: 0, max: 247) ?? 1;
    final addr = _parseInt(_addrCtrl.text, label: '起始地址', max: 0xFFFF);
    if (addr == null) return null;

    switch (_function) {
      case ModbusFunction.readCoils:
      case ModbusFunction.readDiscreteInputs:
      case ModbusFunction.readHoldingRegisters:
      case ModbusFunction.readInputRegisters:
        final count = _parseInt(_countCtrl.text, label: '数量', min: 1, max: 125);
        if (count == null) return null;
        return ModbusCommand(
          function: _function,
          address: addr,
          count: count,
          unit: unit,
          asType: _function.isRegister && _asU32 ? 'u32' : null,
        );
      case ModbusFunction.writeSingleCoil:
        return ModbusCommand(
          function: _function,
          address: addr,
          unit: unit,
          coilValue: _coilValue,
        );
      case ModbusFunction.writeSingleRegister:
        final v = _parseInt(_valueCtrl.text, label: '寄存器值');
        if (v == null) return null;
        return ModbusCommand(
          function: _function,
          address: addr,
          unit: unit,
          registerValue: v,
        );
      case ModbusFunction.writeMultipleCoils:
        final values = _parseCoilList(_valuesCtrl.text);
        if (values == null) return null;
        return ModbusCommand(
          function: _function,
          address: addr,
          unit: unit,
          coilValues: values,
        );
      case ModbusFunction.writeMultipleRegisters:
        final values = _parseRegisterList(_valuesCtrl.text);
        if (values == null) return null;
        return ModbusCommand(
          function: _function,
          address: addr,
          unit: unit,
          registerValues: values,
        );
    }
  }

  List<bool>? _parseCoilList(String text) {
    final parts = text.split(RegExp(r'[,，\s]+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) {
      showAppToast(context, '请输入线圈值序列（如 1,0,1）');
      return null;
    }
    final out = <bool>[];
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null || (v != 0 && v != 1)) {
        showAppToast(context, '线圈值只能为 0 或 1');
        return null;
      }
      out.add(v == 1);
    }
    return out;
  }

  List<int>? _parseRegisterList(String text) {
    final parts = text.split(RegExp(r'[,，\s]+')).where((s) => s.isNotEmpty).toList();
    if (parts.isEmpty) {
      showAppToast(context, '请输入寄存器值序列（如 0,100）');
      return null;
    }
    final out = <int>[];
    for (final p in parts) {
      final v = int.tryParse(p.trim());
      if (v == null || v < 0 || v > 65535) {
        showAppToast(context, '寄存器值需为 0–65535 的整数');
        return null;
      }
      out.add(v);
    }
    return out;
  }

  Future<void> _send() async {
    final cmd = buildCommand();
    if (cmd == null) return;
    await widget.onSend(cmd);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildFieldPair([
          _buildDropdown(),
          _numberField(_unitCtrl, '从站地址', hint: '默认 1'),
        ]),
        const SizedBox(height: 10),
        _buildFieldPair([
          _numberField(_addrCtrl, '起始地址（零基）', hint: '0x0000'),
          if (_function.isRead)
            _numberField(_countCtrl, '数量', hint: '1–125')
          else
            _buildValueField(),
        ]),
        if (_function.isRead) ...[
          if (_function.isRegister) ...[
            const SizedBox(height: 6),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('按 uint32 解析（高字在前）'),
              value: _asU32,
              onChanged: (v) => setState(() => _asU32 = v),
            ),
          ],
        ],
        if (_function == ModbusFunction.writeMultipleCoils ||
            _function == ModbusFunction.writeMultipleRegisters) ...[
          const SizedBox(height: 10),
          _numberField(
            _valuesCtrl,
            _function == ModbusFunction.writeMultipleCoils
                ? '线圈值序列（逗号分隔）'
                : '寄存器值序列（逗号分隔）',
            hint: _function == ModbusFunction.writeMultipleCoils
                ? '1,0,1'
                : '0,100',
            maxLines: 2,
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: widget.sending ? null : _send,
          icon: widget.sending
              ? const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send, size: 18),
          label: Text(widget.sending ? '发送中' : '发送'),
        ),
      ],
    );
  }

  Widget _buildDropdown() {
    return DropdownButtonFormField<ModbusFunction>(
      initialValue: _function,
      isExpanded: true,
      decoration: _decoration('功能码'),
      items: [
        for (final f in ModbusFunction.values)
          DropdownMenuItem(
            value: f,
            child: Text(
              '${f.hex} ${f.label}',
              style: const TextStyle(fontSize: 13),
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (f) {
        if (f != null) setState(() => _function = f);
      },
    );
  }

  Widget _buildValueField() {
    if (_function == ModbusFunction.writeSingleCoil) {
      return SwitchListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        title: Text(_coilValue ? '线圈值：ON' : '线圈值：OFF'),
        value: _coilValue,
        onChanged: (v) => setState(() => _coilValue = v),
      );
    }
    return _numberField(_valueCtrl, '寄存器值', hint: '0–65535');
  }

  Widget _buildFieldPair(List<Widget> children) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: children[i]),
        ],
      ],
    );
  }

  Widget _numberField(
    TextEditingController ctrl,
    String label, {
    String? hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: ctrl,
      keyboardType: TextInputType.number,
      inputFormatters: [
        if (maxLines == 1) FilteringTextInputFormatter.allow(RegExp(r'[0-9]')),
      ],
      maxLines: maxLines,
      minLines: 1,
      style: const TextStyle(fontSize: 13),
      decoration: _decoration(label, hint: hint),
    );
  }

  InputDecoration _decoration(String label, {String? hint}) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      isDense: true,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    );
  }
}
