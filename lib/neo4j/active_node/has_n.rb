module Neo4j::ActiveNode
module HasN
  extend ActiveSupport::Concern
  include Neo4j::ActiveNode::HasN::AutosaveAssociation

  class NonPersistedNodeError < StandardError; end

  # Clears out the association cache.
  def clear_association_cache #:nodoc:
    association_cache.clear if persisted?
  end

  # :nodoc:
  def association_cache
    @association_cache ||= {}
  end

  # Returns the specified association instance if it responds to :loaded?, nil otherwise.
  def association_instance_get(object, association_obj)
    return if association_cache.nil? || association_cache.empty?
    lookup_obj = cacheable_object(object)
    reflection = association_reflection(association_obj)
    association_cache[reflection.name] ? association_cache[reflection.name][lookup_obj] : nil
  end

  def association_instance_get_by_reflection(reflection_name)
    association_cache[reflection_name]
  end

  # Set the specified association instance.
  def association_instance_set(object, association, association_obj)
    cache_key = cacheable_object(object)
    reflection = association_reflection(association_obj)
    @association_cache[reflection.name] = { cache_key => association } unless reflection.nil?
  end

  def association_reflection(association_obj)
    self.class.reflect_on_association(association_obj.name)
  end

  def cacheable_object(obj)
    obj.respond_to?(:to_cypher_with_params) ? obj.to_cypher_with_params.hash.abs : obj
  end

  module ClassMethods
    def has_association?(name)
      !!associations[name.to_sym]
    end

    def associations
      @associations || {}
    end

    # make sure the inherited classes inherit the <tt>_decl_rels</tt> hash
    def inherited(klass)
      klass.instance_variable_set(:@associations, associations.clone)

      super
    end

    def has_many(direction, name, options = {})
      name = name.to_sym
      association = Neo4j::ActiveNode::HasN::Association.new(:has_many, direction, name, options)
      @associations ||= {}
      @associations[name] = association

      target_class_name = association.target_class_name || 'nil'
      create_reflection(:has_many, name, association)


      create_reflection(:has_many, name, association)
      Neo4j::ActiveNode::HasN::AutosaveAssociation::AssociationBuilderExtension.build(self, self.reflect_on_association(name))

      # TODO: Make assignment more efficient? (don't delete nodes when they are being assigned)
      module_eval(%Q{
        def #{name}(node = nil, rel = nil)
          return [].freeze unless self.persisted?
          Neo4j::ActiveNode::Query::QueryProxy.new(#{target_class_name},
                                                   self.class.associations[#{name.inspect}],
                                                   {
                                                     session: self.class.neo4j_session,
                                                     start_object: self,
                                                     node: node,
                                                     rel: rel,
                                                     context: '#{self.name}##{name}',
                                                     caller: self
                                                   })
          end

          def #{name}=(other_nodes)
            #{name}(nil, :r).query_as(:n).delete(:r).exec
            clear_association_cache
            other_nodes.each do |node|
              #{name} << node
            end
          end

          def #{name}_rels
            #{name}(nil, :r).pluck(:r)
          end}, __FILE__, __LINE__)

        instance_eval(%Q{
          def #{name}(node = nil, rel = nil, proxy_obj = nil)
            query_proxy = proxy_obj || Neo4j::ActiveNode::Query::QueryProxy.new(#{self.name}, nil, { 
                  session: self.neo4j_session, query_proxy: nil, context: '#{self.name}' + '##{name}'
                })
            context = (query_proxy && query_proxy.context ? query_proxy.context : '#{self.name}') + '##{name}'
            Neo4j::ActiveNode::Query::QueryProxy.new(#{target_class_name},
                                                     @associations[#{name.inspect}],
                                                     {
                                                       session: self.neo4j_session,
                                                       query_proxy: query_proxy,
                                                       node: node,
                                                       rel: rel,
                                                       context: context,
                                                       caller: query_proxy.caller
                                                     })
          end}, __FILE__, __LINE__)
      end

      def has_one(direction, name, options = {})
        name = name.to_sym

        association = Neo4j::ActiveNode::HasN::Association.new(:has_one, direction, name, options)
        @associations ||= {}
        @associations[name] = association

        target_class_name = association.target_class_name || 'nil'
        create_reflection(:has_one, name, association)

        module_eval(%Q{
          def #{name}=(other_node)
            raise(Neo4j::ActiveNode::HasN::NonPersistedNodeError, 'Unable to create relationship with non-persisted nodes') unless self.persisted?
            #{name}_query_proxy(rel: :r).query_as(:n).delete(:r).exec
            clear_association_cache
            #{name}_query_proxy << other_node
          end

          def #{name}_query_proxy(options = {})
            self.class.#{name}_query_proxy({start_object: self}.merge(options))
          end

          def #{name}_rel
            #{name}_query_proxy(rel: :r).pluck(:r).first
          end

          def #{name}(node = nil, rel = nil)
            return nil unless self.persisted?
            #{name}_query_proxy(node: node, rel: rel, context: '#{self.name}##{name}').first
          end}, __FILE__, __LINE__)

        instance_eval(%Q{
          def #{name}_query_proxy(options = {})
            Neo4j::ActiveNode::Query::QueryProxy.new(#{target_class_name},
                                                     @associations[#{name.inspect}],
                                                     {session: self.neo4j_session}.merge(options))
          end

          def #{name}(node = nil, rel = nil, query_proxy = nil)
            context = (query_proxy && query_proxy.context ? query_proxy.context : '#{self.name}') + '##{name}'
            #{name}_query_proxy(query_proxy: query_proxy, node: node, rel: rel, context: context)
          end}, __FILE__, __LINE__)
      end
    end
  end

end
