platform :ios, '15.0'

target 'NosmaiLiveKitExample' do
  use_frameworks!

  # Nosmai — camera, filters, AR. Same pod the Flutter plugin depends on.
  # `pod install` fetches the framework, so there is nothing to download by hand.
  # If Nosmai gave you a framework build directly, point the pod at the folder
  # you unpacked it into instead:
  #   pod 'NosmaiCameraSDK', :path => './LocalNosmai'
  pod 'NosmaiCameraSDK', '~> 3.0.0'

  # LiveKit's Swift client. NOTE the module is LiveKitClient, not LiveKit.
  pod 'LiveKitClient', '~> 2.0'
end

# Some transitive pods still declare very old deployment targets (as low as
# iOS 8), which modern Xcode cannot build — it looks for libarclite, which was
# removed. Force every pod to the app's minimum.
post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'
    end
  end
end
