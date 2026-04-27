import 'package:flutter/material.dart';

/// 极简日志累积 + 可滚动面板 —— 只给 example 用。
///
/// 用法：
/// ```dart
/// final log = LogController();
/// log.log('hello');
/// Expanded(child: LogPanel(controller: log));
/// ```
class LogController extends ChangeNotifier {
  final List<String> _lines = [];
  List<String> get lines => List.unmodifiable(_lines);

  /// 追加到末尾：界面从上往下按时间顺序显示，第一条在顶，最新一条在底。
  void log(String msg) {
    _lines.add(msg);
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}

class LogPanel extends StatefulWidget {
  const LogPanel({required this.controller, super.key});
  final LogController controller;

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrollToBottom);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_scrollToBottom);
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// 日志超出可视区时自动滚到底部，保证最新一条可见。
  /// addPostFrameCallback 等到 ListView 把新 item 布局完再滚。
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(
        _scrollCtrl.position.maxScrollExtent,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (_, _) {
        final lines = widget.controller.lines;
        return Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.grey.shade400),
            borderRadius: BorderRadius.circular(4),
          ),
          child: lines.isEmpty
              ? const Center(
                  child: Text(
                    '(logs will appear here)',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                )
              : ListView.builder(
                  controller: _scrollCtrl,
                  itemCount: lines.length,
                  itemBuilder: (context, i) => Text(
                    lines[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
        );
      },
    );
  }
}
