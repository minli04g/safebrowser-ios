# Prepares the Xcode project for a CI build (idempotent — safe to run after
# every `cap sync`). Uses the xcodeproj gem (in the Gemfile) so we never
# hand-edit project.pbxproj.
#
#  1. CODE_SIGN_ENTITLEMENTS = App/App.entitlements  (push entitlement)
#  2. CURRENT_PROJECT_VERSION = $BUILD_NUMBER         (unique TestFlight build #)
#
# BUILD_NUMBER is the GitHub Actions run number; TestFlight rejects duplicate
# build numbers, so each upload must bump it. Left untouched when unset (local).
require 'xcodeproj'

project_path = File.expand_path('../ios/App/App.xcodeproj', __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |t| t.name == 'App' }
raise 'App target not found' unless target

build_number = ENV['BUILD_NUMBER']
target.build_configurations.each do |config|
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'App/App.entitlements'
  config.build_settings['CURRENT_PROJECT_VERSION'] = build_number if build_number && !build_number.empty?
end

project.save
puts "ensured entitlements#{build_number && !build_number.empty? ? " + build #{build_number}" : ''}"
