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
  Set<GlobalLogSource> _enabledSources = {
    GlobalLogSource.tcp,
    GlobalLogSource.mqtt,
    GlobalLogSource.broker,
    GlobalLogSource.app,
  };
  bool _autoScroll = true;
  final _scrollCtrl = ScrollController();

  GlobalLogService get _service => widget.service;

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  List<GlobalLogEntry> get _filteredLogs {
    var logs = _service.logs;
    if (_enabledSources.length < 4) {
      logs = logs.where((e) => _enabledSources.contains(e.source)).toList();
    }
    if (_searchQuery.isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      logs = logs
          .where((e) => e.message.toLowerCase().contains(q))
          .toList();
    }
    return logs;
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
                final logs = _filteredLogs;
                if (logs.isEmpty) {
                  return Center(
                    child: Text(
                      _service.logs.isEmpty ? '暂无日志' : '没有匹配的日志',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  );
                }
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_autoScroll && _scrollCtrl.hasClients) {
                    _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
                  }
                });
                return ListView.builder(
                  controller: _scrollCtrl,
                  itemCount: logs.length,
                  itemBuilder: (context, index) {
                    final entry = logs[index];
                    return _buildLogEntry(entry);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    final all = _enabledSources.length == 4;
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
          Row(
            children: [
              _filterChip('TCP', GlobalLogSource.tcp),
              const SizedBox(width: 6),
              _filterChip('MQTT', GlobalLogSource.mqtt),
              const SizedBox(width: 6),
              _filterChip('Broker', GlobalLogSource.broker),
              const SizedBox(width: 6),
              _filterChip('应用', GlobalLogSource.app),
              const Spacer(),
              SizedBox(
                height: 28,
                child: TextButton(
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: Size.zero,
                  ),
                  onPressed: () {
                    setState(() {
                      if (all) {
                        _enabledSources = {_enabledSources.first};
                      } else {
                        _enabledSources = {
                          GlobalLogSource.tcp,
                          GlobalLogSource.mqtt,
                          GlobalLogSource.broker,
                          GlobalLogSource.app,
                        };
                      }
                    });
                  },
                  child: Text(all ? '全部' : '多选', style: const TextStyle(fontSize: 12)),
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
      case GlobalLogSource.app:
        return Colors.grey;
    }
  }

  bool _isError(String kind) => kind == 'error';
}