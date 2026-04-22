import 'package:flutter/material.dart';
import 'package:flutter_patcher/flutter_patcher.dart';

/// Example for flutter_patcher.
///
/// 演示：
///  1. 在 main() 里调 FlutterPatcher.init，下发公钥 + 熔断阈值，并在首帧后清熔断
///  2. 点「Check update」→ 用 mock 数据模拟 checkUpdate 的响应
///  3. 点「Apply patch」→ 把 mock 得到的 PatchInfo 交给 applyPatch
///  4. 点「Rollback」→ 手动回滚到 APK 内置版本
///
/// 注：mock 的 patchUrl 指向一个不存在的地址，applyPatch 会返回 false —— 这是正常
/// 的，真实联调时把 URL 换成真正的 .so 下载地址即可。
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await FlutterPatcher.init(
    // 真实项目请换成自己的 Ed25519 公钥（X.509 DER Base64），留空则跳过签名校验
    publicKeyBase64: '',
    maxCrashCount: 2,
  );
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _logs = <String>[];
  String? _currentVersion;
  PatchInfo? _pending;

  @override
  void initState() {
    super.initState();
    _refreshVersion();
  }

  Future<void> _refreshVersion() async {
    final v = await FlutterPatcher.currentVersion;
    if (!mounted) return;
    setState(() => _currentVersion = v);
  }

  void _log(String msg) {
    setState(() => _logs.insert(0, msg));
  }

  // ---- Mock checkUpdate ----
  // 真实项目你会用自己的 HTTP/gRPC/配置中心拉元信息，然后直接 new PatchInfo(...)
  // —— 插件不绑定任何后端协议。
  Future<void> _onCheckUpdate() async {
    _log('checkUpdate: using mock PatchInfo');
    final mock = const PatchInfo(
      version: '1.0.1-h1',
      patchUrl: 'https://example.com/not-a-real-patch/libapp.so',
      md5: '00000000000000000000000000000000',
      targetVersionCode: 1,
    );
    setState(() => _pending = mock);
    _log('mock patch available: ${mock.version}');
  }

  Future<void> _onApplyPatch() async {
    final info = _pending;
    if (info == null) {
      _log('no pending patch, click "Check update" first');
      return;
    }
    _log('applyPatch ${info.version} ...');

    // 订阅进度（在 applyPatch 调用前订阅）
    final sub = FlutterPatcher.applyProgress.listen((p) {
      switch (p.phase) {
        case PatchApplyPhase.downloading:
          final pct = p.fraction;
          _log(pct != null
              ? 'downloading ${(pct * 100).toStringAsFixed(1)}% (${p.bytesReceived}/${p.totalBytes})'
              : 'downloading ${p.bytesReceived} bytes');
          break;
        case PatchApplyPhase.verifying:
          _log('verifying md5 + signature...');
          break;
        case PatchApplyPhase.bsdiffMerging:
          _log('bsdiff merging...');
          break;
        case PatchApplyPhase.finalizing:
          _log('finalizing (rename + write meta)...');
          break;
      }
    });

    try {
      final result = await FlutterPatcher.applyPatch(info);
      if (result.ok) {
        _log('applyPatch ok, restart to take effect');
        await _refreshVersion();
      } else {
        _log('applyPatch failed: ${result.error?.name} / ${result.message}');
      }
    } finally {
      await sub.cancel();
    }
  }

  Future<void> _onRollback() async {
    await FlutterPatcher.rollback();
    _log('rollback done (takes effect on next cold start)');
    await _refreshVersion();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'flutter_patcher example',
      home: Scaffold(
        appBar: AppBar(title: const Text('flutter_patcher example')),
        body: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('current patch version: ${_currentVersion ?? '(none)'}'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton(
                    onPressed: _onCheckUpdate,
                    child: const Text('Check update (mock)'),
                  ),
                  FilledButton(
                    onPressed: _onApplyPatch,
                    child: const Text('Apply patch'),
                  ),
                  OutlinedButton(
                    onPressed: _onRollback,
                    child: const Text('Rollback'),
                  ),
                ],
              ),
              const Divider(height: 32),
              const Text('Logs:'),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                  ),
                  child: ListView.builder(
                    itemCount: _logs.length,
                    itemBuilder: (_, i) => Text(
                      _logs[i],
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
