//! Agent2API 移动端入口。
//!
//! 架构：Flutter 壳（webview）→ 本地 headless 服务器（进程内 Rust 静态库）
//!       → 网关 Web UI（web_shim 形态，UI 零改）。
//!
//! 启动时序：先 agent2api_server_start 把网关服务器在进程内跑起来，
//! 再用 webview 加载 http://127.0.0.1:3065。

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

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
  String? _status;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  Future<void> _startServer() async {
    // TODO 真机：用 path_provider 取沙盒 Documents 目录；骨架先给临时目录。
    final dir = Directory.systemTemp.path;
    try {
      final code = Agent2ApiServer.start(dir, 3065);
      if (!mounted) return;
      setState(() => _status = code == 0 ? 'server ok' : 'server start failed: $code');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = 'error: $e');
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
              // 本地回环 HTTP，iOS ATS 需放行本地网络
              allowsLinkPreview: false,
            ),
            onLoadError: (controller, url, code, message) {
              // 服务器可能尚未就绪，先容忍；就绪后用户可下拉刷新
            },
          ),
          if (_status != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: IgnorePointer(
                child: Container(
                  color: const Color(0xAA000000),
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    _status!,
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
