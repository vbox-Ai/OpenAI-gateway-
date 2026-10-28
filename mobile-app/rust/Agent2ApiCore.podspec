Pod::Spec.new do |s|
  s.name             = 'Agent2ApiCore'
  s.version          = '1.0.0'
  s.summary          = 'Agent2API 网关 headless 服务器（Rust 静态库）'
  s.description      = '将 libagent2api_server.a 作为 vendored 静态库链接进 Flutter iOS App'
  s.homepage         = 'https://github.com/vbox-Ai/OpenAI-gateway-'
  s.license          = { :type => 'MIT' }
  s.author           = { 'vbox-Ai' => 'vbox-Ai@users.noreply.github.com' }
  s.source           = { :path => '.' }
  s.vendored_libraries = 'libagent2api_server.a'
  s.ios.deployment_target = '13.0'
  s.static_framework = true
  # 关键：dart:ffi 运行时才解析符号，链接期没有任何代码引用它们，
  # 链接器会把整个 .a dead-strip 掉。必须 force_load 强制完整链入。
  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-Wl,-force_load,$(PODS_TARGET_SRCROOT)/libagent2api_server.a'
  }
end
