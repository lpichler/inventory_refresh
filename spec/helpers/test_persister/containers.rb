require_relative '../test_persister'

class TestPersister::Containers < ::TestPersister
  def initialize_inventory_collections
    %i(containers
       container_build_pods
       container_groups
       container_group_tags
       container_image_registries
       container_images
       container_nodes
       container_projects
       container_replicators
       nested_containers
       tags).each do |name|

      add_collection(name, container)
    end
  end

  protected

  def strategy
    :local_db_find_missing_references
  end

  def shared_options
    super.merge(options).merge(:retention_strategy => "archive")
  end
end
