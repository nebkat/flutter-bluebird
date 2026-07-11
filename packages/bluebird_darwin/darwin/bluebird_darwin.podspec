#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint bluebird.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'bluebird_darwin'
  s.version          = '0.0.2'
  s.summary          = 'Flutter plugin for connecting and communicating with Bluetooth Low Energy devices, on Android and iOS'
  s.description      = 'Flutter plugin for connecting and communicating with Bluetooth Low Energy devices, on Android and iOS'
  s.homepage         = 'https://github.com/boskokg/bluebird'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Chip Weinberger' => 'example@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files        = 'bluebird_darwin/Sources/bluebird_darwin/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '12.0'
  s.osx.deployment_target = '10.14'
  s.swift_version = '5.9'
  s.framework = 'CoreBluetooth'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', }
end
