#
# iOS implementation of xue_hua_media_compression.
# xue_hua_media_compression 的 iOS 实现。
#
Pod::Spec.new do |s|
  s.name             = 'xue_hua_media_compression'
  s.version          = '2.4.1'
  s.summary          = 'iOS implementation of xue_hua_media_compression.'
  s.description      = <<-DESC
ImageIO still-image compression and VideoToolbox hardware video encode for iOS.
                       DESC
  s.homepage         = 'https://github.com/Matkurban/xue_hua_media_compression'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Matkurban' => '3496354336@qq.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'xue_hua_media_compression/Sources/xue_hua_media_compression/**/*.swift'
  s.resource_bundles = {
    'xue_hua_media_compression_privacy' => [
      'xue_hua_media_compression/Sources/xue_hua_media_compression/PrivacyInfo.xcprivacy'
    ]
  }

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.frameworks = 'AVFoundation', 'ImageIO', 'VideoToolbox', 'CoreMedia', 'CoreVideo', 'QuartzCore'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
