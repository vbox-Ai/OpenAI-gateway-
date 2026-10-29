//! Agent2API 移动端入口。
//!
//! 架构：Flutter 壳（webview）→ 本地 headless 服务器（进程内 Rust 静态库）
//!       → 网关 Web UI（web_shim 形态，UI 零改）。
//!
//! 启动时序：
//!   1. 取沙盒 Documents 目录作为 data_dir
//!   2. 把打包好的 assets/ui.zip 解压到 {Documents}/ui/（首次启动）
//!   3. agent2api_server_start(Documents, 3065) 在进程内跑起网关服务器
//!   4. webview 加载 http://127.0.0.1:3065

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import 'ffi.dart';

void main() {
  runApp(const Agent2App());
}

class Agent2App extends StatelessWidget {
  const Agent2App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent2API',
      theme: ThemeData.dark(useMaterial3: true),
      home: const WebUiPage(),
    );
  }
}

class WebUiPage extends StatefulWidget {
  const WebUiPage({super.key});

  @override
  State<WebUiPage> createState() => _WebUiPageState();
}

class _WebUiPageState extends State<WebUiPage> {
  String _status = '启动中…';

  @override
  void initState() {
    super.initState();
    _setup();
  }

  Future<void> _setup() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final uiDir = Directory('${docs.path}/ui');

      // 首次启动：解压打包好的 Web UI 到 {Documents}/ui/
      if (!await uiDir.exists()) {
        await _extractUi(uiDir.path);
      }

      // 在进程内启动网关 headless 服务器
      final code = Agent2ApiServer.start(docs.path, 3065);
      if (!mounted) return;
      setState(() => _status = code == 0 ? '服务已启动' : '服务启动失败: $code');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '初始化错误: $e');
    }
  }

  Future<void> _extractUi(String uiPath) async {
    final data = await rootBundle.load('assets/ui.zip');
    final archive = ZipDecoder().decodeBytes(data.buffer.asUint8List());
    for (final file in archive) {
      if (file.isFile) {
        final content = file.content;
        if (content == null) continue;
        final out = File('$uiPath/${file.name}');
        await out.parent.create(recursive: true);
        await out.writeAsBytes(content);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          InAppWebView(
            initialUrlRequest: URLRequest(
              url: WebUri('http://127.0.0.1:3065/'),
            ),
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              domStorageEnabled: true,
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Container(
                color: const Color(0xAA000000),
                padding: const EdgeInsets.all(8),
                child: Text(
                  _status,
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
