require "active_support/core_ext/module/delegation"

module InventoryRefresh
  class InventoryObjectLazy
    attr_reader :reference, :inventory_collection, :key, :default, :transform_nested_lazy_finds

    delegate :stringified_reference, :ref, :[], :to => :reference

    # @param inventory_collection [InventoryRefresh::InventoryCollection] InventoryCollection object owning the
    #        InventoryObject
    # @param index_data [Hash] data of the InventoryObject object
    # @param ref [Symbol] reference name
    # @param key [Symbol] key name, will be used to fetch attribute from resolved InventoryObject
    # @param default [Object] a default value used if the :key will resolve to nil
    # @param transform_nested_lazy_finds [Boolean] True if we want to convert all lazy objects in InventoryObject
    #        objects and reset the Reference. TODO(lsmola) we should be able to do this automatically, then we can
    #        remove this option
    def initialize(inventory_collection, index_data, ref: :manager_ref, key: nil, default: nil, transform_nested_lazy_finds: false)
      @inventory_collection = inventory_collection
      @reference            = inventory_collection.build_reference(index_data, ref)
      @key                  = key
      @default              = default

      @transform_nested_lazy_finds = transform_nested_lazy_finds

      # We do not support skeletal pre-create for :key, since :key will not be available, we want to use local_db_find
      # instead.
      skeletal_precreate! unless @key
    end

    # @return [String] stringified reference
    def to_s
      # TODO(lsmola) do we need this method?
      stringified_reference
    end

    # @return [String] string format for nice logging
    def inspect
      suffix = ""
      suffix += ", ref: #{ref}" if ref.present?
      suffix += ", key: #{key}" if key.present?
      "InventoryObjectLazy:('#{self}', #{inventory_collection}#{suffix})"
    end

    # @param inventory_object [InventoryRefresh::InventoryObject] InventoryObject object owning this relation
    # @param inventory_object_key [Symbol] InventoryObject object's attribute pointing to this relation
    # @return [InventoryRefresh::InventoryObject, Object] InventoryRefresh::InventoryObject instance or an attribute
    #         on key
    def load(inventory_object = nil, inventory_object_key = nil)
      transform_nested_secondary_indexes! if transform_nested_lazy_finds && nested_secondary_index?

      load_object(inventory_object, inventory_object_key)
    end

    # return [Boolean] true if the Lazy object is causing a dependency, Lazy link is always a dependency if no :key
    #        is provider or if it's transitive_dependency
    def dependency?
      # If key is not set, InventoryObjectLazy is a dependency, cause it points to the record itself. Otherwise
      # InventoryObjectLazy is a dependency only if it points to an attribute which is a dependency or a relation.
      !key || transitive_dependency?
    end

    # return [Boolean] true if the Lazy object is causing a transitive dependency, which happens if the :key points
    #        to an attribute that is causing a dependency.
    def transitive_dependency?
      # If the dependency is inventory_collection.lazy_find(:ems_ref, :key => :stack)
      # and a :stack is a relation to another object, in the InventoryObject object,
      # then this relation is considered transitive.
      key && association?(key)
    end

    # @return [Boolean] true if the key is an association on inventory_collection_scope model class
    def association?(key)
      # TODO(lsmola) remove this if there will be better dependency scan, probably with transitive dependencies filled
      # in a second pass, then we can get rid of this hardcoded symbols. Right now we are not able to introspect these.
      return true if [:parent, :genealogy_parent].include?(key)

      inventory_collection.dependency_attributes.key?(key) ||
        !inventory_collection.association_to_foreign_key_mapping[key].nil?
    end

    def transform_nested_secondary_indexes!(depth = 0)
      raise "Nested references are too deep!" if depth > 20

      keys.each do |x|
        attr = full_reference[x]
        next unless attr.kind_of?(InventoryRefresh::InventoryObjectLazy)
        next if attr.primary?

        if attr.nested_secondary_index?
          attr.transform_nested_secondary_indexes!(depth + 1)
        end

        full_reference[x] = full_reference[x].load
      end

      # Rebuild the reference to get the right value
      self.reference = inventory_collection.build_reference(full_reference, ref)
    end

    private

    delegate :parallel_safe?, :saved?, :saver_strategy, :skeletal_primary_index, :targeted?, :to => :inventory_collection
    delegate :nested_secondary_index?, :primary?, :full_reference, :keys, :primary?, :to => :reference

    attr_writer :reference

    # Instead of loading the reference from the DB, we'll add the skeletal InventoryObject (having manager_ref and
    # info from the default_values) to the correct InventoryCollection. Which will either be found in the DB or
    # created as a skeletal object. The later refresh of the object will then fill the rest of the data, while not
    # touching the reference.
    #
    # @return [InventoryRefresh::InventoryObject, NilClass] Returns pre-created InventoryObject or nil
    def skeletal_precreate!
      # We can do skeletal pre-create only for strategies using unique indexes. Since this can build records out of
      # the given :arel scope, we will always attempt to create the recod, so we need unique index to avoid duplication
      # of records.
      return unless parallel_safe?
      # Pre-create only for strategies that will be persisting data, i.e. are not saved already
      return if saved?
      # We can only do skeletal pre-create for primary index reference, since that is needed to create DB unique index
      return unless primary?
      # Full reference must be present
      return if full_reference.blank?

      # To avoid pre-creating invalid records all fields of a primary key must have non null value
      # TODO(lsmola) for composite keys, it's still valid to have one of the keys nil, figure out how to allow this. We
      # will need to scan the DB for NOT NULL constraint and allow it based on that. So we would move this check to
      # saving code, but this will require bigger change, since having the column nil means we will have to batch it
      # smartly, since having nil means we will need to use different unique index for the upsert/update query.
      return if keys.any? { |x| full_reference[x].nil? }

      skeletal_primary_index.build(full_reference)
    end

    # @param loaded_object [InventoryRefresh::InventoryObject, NilClass] Loaded object or nil if object wasn't found
    # @return [Object] value found or :key or default value if the value is nil
    def load_object_with_key(loaded_object)
      # TODO(lsmola) Log error if we are accessing path that is present in blacklist or not present in whitelist
      if loaded_object.present?
        if loaded_object.try(:data).present?
          loaded_object.data[key] || default
        else
          loaded_object.public_send(key) || default
        end
      else
        default
      end
    end

    # @return [InventoryRefresh::InventoryObject, NilClass] InventoryRefresh::InventoryObject instance or nil if not found
    def load_object(inventory_object = nil, inventory_object_key = nil)
      loaded_object = inventory_collection.find(reference)

      if inventory_object && inventory_object_key && !loaded_object && reference.loadable?
        # Object was not loaded, but the reference is pointing to something, lets return it as edge that should've
        # been loaded.
        inventory_object.inventory_collection.store_unconnected_edges(inventory_object, inventory_object_key, self)
      end

      key ? load_object_with_key(loaded_object) : loaded_object
    end
  end
end
