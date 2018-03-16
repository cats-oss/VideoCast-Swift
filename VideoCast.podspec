Pod::Spec.new do |s|
s.name = 'VideoCast'
s.version = '0.1.0'
s.license = 'MIT'
s.summary = 'A framework for broadcasting live video'
s.homepage = 'https://github.com/openfresh/VideoCast-Swift'
s.authors = { 'Tomohiro Matsuzawa' => 'thmatuza75@hotmail.com' }
s.source = { :git => 'https://github.com/openfresh/VideoCast-Swift.git', :tag => s.version }

s.ios.deployment_target = '10.0'

s.source_files = [ 'Source/**/*.swift', 'SRT/*.{h,cpp}', 'SRT/Includes/*.h' ]
s.public_header_files = ['SRT/Includes/*.h', 'SRT/udt_wrapper.h']
s.vendored_libraries = 'SRT/*.a'

s.frameworks          = [ 'VideoToolbox', 'AudioToolbox', 'AVFoundation', 'CFNetwork', 'CoreMedia',
'CoreVideo', 'OpenGLES', 'Foundation', 'CoreGraphics' ]

s.libraries           = 'c++'
end
