import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

import 'diag_card.dart';
import 'log_panel.dart';

// Build this app with `flutter_patcher build android --host-policy`, make a
// patch (for example after replacing this image) with `patch android`, publish
// it with `flutter_patcher publish`, and enter the manifest's HTTPS URL below.
const _demoImage = 'assets/patch_demo.png';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'flutter_patcher example',
    theme: ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      useMaterial3: true,
    ),
    home: const Demo(),
  );
}

class Demo extends StatefulWidget {
  const Demo({super.key});

  @override
  State<Demo> createState() => _DemoState();
}

class _DemoState extends State<Demo> {
  final _log = LogController();
  final _url = TextEditingController();

  Future<void> _update() async {
    try {
      final check = await FlutterPatcher.checkUpdate(_url.text.trim());
      if (!check.hasUpdate) {
        _log.log('no update');
        return;
      }
      _log.log('update ${check.patch!.version}, applying...');
      final result = await FlutterPatcher.applyPatch(
        check.patch!,
        onProgress: (p) => _log.log('  [${p.phase.name}]'),
      );
      _log.log(
        result.ok
            ? 'APPLIED: force-stop and reopen to load it'
            : 'failed: ${result.error?.name} / ${result.message}',
      );
    } on PatcherException catch (e) {
      _log.log('check failed: ${e.message}');
    }
    DiagCard.refresh();
  }

  Future<void> _rollback() async {
    await FlutterPatcher.rollback();
    _log.log('ROLLED BACK: force-stop and reopen to restore the APK version');
    DiagCard.refresh();
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('flutter_patcher example')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 54,
              child: Image.asset(_demoImage, fit: BoxFit.contain),
            ),
            const SizedBox(height: 12),
            const DiagCard(),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              decoration: const InputDecoration(
                labelText: 'Signed manifest URL',
                hintText: 'https://example.com/manifest.json',
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: _update,
              child: const Text('Check and apply update'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _rollback, child: const Text('Rollback')),
            const SizedBox(height: 16),
            Expanded(child: LogPanel(controller: _log)),
          ],
        ),
      ),
    ),
  );
}