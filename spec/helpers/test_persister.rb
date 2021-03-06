require_relative "test_builder"
require_relative "test_builder/persister_helper"

class TestPersister < InventoryRefresh::Persister
  attr_reader :manager, :collections, :options

  include ::TestBuilder::PersisterHelper

  # @return [Config::Options] Options for the manager type
  def options
    @options ||= {}
  end

  def initialize(manager, extra_options = {})
    @options     = extra_options
    super(manager)
  end

  def assert_graph_integrity?
    true
  end
end
