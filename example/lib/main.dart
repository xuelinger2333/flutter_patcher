import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_patcher/flutter_patcher.dart';

import 'diag_card.dart';
import 'log_panel.dart';

/// flutter_patcher 最小演示：
///  - "Apply patch"：从 APK 内置 asset 读红色 libapp.so，装成热更补丁
///  - 冷启动 app → 按钮变红（补丁生效）
///  - "Rollback" + 冷启动 → 回到蓝色（APK 内置版本）
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'flutter_patcher example',
    // APK 内置的 .so 是蓝色主题，补丁包里的 .so 是红色主题，切换补丁就能看到颜色变化
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

  /// 读 APK 内置的 libapp_preload.so → 交给 applyPatchBytes 落盘。
  /// 下次冷启动 Flutter Engine 会用这份 .so 代替 APK 内置的版本。
  Future<void> _apply() async {
    _log.log('loading bundled asset...');
    final bytes = (await rootBundle.load(
      'assets/libapp_preload.so',
    )).buffer.asUint8List();
    final result = await FlutterPatcher.applyPatchBytes(
      bytes,
      version: 'bundled-1',
      onProgress: (p) => _log.log('  [${p.phase.name}]'),
    );
    _log.log(
      result.ok
          ? '✅ APPLIED — force-stop the app and reopen to see the new theme'
          : '❌ failed: ${result.error?.name} / ${result.message}',
    );
    DiagCard.refresh();
  }

  Future<void> _rollback() async {
    await FlutterPatcher.rollback();
    _log.log('🔄 ROLLED BACK — force-stop the app and reopen to revert');
    DiagCard.refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('flutter_patcher example (BASE)')),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DiagCard(),
            const SizedBox(height: 12),
            FilledButton(onPressed: _apply, child: const Text('Apply patch')),
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
