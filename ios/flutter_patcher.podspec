Pod::Spec.new do |s|
  s.name             = 'flutter_patcher'
  s.version          = '1.0.0'
  s.summary          = 'Self-hosted, signed Flutter hot updates.'
  s.homepage         = 'https://github.com/xuelinger2333/flutter_patcher'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'flutter_patcher'
  s.source           = { :path => '.' }
  s.source_files     = 'flutter_patcher/Sources/flutter_patcher/**/*.swift'
  s.dependency 'Flutter'
  # CryptoKit (Ed25519) is available from iOS 13.
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
