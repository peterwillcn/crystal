module Crystal
  class ASTNode
    attr_accessor :type
    attr_accessor :dependencies
    attr_accessor :type_filters
    attr_accessor :freeze_type
    attr_accessor :observers

    def set_type(type)
      if @freeze_type && !@type.is_restriction_of_all?(type)
        raise "type must be #{@type}, not #{type}", nil, Crystal::FrozenTypeException
      end
      @type = type
    end

    def type=(type)
      return if type.nil? || @type.type_id == type.type_id

      set_type(type)
      notify_observers
    end

    def map_type(type)
      type
    end

    def bind_to(*nodes)
      @dependencies ||= []
      @dependencies.concat nodes
      nodes.each { |node| node.add_observer self }

      if @dependencies.length == 1
        new_type = nodes[0].type
      else
        new_type = Type.merge *@dependencies.map(&:type)
      end
      return if @type.type_id == new_type.type_id
      set_type(map_type(new_type))
      @dirty = true
      propagate
    end

    def unbind_from(*nodes)
      return unless @dependencies

      nodes.each do |node|
        idx = @dependencies.index { |d| d.equal?(node) }
        @dependencies.delete_at(idx) if idx
        node.remove_observer self
      end
    end

    def add_observer(observer, func = :update)
      @observers ||= []
      @observers << [observer, func]
    end

    def remove_observer(observer)
      return unless @observers
      idx = @observers.index { |o| o.equal?(observer) }
      @observers.delete_at(idx) if idx
    end

    def notify_observers
      return unless @observers
      @observers.each do |observer, func|
        observer.send func, self
      end
      @observers.each do |observer, func|
        observer.propagate
      end
    end

    def update(from)
      return if !from.type || @type.equal?(from.type)

      if @type.nil? || dependencies.length == 1
        new_type = from.type
      else
        new_type = Type.merge *@dependencies.map(&:type)
      end

      return if @type.type_id == new_type.type_id
      set_type(map_type new_type)
      @dirty = true
    end

    def propagate
      if @dirty
        @dirty = false
        notify_observers
      end
    end

    def raise(message, inner = nil, exception_type = Crystal::TypeException)
      Kernel::raise exception_type.for_node(self, message, inner)
    end
  end

  class PointerOf
    attr_accessor :mod

    def map_type(type)
      mod.pointer_of(type)
    end
  end

  class TypeMerge
    def map_type(type)
      type.metaclass
    end

    def update(*)
      super
      propagate
    end
  end

  class FunLiteral
    attr_accessor :mod

    def update(from)
      types = self.def.args.map(&:type)
      types.push self.def.body.type

      unless types.any?(&:nil?)
        self.type = mod.fun_of(*types)
      end
    end
  end

  class NewGenericClass
    attr_accessor :instance_type

    def update(*)
      generic_type = instance_type.instantiate(type_vars.map do |var|
        self.raise "can't deduce generic type in recursive method" unless var.type
        var.type.instance_type
      end)
      self.type = generic_type.metaclass
    end
  end
end
