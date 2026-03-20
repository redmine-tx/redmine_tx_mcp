# Load the Redmine helper from either:
# 1. a normal plugin install under redmine/plugins/redmine_tx_mcp
# 2. a sibling checkout next to ../redmine when this repo is symlinked in
shim_path = File.expand_path('support/test_shims', __dir__)
$LOAD_PATH.unshift(shim_path) if Dir.exist?(shim_path) && !$LOAD_PATH.include?(shim_path)

require 'bundler/setup'
require 'action_cable'
module ActionCable
  module Server
  end
end unless defined?(ActionCable::Server)
require 'action_cable/server/configuration'
require 'action_cable/server/base'

candidates = [
  File.expand_path('../../../test/test_helper', __dir__),
  File.expand_path('../../redmine/test/test_helper', __dir__),
  File.expand_path('../../../../test/test_helper', __dir__)
]

helper = candidates.find { |path| File.exist?("#{path}.rb") || File.exist?(path) }
raise LoadError, "Could not locate Redmine test_helper. Checked: #{candidates.join(', ')}" unless helper

require helper
