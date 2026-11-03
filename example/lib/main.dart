import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

import 'status_card.dart';

/// Change this text or replace assets/patch_demo.png, then run
/// `dart run flutter_patcher patch android`: a cold start after the update
/// shows the change.
const message = 'Hello from the installed app';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF0071E3),
        brightness: brightness,
        primary: dark ? const Color(0xFF0A84FF) : const Color(0xFF0071E3),
        surface: dark ? const Color(0xFF1C1C1E) : Colors.white,
      ),
      scaffoldBackgroundColor: dark ? Colors.black : const Color(0xFFF5F5F7),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'flutter_patcher',
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    home: const Demo(),
  );
}

class Demo extends StatefulWidget {
  const Demo({super.key});

  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  // `flutter_patcher serve` on this computer, reached over USB by adb reverse.
  final _url = TextEditingController(text: 'http://127.0.0.1:8686');
  final _log = <String>[];
  var _busy = false;
  var _checks = 0;

  void _note(String line) => setState(() => _log.add(line));

  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } on PatcherException catch (e) {
      _note(e.message);
    } finally {
      setState(() {
        _busy = false;
        _checks++;
      });
    }
  }

  Future<void> _update() => _run(() async {
    final check = await FlutterPatcher.checkUpdate(_url.text.trim());
    if (!check.hasUpdate) return _note('Up to date');
    PatchApplyPhase? phase;
    final result = await FlutterPatcher.applyPatch(
      check.patch!,
      onProgress: (p) {
        if (p.phase != phase) _note('${(phase = p.phase).name}…');
      },
    );
    _note(
      result.ok
          ? 'Installed: restart the app to run patch ${check.patch!.version}'
          : 'Not installed: ${result.error?.name} ${result.message ?? ''}',
    );
  });

  Future<void> _rollback() => _run(() async {
    await FlutterPatcher.rollback();
    _note('Rolled back: restart the app to run the installed version');
  });

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 32, 16, 32),
          children: [
            Text(
              'flutter_patcher',
              style: text.headlineLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Signed hot updates for Flutter',
              style: text.bodyLarge?.copyWith(color: secondary),
            ),
            const SizedBox(height: 24),
            Panel(
              child: Column(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.asset('assets/patch_demo.png', height: 160),
                  ),
                  const SizedBox(height: 16),
                  Text(message, style: text.titleMedium),
                ],
              ),
            ),
            const SizedBox(height: 16),
            StatusCard(key: ValueKey(_checks)),
            const SizedBox(height: 16),
            Panel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'Update store',
                      helperText: 'flutter_patcher serve, or your HTTPS store',
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _busy ? null : _update,
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: const StadiumBorder(),
                    ),
                    child: Text(_busy ? 'Working…' : 'Check for update'),
                  ),
                  TextButton(
                    onPressed: _busy ? null : _rollback,
                    child: const Text('Roll back'),
                  ),
                ],
              ),
            ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 16),
              Panel(
                child: Text(
                  _log.join('\n'),
                  style: text.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    color: secondary,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}