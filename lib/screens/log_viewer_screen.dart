import 'package:flutter/material.dart';

import '../services/global_log_service.dart';

/// 全局日志查看页：统一展示来自各模块的日志，支持筛选与搜索
class LogViewerScreen extends StatefulWidget {
  final GlobalLogService service;

  const LogViewerScreen({super.key, required this.service});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen> {
  final _searchCtrl = TextEditingController();
  String _searchQuery = '';
  Set<GlobalLogSource> _enabledSources = GlobalLogSource.values.toSet();
  bool _autoScroll = true;
  final _scrollCtrl = ScrollController();

  GlobalLogService get _service => widget.service;

  /// 各来源筛选 chip 显示名
  static const _sourceLabels = {
    GlobalLogSource.tcp: 'TCP',
    GlobalLogSource.mqtt: 'MQTT',
    GlobalLogSource.broker: 'Broker',
    GlobalLogSource.modbus: 'Modbus',
    GlobalLogSource.app: '应用',
  };

  bool get _allSelected =>
      _enabledSources.length == GlobalLogSource.values.length;

  /// 无筛选且无搜索：直接懒加载全部日志，不做全量过滤
  bool get _noFilter => _allSelected && _searchQuery.isEmpty;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 构建与当前筛选/搜索匹配的日志索引（仅筛选/搜索生效时调用）。
  /// 只存索引不复制条目，避免大日志量时的内存与时间开销。
  List<int> _buildIndices(List<GlobalLogEntry> logs) {
    final useSources = !_allSelected;
    final q = _searchQuery.toLowerCase();
    final queryEmpty = _searchQuery.isEmpty;
    final indices = <int>[];
    for (var i = 0; i < logs.length; i++) {
      final e = logs[i];
      if (useSources && !_enabledSources.contains(e.source)) continue;
      if (!queryEmpty && !e.message.toLowerCase().contains(q)) continue;
      indices.add(i);
    }
    return indices;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('系统日志'),
        actions: [
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.vertical_align_center,
            ),
            tooltip: _autoScroll ? '自动滚动：开' : '自动滚动：关',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: () {
              _service.clear();
              setState(() {});
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildFilterBar(),
          const Divider(height: 1),
          Expanded(
            child: ListenableBuilder(
              listenable: _service,
              builder: (context, _) {
                final logs = _service.logs;
                if (logs.isEmpty) {
                  return Center(
                    child: Text(
                      '暂无日志',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                // 无筛选/搜索：直接懒加载原始列表（不复制、不过滤）；
                // 有筛选/搜索：按需构建匹配索引，逐项懒渲染
                final filtered = !_noFilter;
                final List<int> indices;
                if (filtered) {
                  indices = _buildIndices(logs);
                  if (indices.isEmpty) {
                    return Center(
                      child: Text(
                        '没有匹配的日志',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    );
                  }
                } else {
                  indices = const [];
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_autoScroll && _scrollCtrl.hasClients) {
                    _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                  }
                });
                return ListView.builder(
                  controller: _scrollCtrl,
                  itemCount: filtered ? indices.length : logs.length,
                  itemBuilder: (context, index) => _buildLogEntry(
                    filtered ? logs[indices[index]] : logs[index],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 36,
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: '搜索日志内容…',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 16),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
              ),
              onChanged: (v) => setState(() => _searchQuery = v),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              for (final s in GlobalLogSource.values)
                _filterChip(_sourceLabels[s]!, s),
              TextButton(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () {
                  setState(() {
                    if (_allSelected) {
                      _enabledSources = {_enabledSources.first};
                    } else {
                      _enabledSources = GlobalLogSource.values.toSet();
                    }
                  });
                },
                child: Text(
                  _allSelected ? '全部' : '多选',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, GlobalLogSource source) {
    final selected = _enabledSources.contains(source);
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: selected,
      onSelected: (v) {
        setState(() {
          if (v) {
            _enabledSources.add(source);
          } else {
            _enabledSources.remove(source);
          }
        });
      },
      visualDensity: VisualDensity.compact,
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }

  Widget _buildLogEntry(GlobalLogEntry entry) {
    final color = _colorForKind(entry.source, entry.kind);
    final timeStr =
        '${entry.time.hour.toString().padLeft(2, '0')}:'
        '${entry.time.minute.toString().padLeft(2, '0')}:'
        '${entry.time.second.toString().padLeft(2, '0')}'
        '.${entry.time.millisecond.toString().padLeft(3, '0')}';
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            timeStr,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              entry.sourceLabel,
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              entry.message,
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: _isError(entry.kind)
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Color _colorForKind(GlobalLogSource source, String kind) {
    if (kind == 'error') return Colors.red;
    if (kind == 'tx') return Colors.green;
    if (kind == 'rx') return Colors.blue;
    switch (source) {
      case GlobalLogSource.tcp:
        return Colors.indigo;
      case GlobalLogSource.mqtt:
        return Colors.teal;
      case GlobalLogSource.broker:
        return Colors.orange;
      case GlobalLogSource.modbus:
        return Colors.brown;
      case GlobalLogSource.app:
        return Colors.grey;
    }
  }

  bool _isError(String kind) => kind == 'error';
}