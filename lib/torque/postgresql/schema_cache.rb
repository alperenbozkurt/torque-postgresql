module Torque
  module PostgreSQL
    # :TODO: Create the +add+ to load inheritance info
    module SchemaCache

      def initialize(*) # :nodoc:
        super

        @data_sources_model_names = {}
        @inheritance_dependencies = {}
        @inheritance_associations = {}
        @cached_data_sources_size = 0
      end

      def initialize_dup(*) # :nodoc:
        super
        @data_sources_model_names = @data_sources_model_names.dup
        @inheritance_dependencies = @inheritance_dependencies.dup
        @inheritance_associations = @inheritance_associations.dup
        @cached_data_sources_size = @cached_data_sources_size.dup
      end

      def clear! # :nodoc:
        super
        @data_sources_model_names.clear
        @inheritance_dependencies.clear
        @inheritance_associations.clear
        @cached_data_sources_size = nil
      end

      def size # :nodoc:
        super + [
          @data_sources_model_names,
          @inheritance_dependencies,
          @inheritance_associations,
        ].map(&:size).inject(:+)
      end

      def clear_data_source_cache!(name) # :nodoc:
        super
        @data_sources_model_names.delete name
        @inheritance_dependencies.delete name
        @inheritance_associations.delete name
        @inheritance_cache -= 1
      end

      def marshal_dump # :nodoc:
        super + [
          @inheritance_cache,
          @inheritance_dependencies,
          @inheritance_associations,
          @data_sources_model_names,
        ]
      end

      def marshal_load(array) # :nodoc:
        @data_sources_model_names = array.pop
        @inheritance_associations = array.pop
        @inheritance_dependencies = array.pop
        @inheritance_cache = array.pop
        super
      end

      # A way to manually add models name so it doesn't need the lookup method
      def add_model_name(table_name, model)
        return unless data_source_exists?(table_name)
        model = model.name if model.is_a?(Module)
        @data_sources_model_names[table_name] = model
      end

      # Get all the tables that the given one inherits from
      def dependencies(table_name)
        reload_inheritance_data!
        @inheritance_dependencies[table_name]
      end

      # Get the list of all tables that are associated (direct or indirect
      # inheritance) with the provided one
      def associations(table_name)
        reload_inheritance_data!
        @inheritance_associations[table_name]
      end

      # Try to find a model based on a given table
      def lookup_model(table_name, scopred_class = '')
        scopred_class = scopred_class.name if scopred_class.is_a?(Class)
        return @data_sources_model_names[table_name] \
          if @data_sources_model_names.key?(table_name)

        # Get all the possible scopes
        scopes = scopred_class.scan(/(?:::)?[A-Z][a-z]+/)
        scopes.unshift('Object::')

        # Consider the maximum namespaced possible model name
        max_name = table_name.tr('_', '/').camelize.split(/(::)/)
        max_name[-1] = max_name[-1].singularize

        # Test all the possible names against all the possible scopes
        until scopes.size == 0
          scope = scopes.join.safe_constantize
          model = find_model(max_name, table_name, scope) unless scope.nil?
          return @data_sources_model_names[table_name] = model unless model.nil?
          scopes.pop
        end

        nil
      end

      private

        # Find a model by a given max namespaced class name thath matches the
        # given table name
        def find_model(max_name, table_name, scope = Object)
          pieces = max_name.is_a?(Array) ? max_name : max_name.split(/(::)/)
          ns_places = (1..(max_name.size - 1)).step(2).to_a

          # Generate all possible combinarions
          conditions = []
          range = Torque::PostgreSQL.config.inheritance.inverse_lookup \
            ? 0.upto(ns_places.size) \
            : ns_places.size.downto(0)
          range.each do |size|
            conditions.concat(ns_places.combination(size).to_a)
          end

          # Now iterate over
          while (condition = conditions.shift)
            ns_places.each{ |i| pieces[i] = condition.include?(i) ? '::' : '' }
            next unless scope.const_defined?(pieces.join)

            # Check if the class match the table name
            klass = scope.const_get(pieces.join)
            return klass if klass < ::ActiveRecord::Base && klass.table_name == table_name
          end
        end

        # Generates the cache key for inheitance information
        def inheritance_cache_key
          @data_sources.keys.sort.join(',')
        end

        # Reload information about tables inheritance and dependencies, uses a
        # cache to not perform additional checkes
        def reload_inheritance_data!
          cache_key = inheritance_cache_key

          return unless @inheritance_cache != cache_key
          @inheritance_cache = cache_key

          @inheritance_dependencies = connection.inherited_tables.freeze
          @inheritance_associations = generate_associations.freeze
        end

        # Calculates the inverted dependency (association), where even indirect
        # inheritance comes up in the list
        def generate_associations
          result = Hash.new{ |h, k| h[k] = [] }
          masters = @inheritance_dependencies.values.flatten.uniq

          # Add direct associations
          masters.map do |master|
            @inheritance_dependencies.each do |(dependent, associations)|
              result[master] << dependent if associations.include?(master)
            end
          end

          # Add indirect associations
          result.each do |master, children|
            children.each do |child|
              children.concat(result[child]).uniq! if result.key?(child)
            end
          end

          # Remove the default proc that would create new entries
          result.default_proc = nil
          result
        end

        # Use this method to also load any irregular model name. This is smart
        # enought to only load the sources present on this instance
        def prepare_data_sources
          @data_sources_model_names = begin
            Torque::PostgreSQL.config.irregular_models.slice(@data_sources.keys)
          end
        end

    end

    ActiveRecord::ConnectionAdapters::SchemaCache.prepend SchemaCache
  end
end
