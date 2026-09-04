import 'dart:convert';

/// Modbus 标准功能码（调试工具作为主站使用）。
enum ModbusFunction {
  readCoils(1, '读线圈', '01'),
  readDiscreteInputs(2, '读离散输入', '02'),
  readHoldingRegisters(3, '读保持寄存器', '03'),
  readInputRegisters(4, '读输入寄存器', '04'),
  writeSingleCoil(5, '写单线圈', '05'),
  writeSingleRegister(6, '写单寄存器', '06'),
  writeMultipleCoils(15, '写多线圈', '0F'),
  writeMultipleRegisters(16, '写多寄存器', '10');

  const ModbusFunction(this.code, this.label, this.hex);

  final int code;
  final String label;
  final String hex;

  bool get isRead =>
      this == readCoils ||
      this == readDiscreteInputs ||
      this == readHoldingRegisters ||
      this == readInputRegisters;

  bool get isCoil => this == readCoils || this == writeSingleCoil || this == writeMultipleCoils;

  bool get isRegister =>
      this == readHoldingRegisters ||
      this == readInputRegisters ||
      this == writeSingleRegister ||
      this == writeMultipleRegisters;

  static ModbusFunction? fromCode(int code) {
    for (final f in values) {
      if (f.code == code) return f;
    }
    return null;
  }
}

/// 一条 Modbus 指令：对应表单字段，也可序列化成快捷指令预设的 `command`。
///
/// 紧凑 JSON 约定（功能码用数字）：
///   {"fc":3,"addr":0,"count":1}
///   {"fc":4,"addr":16,"count":8,"as":"u32"}
///   {"fc":5,"addr":0,"value":true}
///   {"fc":6,"addr":0,"value":33}
///   {"fc":15,"addr":0,"values":[true,false]}
///   {"fc":16,"addr":16,"values":[0,100]}
///   （可选 "unit":1 覆盖从站地址）
class ModbusCommand {
  final ModbusFunction function;

  /// 零基起始地址（协议 PDU 地址）
  final int address;

  /// 读数量（读类）；写多类为值的数量（由 value 列表长度决定，可省略）
  final int? count;

  /// 从站地址（MBAP Unit Identifier），默认 1
  final int unit;

  /// 写单线圈值
  final bool? coilValue;

  /// 写单寄存器值
  final int? registerValue;

  /// 写多线圈值序列
  final List<bool>? coilValues;

  /// 写多寄存器值序列
  final List<int>? registerValues;

  /// 响应解析方式：null/'u16' 按 16 位十进制数组；'u32' 按高字在前合并
  final String? asType;

  const ModbusCommand({
    required this.function,
    required this.address,
    this.count,
    this.unit = 1,
    this.coilValue,
    this.registerValue,
    this.coilValues,
    this.registerValues,
    this.asType,
  });

  /// 该指令实际涉及的值数量（写多类）。
  int get valueCount {
    if (coilValues != null) return coilValues!.length;
    if (registerValues != null) return registerValues!.length;
    if (count != null) return count!;
    return 1;
  }

  factory ModbusCommand.fromJson(Map<String, dynamic> json) {
    final fc = (json['fc'] as num?)?.toInt() ?? 0;
    final function = ModbusFunction.fromCode(fc) ?? ModbusFunction.readHoldingRegisters;
    final addr = (json['addr'] as num?)?.toInt() ?? 0;
    final unit = (json['unit'] as num?)?.toInt() ?? 1;
    final asType = json['as'] as String?;

    final count = (json['count'] as num?)?.toInt();
    final value = json['value'];
    final values = json['values'];

    bool? coilValue;
    int? registerValue;
    List<bool>? coilValues;
    List<int>? registerValues;

    if (function == ModbusFunction.writeSingleCoil) {
      coilValue = value == true;
    } else if (function == ModbusFunction.writeSingleRegister) {
      registerValue = (value as num?)?.toInt() ?? 0;
    } else if (function == ModbusFunction.writeMultipleCoils) {
      coilValues = [
        for (final v in (values as List? ?? [])) v == true || v == 1,
      ];
    } else if (function == ModbusFunction.writeMultipleRegisters) {
      registerValues = [
        for (final v in (values as List? ?? [])) (v as num).toInt(),
      ];
    }

    return ModbusCommand(
      function: function,
      address: addr,
      count: count,
      unit: unit,
      coilValue: coilValue,
      registerValue: registerValue,
      coilValues: coilValues,
      registerValues: registerValues,
      asType: asType,
    );
  }

  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'fc': function.code,
      'addr': address,
    };
    if (unit != 1) m['unit'] = unit;
    if (function.isRead) {
      if (count != null) m['count'] = count;
    } else if (function == ModbusFunction.writeSingleCoil) {
      m['value'] = coilValue == true;
    } else if (function == ModbusFunction.writeSingleRegister) {
      m['value'] = registerValue ?? 0;
    } else if (function == ModbusFunction.writeMultipleCoils) {
      m['values'] = [for (final v in coilValues ?? <bool>[]) v];
    } else if (function == ModbusFunction.writeMultipleRegisters) {
      m['values'] = [for (final v in registerValues ?? <int>[]) v];
    }
    if (asType != null && asType!.isNotEmpty) m['as'] = asType;
    return m;
  }

  String encode() => jsonEncode(toJson());

  /// 从快捷指令预设的 command 字符串解析（容错：失败返回 null）。
  static ModbusCommand? tryParse(String raw) {
    try {
      final v = jsonDecode(raw.trim());
      if (v is! Map) return null;
      return ModbusCommand.fromJson(v.cast<String, dynamic>());
    } catch (_) {
      return null;
    }
  }

  /// 人类可读摘要（用于日志/回显）。
  String get summary {
    final a = '0x${address.toRadixString(16).toUpperCase().padLeft(4, '0')}($address)';
    switch (function) {
      case ModbusFunction.readCoils:
      case ModbusFunction.readDiscreteInputs:
      case ModbusFunction.readHoldingRegisters:
      case ModbusFunction.readInputRegisters:
        return '${function.label} 起始 $a 数量 ${count ?? 1}';
      case ModbusFunction.writeSingleCoil:
        return '写单线圈 $a = ${coilValue == true ? 'ON' : 'OFF'}';
      case ModbusFunction.writeSingleRegister:
        return '写单寄存器 $a = ${registerValue ?? 0}';
      case ModbusFunction.writeMultipleCoils:
        return '写多线圈 $a = [${(coilValues ?? []).map((v) => v ? 1 : 0).join(', ')}]';
      case ModbusFunction.writeMultipleRegisters:
        return '写多寄存器 $a = [${(registerValues ?? []).join(', ')}]';
    }
  }
}
