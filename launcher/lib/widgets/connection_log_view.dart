import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../services/connection_log.dart';
import 'lulu_ui.dart';

class ConnectionLogView extends StatefulWidget {
  const ConnectionLogView({super.key});

  @override
  State<ConnectionLogView> createState() => _ConnectionLogViewState();
}

class _ConnectionLogViewState extends State<ConnectionLogView> {
  late Future<List<ConnectionEntry>> _entries;
  String? _date;

  @override
  void initState() {
    super.initState();
    _entries = ConnectionLog.instance.read();
  }

  Future<void> _export(List<ConnectionEntry> rows) async {
    try {
      final location = await getSaveLocation(
        suggestedName:
            'QG-remote-${_date ?? connectionDay(DateTime.now())}.txt',
        acceptedTypeGroups: const [
          XTypeGroup(label: '文本文档', extensions: ['txt'])
        ],
      );
      if (location == null) return;
      final bytes =
          Uint8List.fromList(utf8.encode(ConnectionLog.exportText(rows)));
      await XFile.fromData(bytes, mimeType: 'text/plain').saveTo(location.path);
      if (mounted) showLuluSnack(context, '已导出连接记录。');
    } on Exception {
      if (mounted) showLuluSnack(context, '无法导出连接记录。');
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('连接记录'), actions: [
          IconButton(
            tooltip: '刷新连接记录',
            icon: const Icon(Icons.refresh),
            onPressed: () =>
                setState(() => _entries = ConnectionLog.instance.read()),
          ),
        ]),
        body: FutureBuilder<List<ConnectionEntry>>(
          future: _entries,
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Center(child: Text('无法读取连接记录。'));
            }
            final all = snapshot.data;
            if (all == null) {
              return const Center(child: CircularProgressIndicator());
            }
            if (all.isEmpty) return const Center(child: Text('暂无连接记录。'));
            final dates = all
                .map((entry) => connectionDay(entry.start))
                .toSet()
                .toList()
              ..sort((left, right) => right.compareTo(left));
            final selected = dates.contains(_date) ? _date : null;
            final rows = selected == null
                ? all.take(30).toList()
                : all
                    .where((entry) => connectionDay(entry.start) == selected)
                    .toList();
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Wrap(
                    spacing: 16,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      DropdownButton<String>(
                        value: selected ?? '',
                        items: [
                          const DropdownMenuItem(
                              value: '', child: Text('最近 30 条')),
                          for (final date in dates)
                            DropdownMenuItem(value: date, child: Text(date)),
                        ],
                        onChanged: (value) =>
                            setState(() => _date = value == '' ? null : value),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _export(rows),
                        icon: const Icon(Icons.download_outlined),
                        label: const Text('导出文本'),
                      ),
                    ]),
                for (final row in rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('${row.kindLabel} · ${row.clientLabel}'),
                    subtitle: Text([
                      '${connectionTime(row.start)} 至 ${connectionTime(row.end)}',
                      if (row.issue case final issue?) issue.label,
                    ].join('\n')),
                    isThreeLine: row.issue != null,
                    trailing: Text(
                        '${row.duration.inSeconds} 秒 · ${row.outcomeLabel}'),
                  ),
              ],
            );
          },
        ),
      );
}
