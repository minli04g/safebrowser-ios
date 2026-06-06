# Sets CODE_SIGN_ENTITLEMENTS = App/App.entitlements on the App target for all
# build configurations. Idempotent — safe to run after every `cap sync`. Uses
# the xcodeproj gem (in the Gemfile) so we never hand-edit project.pbxproj.
require 'xcodeproj'

project_path = File.expand_path('../ios/App/App.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'App' }
raise 'App target not found' unless target

target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/App.entitlements'
end

project.save
puts "ensured CODE_SIGN_ENTITLEMENTS on #{target.build_configurations.map(&:name).join(', ')}"
