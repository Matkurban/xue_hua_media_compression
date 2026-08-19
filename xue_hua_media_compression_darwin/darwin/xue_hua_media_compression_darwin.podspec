#
# iOS + macOS shared implementation of xue_hua_media_compression.
# xue_hua_media_compression 的 iOS / macOS 共享实现。
#
Pod::Spec.new do |s|
  s.name             = 'xue_hua_media_compression_darwin'
  s.version          = '2.0.0'
  s.summary          = 'iOS and macOS implementation of xue_hua_media_compression.'
  s.description      = <<-DESC
ImageIO still-image compression and VideoToolbox hardware video encode
shared between iOS and macOS.
                       DESC
  s.homepage         = 'https://github.com/Matkurban/xue_hua_media_compression'
  s.license          = { :file => '../../LICENSE' }
  s.author           = { 'Matkurban' => '3496354336@qq.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'xue_hua_media_compression_darwin/Sources/xue_hua_media_compression_darwin/**/*.swift'
  s.resource_bundles = {
    'xue_hua_media_compression_darwin_privacy' => [
      'xue_hua_media_compression_darwin/Sources/xue_hua_media_compression_darwin/PrivacyInfo.xcprivacy'
    ]
  }

  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.15'
  s.ios.frameworks = 'AVFoundation', 'ImageIO', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'QuartzCore'
  s.osx.frameworks = 'AVFoundation', 'ImageIO', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'QuartzCore'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
