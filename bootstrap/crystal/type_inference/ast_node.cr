require "../ast"

module Crystal
  class ASTNode
    property! dependencies
    property type_filters
    property freeze_type
    property observers
    property input_observers

    def set_type(type : Type)
      if @freeze_type
        if (my_type = @type) && !my_type.is_restriction_of_all?(type)
          raise "type must be #{my_type}, not #{type}", nil, Crystal::FrozenTypeException
        end
      end
      @type = type
    end

    def set_type(type : Nil)
      @type = type
    end

    def type=(type)
      return if type.nil? || @type.object_id == type.object_id

      set_type(type)
      notify_observers
      @type
    end

    def map_type(type)
      type
    end

    def bind_to(node)
      bind_to [node] of ASTNode
    end

    def bind_to(nodes : Array)
      dependencies = @dependencies ||= [] of ASTNode
      dependencies.concat nodes
      nodes.each &.add_observer self

      if dependencies.length == 1
        new_type = nodes[0].type?
      else
        new_type = Type.merge dependencies
      end
      return if @type.object_id == new_type.object_id
      return unless new_type

      set_type(map_type(new_type))
      @dirty = true
      propagate
    end

    def unbind_from(nodes : Nil)
      # Nothing to do
    end

    def unbind_from(nodes)
      @dependencies.try do |dependencies|
        nodes.each do |node|
          dependencies.delete_if &.same?(node)
          node.remove_observer self
        end
      end
    end

    def add_observer(observer)
      @observers ||= [] of ASTNode
      @observers << observer
    end

    def add_input_observer(observer)
      @input_observers ||= [] of Call
      @input_observers << observer
    end

    def remove_observer(observer)
      @observers.try &.delete_if &.same?(observer)
    end

    def notify_observers
      @observers.try &.each do |observer|
        observer.update self
      end

      @input_observers.try &.each do |observer|
        observer.update_input self
      end

      @observers.try &.each do |observer|
        observer.propagate
      end

      @input_observers.try &.each do |observer|
        observer.propagate
      end
    end

    def update(from)
      return if @type.object_id == from.type.object_id

      if dependencies.length == 1 || !@type
        new_type = from.type?
      else
        new_type = Type.merge dependencies
      end

      return if @type.object_id == new_type.object_id
      return unless new_type

      set_type(map_type(new_type))
      @dirty = true
    end

    def propagate
      if @dirty
        @dirty = false
        notify_observers
      end
    end

    def raise(message, inner = nil, exception_type = Crystal::TypeException)
      ::raise exception_type.for_node(self, message, inner)
    end
  end

  class PointerOf
    property! mod

    def map_type(type)
      mod.pointer_of(type)
    end
  end

  class TypeMerge
    def map_type(type)
      type.metaclass
    end

    def update(from = nil)
      super
      propagate
    end
  end

  class NewGenericClass
    property! instance_type

    def update(from = nil)
      generic_type = instance_type.instantiate(type_vars.map do |var|
        var_type = var.type
        self.raise "can't deduce generic type in recursive method" unless var_type
        var_type.instance_type
      end)
      self.type = generic_type.metaclass
    end
  end
end
