Pod::Spec.new do |s|
  s.name      = 'VideoCast'
  s.version   = '0.1.5'
  s.license   = { :type => "MIT", :file => "LICENSE" }
  s.summary   = 'A framework for broadcasting live video'
  s.homepage  = 'https://github.com/openfresh/VideoCast-Swift'
  s.authors   = { 'Tomohiro Matsuzawa' => 'thmatuza75@hotmail.com' }
  s.source    = { :git => 'https://github.com/openfresh/VideoCast-Swift.git', :tag => s.version }

  s.ios.deployment_target = '8.0'

s.source_files = [ 'Source/**/*.{swift,h,metal}', 'SRT/*.{h,cpp}', 'SRT/Includes/*.h' ]
  s.public_header_files = [ 'SRT/Includes/*.h', 'SRT/udt_wrapper.h', 'Source/System/ShaderDefinitions.h' ]
  s.vendored_libraries = 'SRT/*.a'

  s.libraries = 'c++'

  s.pod_target_xcconfig = {
    'CLANG_WARN_DOCUMENTATION_COMMENTS' => 'NO',
  }
  s.cocoapods_version = ">= 1.4.0"
  s.swift_version = "5.0"
end
