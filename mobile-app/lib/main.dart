//! Agent2API 移动端入口。
//!
//! 架构：Flutter 壳（webview）→ 本地 headless 服务器（进程内 Rust 静态库）
//!       → 网关 Web UI（web_shim 形态，UI 零改）。
//!
//! 启动时序：
//!   1. 取沙盒 Documents 目录作为 data_dir
//!   2. 把打包好的 assets/ui.zip 解压到 {Documents}/ui/（缺 index.html 才解压）
//!   3. agent2api_server_start(Documents, 3065) 在进程内跑起网关服务器
//!   4. 轮询 /health 直到服务真正应答（start 返回 0 只代表 bind 成功）
//!   5. webview 加载 http://127.0.0.1:3065
//!
//! ── 为什么必须等 /health ──────────────────────────────────────
//! `server::start` 只同步 bind，监听任务是在后台运行时里起的；立刻让 webview
//! 去请求会拿到 connection refused，WKWebView 就停在白屏且不再重试。

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import 'ffi.dart';

/// 网关监听端口（回环，仅本机可达）
const int kPort = 3065;

/// 面板地址
const String kUiUrl = 'http://127.0.0.1:$kPort/';

/// 探活地址（/health 返回裸 JSON，200 即服务已就绪）
const String kHealthUrl = 'http://127.0.0.1:$kPort/health';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const Agent2App());
}

class Agent2App extends StatelessWidget {
  const Agent2App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent2API',
      debugShowCheckedModeBanner: false,
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
  /// 当前阶段文案（显示在状态条 / 加载页）
  String _stage = '启动中…';

  /// 附加细节（错误码、路径、异常信息）
  String _detail = '';

  /// 服务已就绪，可以放 webview
  bool _ready = false;

  /// 启动失败，展示重试入口
  bool _failed = false;

  /// 页面加载成功后可收起状态条（失败时保持可见）
  bool _barVisible = true;

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _setup();
  }

  /// 只在挂载时 setState（启动流程有多处 await，避免 dispose 后报错）
  void _set(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  Future<void> _setup() async {
    if (_busy) return;
    _busy = true;
    try {
      _set(() {
        _failed = false;
        _ready = false;
        _barVisible = true;
        _stage = '准备数据目录…';
        _detail = '';
      });

      final docs = await getApplicationDocumentsDirectory();
      final uiPath = '${docs.path}/ui';

      // 解压判据用 index.html 而不是目录是否存在：上一次解压中途被杀会留下
      // 空目录，按目录判断会永远跳过解压，结果是永远白屏。
      if (!File('$uiPath/index.html').existsSync()) {
        _set(() => _stage = '解包管理界面…');
        await _extractUi(uiPath);
        if (!File('$uiPath/index.html').existsSync()) {
          throw StateError('解包后仍找不到 index.html（assets/ui.zip 可能没打进去）');
        }
      }

      _set(() {
        _stage = '启动网关服务…';
        _detail = '端口 $kPort　数据目录 ${docs.path}';
      });
      final code = Agent2ApiServer.start(docs.path, kPort);
      if (code != 0) {
        throw StateError('agent2api_server_start 返回 $code'
            '（1=参数非法 2=路径非 UTF-8 3=服务器内部错误，常见为端口被占用）');
      }

      _set(() => _stage = '等待服务应答…');
      final ok = await _waitHealthy();
      if (!ok) {
        throw StateError('服务启动后 20 秒内 /health 无 200 应答'
            '（静态库可能未被链接，或监听任务已退出）');
      }

      _set(() {
        _ready = true;
        _stage = '就绪';
        _detail = '';
      });
    } catch (e) {
      _set(() {
        _failed = true;
        _barVisible = true;
        _stage = '启动失败';
        _detail = '${e.toString()}\nping=${_safePing()}';
      });
    } finally {
      _busy = false;
    }
  }

  /// 探活符号（42 = 静态库已链接）。失败时用于区分「库没链上」与「服务没起来」。
  String _safePing() {
    try {
      return Agent2ApiServer.ping().toString();
    } catch (e) {
      return 'symbol-missing';
    }
  }

  /// 轮询 /health：`server::start` 只保证 bind，监听任务异步起来。
  Future<bool> _waitHealthy() async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
    try {
      for (var i = 0; i < 80; i++) {
        try {
          final request = await client.getUrl(Uri.parse(kHealthUrl));
          final response = await request.close();
          await response.drain<void>();
          if (response.statusCode == 200) return true;
        } catch (_) {
          // 还没起来：connection refused，继续等
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 解压内置 Web UI。zip 内条目可能带 `./` 前缀，且必须防 zip-slip。
  Future<void> _extractUi(String uiPath) async {
    final data = await rootBundle.load('assets/ui.zip');
    final archive = ZipDecoder().decodeBytes(data.buffer.asUint8List());
    final root = Directory(uiPath).absolute;
    final rootPrefix = '${root.path}${Platform.pathSeparator}';

    for (final file in archive) {
      if (!file.isFile) continue;
      // archive 3.x 的 zip 条目解码后 content 即完整字节（非流式）
      final content = file.content;
      if (content is! List<int>) continue;

      var name = file.name.replaceAll('\\', '/');
      while (name.startsWith('./')) {
        name = name.substring(2);
      }
      name = name.replaceFirst(RegExp(r'^/+'), '');
      if (name.isEmpty) continue;

      final out = File('${root.path}/$name');
      // 归一化后必须仍在 ui/ 之内，否则丢弃（zip-slip 防御）
      final normalized = out.absolute.path;
      if (!normalized.startsWith(rootPrefix)) continue;

      await out.parent.create(recursive: true);
      await out.writeAsBytes(content, flush: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      body: Stack(
        children: [
          Positioned.fill(
            child: _ready
                ? InAppWebView(
                    initialUrlRequest: URLRequest(url: WebUri(kUiUrl)),
                    initialSettings: InAppWebViewSettings(
                      javaScriptEnabled: true,
                      domStorageEnabled: true,
                      allowsInlineMediaPlayback: true,
                      mediaPlaybackRequiresUserGesture: false,
                      supportZoom: false,
                      transparentBackground: false,
                    ),
                    onLoadStop: (controller, url) {
                      if (!mounted) return;
                      setState(() => _barVisible = false);
                    },
                    onReceivedError: (controller, request, error) {
                      if (!mounted) return;
                      setState(() {
                        _barVisible = true;
                        _failed = true;
                        _stage = '页面加载失败';
                        _detail = '${request.url}\n${error.description}';
                      });
                    },
                  )
                : _loadingView(),
          ),
          if (_barVisible)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: IgnorePointer(
                  ignoring: !_failed,
                  child: Container(
                    margin: const EdgeInsets.fromLTRB(10, 6, 10, 0),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xE6101216),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0x33FFFFFF)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (!_failed)
                          const Padding(
                            padding: EdgeInsets.only(top: 1, right: 8),
                            child: SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _stage,
                                style: TextStyle(
                                  color: _failed
                                      ? const Color(0xFFFF7A7A)
                                      : Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (_detail.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 3),
                                  child: Text(
                                    _detail,
                                    style: const TextStyle(
                                      color: Color(0xFFB9BEC7),
                                      fontSize: 11,
                                      height: 1.35,
                                    ),
                                  ),
                                ),
                              if (_failed)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Row(
                                    children: [
                                      _barButton('重试', () {
                                        Agent2ApiServer.stop();
                                        _setup();
                                      }),
                                      const SizedBox(width: 8),
                                      _barButton('只看页面', () {
                                        setState(() {
                                          _barVisible = false;
                                          _ready = true;
                                        });
                                      }),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _barButton(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF2B6CF6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _loadingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!_failed)
              const SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
            if (!_failed) const SizedBox(height: 16),
            Text(
              _stage,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (_detail.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                _detail,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Color(0xFF9AA0AA),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
