import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

/// 上次冷启动诊断的只读卡片 —— 把 `FlutterPatcher.lastBootDiagnostic` 的结果
/// 渲染成业务可一眼看懂的 UI，避免真机调试时一直看 logcat。
///
/// 状态视觉编码：
/// - 绿色 ✅：patched / noPatch（健康）
/// - 红色 ❌：droppedSignatureInvalid / droppedCircuitBreaker（强告警）
/// - 黄色 ⚠️：其他被丢弃 / hook 失败（一般提醒）
class DiagCard extends StatefulWidget {
  const DiagCard({super.key});

  /// 让外部代码（比如刚做完 apply / rollback）触发卡片重新拉取诊断。
  /// 注意：lastBootDiagnostic 反映的是**上次冷启动**结果，apply 当下不会变；
  /// 但卡片的 `app vc` 等字段重新读一遍也无害，且能视觉上刷一下"我点过了"。
  static void refresh() => _refreshTick.value++;

  static final ValueNotifier<int> _refreshTick = ValueNotifier(0);

  @override
  State<DiagCard> createState() => _DiagCardState();
}

class _DiagCardState extends State<DiagCard> {
  PatchBootDiagnostic? _diag;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
    DiagCard._refreshTick.addListener(_refresh);
  }

  @override
  void dispose() {
    DiagCard._refreshTick.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final diag = await FlutterPatcher.lastBootDiagnostic;
    if (!mounted) return;
    setState(() {
      _diag = diag;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (bg, fg, icon, title) = _visualFor(_diag, scheme);

    return Card(
      color: bg,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: fg, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        'Last boot',
                        style: TextStyle(
                          fontSize: 12,
                          color: fg.withValues(alpha: 0.7),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: _loading ? null : _refresh,
                        child: Icon(
                          Icons.refresh,
                          size: 16,
                          color: fg.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    title,
                    style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  ..._detailLines(_diag).map(
                    (line) => Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        line,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.85),
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static (Color, Color, IconData, String) _visualFor(
    PatchBootDiagnostic? d,
    ColorScheme scheme,
  ) {
    if (d == null) {
      return (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
        Icons.help_outline,
        'no diagnostic recorded yet',
      );
    }
    switch (d.status) {
      case PatchBootStatus.patched:
        return (
          Colors.green.shade50,
          Colors.green.shade900,
          Icons.check_circle,
          'patched${d.patchVersion != null ? " (v=${d.patchVersion})" : ""}',
        );
      case PatchBootStatus.noPatch:
        return (
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
          Icons.info_outline,
          'noPatch (built-in libapp.so)',
        );
      case PatchBootStatus.droppedSignatureInvalid:
      case PatchBootStatus.droppedCircuitBreaker:
        return (
          Colors.red.shade50,
          Colors.red.shade900,
          Icons.error,
          d.status.name,
        );
      default:
        return (
          Colors.orange.shade50,
          Colors.orange.shade900,
          Icons.warning_amber,
          d.status.name,
        );
    }
  }

  static List<String> _detailLines(PatchBootDiagnostic? d) {
    if (d == null) return const [];
    final lines = <String>[];
    // versionCode mismatch 时两个值都有意义；其他场景只有 appVersionCode，
    // 此时单独显示更直观，避免出现 "patch vc=?, app vc=1" 这种半残提示。
    if (d.patchTargetVersionCode != null && d.appVersionCode != null) {
      lines.add(
        'patch vc=${d.patchTargetVersionCode}, app vc=${d.appVersionCode}',
      );
    } else if (d.appVersionCode != null) {
      lines.add('app vc=${d.appVersionCode}');
    }
    if (d.crashCount != null) lines.add('crashCount=${d.crashCount}');
    if (d.attemptedLoaderFields != null &&
        d.attemptedLoaderFields!.isNotEmpty) {
      lines.add('triedFields=${d.attemptedLoaderFields!.join(",")}');
    }
    if (d.message != null && d.message!.isNotEmpty) {
      lines.add(d.message!);
    }
    return lines;
  }
}
