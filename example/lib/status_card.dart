import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

/// A rounded, softly shadowed group, as in iOS settings.
class Panel extends StatelessWidget {
  const Panel({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          if (light)
            const BoxShadow(
              color: Color(0x0F000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
        ],
      ),
      child: child,
    );
  }
}

/// What this cold start runs. A patched start is recorded at its first frame,
/// so the card shows a loading state until then. Applying or rolling back
/// changes the installed patch at once and what runs after a restart.
class StatusCard extends StatefulWidget {
  const StatusCard({required this.refresh, super.key});

  /// Changes after each update or rollback, to read the installed patch again.
  final int refresh;

  @override
  State<StatusCard> createState() => _StatusCardState();
}

class _StatusCardState extends State<StatusCard> {
  PatchBootDiagnostic? _boot;
  List<(String, String)>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(StatusCard old) {
    super.didUpdateWidget(old);
    if (old.refresh != widget.refresh) _load();
  }

  Future<void> _load() async {
    final boot = await FlutterPatcher.lastBootDiagnostic;
    final rows = [
      ('Installed patch', await FlutterPatcher.currentVersion ?? 'none'),
      ('versionCode', '${await FlutterPatcher.appVersionCode ?? '-'}'),
      ('ABI', await FlutterPatcher.deviceAbi),
      if (boot?.message case final message? when message.isNotEmpty)
        ('Detail', message),
    ];
    if (!mounted) return;
    setState(() {
      _boot = boot;
      _rows = rows;
    });
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final (color, icon, title) = switch (_boot?.status) {
      null => (Colors.grey, Icons.hourglass_empty, 'No cold start recorded'),
      PatchBootStatus.patched => (
        dark ? const Color(0xFF30D158) : const Color(0xFF34C759),
        Icons.check_circle,
        'Running patch ${_boot!.patchVersion ?? ''}',
      ),
      PatchBootStatus.noPatch => (
        Colors.grey,
        Icons.circle_outlined,
        'Running the installed version',
      ),
      PatchBootStatus.droppedCircuitBreaker => (
        dark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30),
        Icons.error,
        'Patch rolled back after a crash',
      ),
      final status => (
        dark ? const Color(0xFFFF9F0A) : const Color(0xFFFF9500),
        Icons.warning_rounded,
        status.name,
      ),
    };
    final text = Theme.of(context).textTheme;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final rows = _rows;
    return Panel(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: rows == null
            ? Row(
                key: const ValueKey('loading'),
                children: [
                  const SizedBox.square(
                    dimension: 36,
                    child: Padding(
                      padding: EdgeInsets.all(8),
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Checking this start…',
                    style: text.titleMedium?.copyWith(color: secondary),
                  ),
                ],
              )
            : Column(
                key: const ValueKey('status'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: color.withValues(alpha: 0.15),
                        child: Icon(icon, color: color, size: 22),
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: Text(title, style: text.titleMedium)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  for (final (label, value) in rows)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Text(label, style: text.bodyMedium),
                          const Spacer(),
                          Text(
                            value,
                            style: text.bodyMedium?.copyWith(color: secondary),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
