Pod::Spec.new do |s|
  s.name             = 'apprefer'
  s.version          = '0.1.0'
  s.summary          = 'AppRefer SDK - First-party mobile attribution.'
  s.description      = 'First-party mobile attribution platform for iOS and Android.'
  s.homepage         = 'https://apprefer.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'AppRefer' => 'dev@apprefer.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'
  s.weak_frameworks  = 'AdServices', 'AdSupport', 'AppTrackingTransparency'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
