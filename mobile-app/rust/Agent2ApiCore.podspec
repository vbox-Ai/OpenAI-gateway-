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
end
