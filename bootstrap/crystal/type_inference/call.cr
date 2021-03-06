require "../ast"
require "../types"
require "../primitives"

module Crystal
  class Call
    property! mod
    property! scope
    property! parent_visitor
    property target_defs
    property target_macro

    def target_def
      # TODO: fix
      if (defs = @target_defs)
        if defs.length == 1
          return defs[0]
        else
          ::raise "#{defs.length} target defs for #{self}"
        end
      end

      ::raise "Zero target defs for #{self}"
    end

    def update_input(from)
      recalculate
    end

    def recalculate
      obj = @obj

      if obj && (obj_type = obj.type?) && obj_type.is_a?(LibType)
        recalculate_lib_call(obj_type)
        return
      end

      return unless obj_and_args_types_set?

      # elsif !obj || (obj.type && !obj.type.is_a?(LibType))
      #   check_not_lib_out_args
      # end

      # Ignore extra recalculations when more than one argument changes at the same time
      # types_signature = args.map { |arg| arg.type.type_id }
      # types_signature << obj.type.type_id if obj
      # return if @types_signature == types_signature
      # @types_signature = types_signature

      unbind_from @target_defs if @target_defs
      # unbind_from block.break if block
      # @subclass_notifier.remove_subclass_observer(self) if @subclass_notifier

      @target_defs = nil

      # if obj
      #   if obj.type.is_a?(UnionType)
      #     matches = []
      #     obj.type.each do |type|
      #       matches.concat lookup_matches_in(type)
      #     end
      #   else
      #     matches = lookup_matches_in(obj.type)
      #   end
      # else
      #   if name == 'super'
      #     matches = lookup_matches_in_super
      #   else
          # matches = lookup_matches_in(scope) || lookup_matches_in(mod)
      #   end
      # end

      if obj
        matches = lookup_matches_in(obj.type)
      else
        matches = lookup_matches_in scope
      end

      # If @target_defs is set here it means there was a recalculation
      # fired as a result of a recalculation. We keep the last one.

      return if @target_defs

      @target_defs = matches

      bind_to matches if matches

      # bind_to *matches
      # bind_to block.break if block

      # if parent_visitor && parent_visitor.typed_def && matches.any?(&:raises)
      #   parent_visitor.typed_def.raises = true
      # end
    end

    def lookup_matches_in(owner : UnionType)
      owner.union_types.flat_map { |type| lookup_matches_in(type) }
    end

    def lookup_matches_in(owner : Type, self_type = owner, def_name = self.name)
      arg_types = args.map &.type
      matches = owner.lookup_matches(def_name, arg_types, !!block)

      if matches.empty?
        if def_name == "new" && owner.metaclass? && owner.instance_type.class?
            #|| owner.instance_type.hierarchy?) # && !owner.instance_type.pointer?
          new_matches = define_new owner, arg_types
          matches = new_matches unless new_matches.empty?
        else
          unless owner == mod
            mod_matches = mod.lookup_matches(def_name, arg_types, !!block)
            matches = mod_matches unless obj || mod_matches.empty?
          end
        end
      end

      if matches.empty?
        raise_matches_not_found(matches.owner || owner, def_name, matches)
      end

      block = @block

      matches.map do |match|
        yield_vars = match_block_arg(match)
        use_cache = !block || match.def.block_arg
        block_type = block && block.body && match.def.block_arg ? block.body.type : nil
        match_owner = match.owner
        typed_def = match_owner.lookup_def_instance(match.def.object_id, match.arg_types, block_type) if use_cache
        unless typed_def
          prepared_typed_def = prepare_typed_def_with_args(match.def, owner, match_owner, match.arg_types)
          typed_def = prepared_typed_def.typed_def
          typed_def_args = prepared_typed_def.args
          match_owner.add_def_instance(match.def.object_id, match.arg_types, block_type, typed_def) if use_cache
          if typed_def.body
            bubbling_exception do
              visitor = TypeVisitor.new(mod, typed_def_args, match_owner, parent_visitor, self, owner, match.def, typed_def, match.arg_types, match.free_vars, yield_vars)
              typed_def.body.accept visitor
            end
          end
        end
        typed_def
      end
    end

    def lookup_matches_in(owner : Nil)
      raise "Bug: trying to lookup matches in nil in #{self}"
    end

    def recalculate_lib_call(obj_type)
      old_target_defs = @target_defs

      untyped_def = obj_type.lookup_first_def(name, false) #or
      raise "undefined fun '#{name}' for #{obj_type}" unless untyped_def

      check_args_length_match obj_type, untyped_def
      # check_lib_out_args untyped_def
      return unless obj_and_args_types_set?

      check_fun_args_types_match obj_type, untyped_def

      untyped_defs = [untyped_def]
      @target_defs = untyped_defs

      # self.unbind_from *old_target_defs if old_target_defs
      self.bind_to untyped_defs
    end

    def match_block_arg(match)
      yield_vars = nil

      if (block_arg = match.def.block_arg)
        if (yields = match.def.yields) && yields > 0
          block = @block.not_nil!
          ident_lookup = IdentLookupVisitor.new(mod, match)

          if inputs = block_arg.type_spec.inputs
            yield_vars = [] of Var
            inputs.each_with_index do |input, i|
              type = lookup_node_type(ident_lookup, input)
              # type = type.hierarchy_type if type.class? && type.abstract
              yield_vars << Var.new("var#{i}", type)
            end
            block.args.each_with_index do |arg, i|
              var = yield_vars[i]?
              arg.bind_to(var || mod.nil_var)
            end
          else
            block.args.each &.bind_to(mod.nil_var)
          end

          block.accept parent_visitor

          if output = block_arg.type_spec.output
            block_type = block.body.type
            type_lookup = match.type_lookup
            assert_type type_lookup, MatchesLookup

            matched = type_lookup.match_arg(block_type, output, match.owner, match.owner, match.free_vars)
            unless matched
              if output.is_a?(SelfType)
                raise "block expected to return #{match.owner}, not #{block_type}"
              else
                raise "block expected to return #{output}, not #{block_type}"
              end
            end
            block.body.freeze_type = true
          end
        end
      end

      yield_vars
    end

    def lookup_node_type(visitor, node)
      node.accept visitor
      visitor.type
    end

    class IdentLookupVisitor < Visitor
      getter! type

      def initialize(@mod, @match)
      end

      def visit(node : ASTNode)
        true
      end

      def visit(node : Ident)
        if node.names.length == 1 && @match.free_vars
          if type = @match.free_vars[node.names.first]?
            @type = type
            return
          end
        end

        @type = (node.global ? @mod : @match.type_lookup).lookup_type(node.names)

        unless @type
          node.raise("uninitialized constant #{node}")
        end
      end

      def visit(node : NewGenericClass)
        node.name.accept self

        instance_type = @type.not_nil!
        unless instance_type.is_a?(GenericClassType)
          node.raise "#{instance_type} is not a generic class, it's a #{instance_type.type_desc}"
        end

        if instance_type.type_vars.length != node.type_vars.length
          node.raise "wrong number of type vars for #{instance_type} (#{node.type_vars.length} for #{instance_type.type_vars.length})"
        end

        type_vars = [] of Type
        node.type_vars.each do |type_var|
          type_var.accept self
          type_vars.push @type.not_nil!
        end

        @type = instance_type.instantiate(type_vars)
        false
      end

      def visit(node : SelfType)
        @type = @match.owner
        false
      end
    end

    def bubbling_exception
      begin
        yield
      rescue ex : Crystal::Exception
        if obj = @obj
          raise "instantiating '#{obj.type}##{name}(#{args.map(&.type).join ", "})'", ex
        else
          raise "instantiating '#{name}(#{args.map(&.type).join ", "})'", ex
        end
      end
    end

    def check_args_length_match(obj_type, untyped_def : External)
      call_args_count = args.length
      all_args_count = untyped_def.args.length

      if untyped_def.varargs && call_args_count >= all_args_count
        return
      end

      required_args_count = untyped_def.args.count { |arg| !arg.default_value }

      return if required_args_count <= call_args_count && call_args_count <= all_args_count

      raise "wrong number of arguments for '#{full_name(obj_type)}' (#{args.length} for #{untyped_def.args.length})"
    end

    def check_args_length_match(obj_type, untyped_def : Def)
      raise "Bug: shouldn't check args length for Def here"
    end

    def check_fun_args_types_match(obj_type, typed_def)
      string_conversions = nil
      # nil_conversions = nil
      # fun_conversions = nil
      typed_def.args.each_with_index do |typed_def_arg, i|
        expected_type = typed_def_arg.type
        self_arg = self.args[i]
        actual_type = self_arg.type
        # actual_type = mod.pointer_of(actual_type) if self.args[i].out?
        if actual_type != expected_type
          # if actual_type.nil_type? && expected_type.pointer?
          #   nil_conversions ||= []
          #   nil_conversions << i
          if (actual_type == mod.string || actual_type == mod.string.hierarchy_type) && (expected_type.is_a?(PointerInstanceType) && expected_type.var.type == mod.char)
            string_conversions ||= [] of Int32
            string_conversions << i
          # elsif expected_type.fun_type? && actual_type.fun_type? && expected_type.return_type.equal?(@mod.void) && expected_type.arg_types == actual_type.arg_types
          #   fun_conversions ||= []
          #   fun_conversions << i
          else
            arg_name = typed_def_arg.name.length > 0 ? "'#{typed_def_arg.name}'" : "##{i + 1}"
            self_arg.raise "argument #{arg_name} of '#{full_name(obj_type)}' must be #{expected_type}, not #{actual_type}"
          end
        end
      end

      # if typed_def.varargs
      #   typed_def.args.length.upto(args.length - 1) do |i|
      #     if mod.string.equal?(self.args[i].type)
      #       string_conversions ||= []
      #       string_conversions << i
      #     end
      #   end
      # end

      if string_conversions
        string_conversions.each do |i|
          call = Call.new(self.args[i], "cstr")
          call.mod = mod
          call.scope = scope
          call.parent_visitor = parent_visitor
          call.recalculate
          self.args[i] = call
        end
      end

      # if nil_conversions
      #   nil_conversions.each do |i|
      #     self.args[i] = NilPointer.new(typed_def.args[i].type)
      #   end
      # end

      # if fun_conversions
      #   fun_conversions.each do |i|
      #     self.args[i] = CastFunToReturnVoid.new(self.args[i])
      #   end
      # end
    end

    def obj_and_args_types_set?
      obj = @obj
      block_arg = @block_arg
      args.all?(&.type?) && (obj ? obj.type? : true) && (block_arg ? block_arg.type? : true)
    end

    def raise_matches_not_found(owner : CStructType, def_name, matches = nil)
      raise_struct_or_union_field_not_found owner, def_name
    end

    def raise_matches_not_found(owner : CUnionType, def_name, matches = nil)
      raise_struct_or_union_field_not_found owner, def_name
    end

    def raise_struct_or_union_field_not_found(owner, def_name)
      if def_name.ends_with?('=')
        def_name = def_name[0 .. -2]
      end

      var = owner.vars[def_name]?
      if var
        args[0].raise "field '#{def_name}' of #{owner.type_desc} #{owner} has type #{var.type}, not #{args[0].type}"
      else
        raise "#{owner.type_desc} #{owner} has no field '#{def_name}'"
      end
    end

    def raise_matches_not_found(owner, def_name, matches = nil)
      defs = owner.lookup_defs(def_name)
      if defs.empty?
        if obj || !owner.is_a?(Program)
          error_msg = "undefined method '#{name}' for #{owner}"
          # similar_name = owner.lookup_similar_defs(def_name, self.args.length, !!block)
          # error_msg << " \033[1;33m(did you mean '#{similar_name}'?)\033[0m" if similar_name
          raise error_msg#, owner_trace
        elsif args.length > 0 || has_parenthesis
          raise "undefined method '#{name}'"#, owner_trace
        else
          raise "undefined local variable or method '#{name}'"#, owner_trace
        end
      end

      defs_matching_args_length = defs.select { |a_def| a_def.args.length == self.args.length }
      if defs_matching_args_length.empty?
        all_arguments_lengths = defs.map { |a_def| a_def.args.length }.uniq!
        raise "wrong number of arguments for '#{full_name(owner)}' (#{args.length} for #{all_arguments_lengths.join ", "})"
      end

      if defs_matching_args_length.length > 0
        if block && defs_matching_args_length.all? { |a_def| !a_def.yields }
          raise "'#{full_name(owner)}' is not expected to be invoked with a block, but a block was given"
        elsif !block && defs_matching_args_length.all?(&.yields)
          raise "'#{full_name(owner)}' is expected to be invoked with a block, but no block was given"
        end
      end

      arg_names = [] of Array(String)

      message = String.build do |msg|
        msg << "no overload matches '#{full_name(owner)}'"
        msg << " with types #{args.map(&.type).join ", "}" if args.length > 0
        msg << "\n"
        msg << "Overloads are:"
        defs.each do |a_def|
          arg_names.push a_def.args.map(&.name)

          msg << "\n - #{full_name(owner)}("
          a_def.args.each_with_index do |arg, i|
            msg << ", " if i > 0
            msg << arg.name
            if arg_type = arg.type?
              msg << " : "
              msg << arg_type
            elsif res = arg.type_restriction
              msg << " : "
              if owner.is_a?(GenericClassInstanceType) && res.is_a?(Ident) && res.names.length == 1
                if type_var = owner.type_vars[res.names[0]]?
                  msg << type_var.type
                else
                  msg << arg.type_restriction
                end
              else
                msg << arg.type_restriction
              end
            end
          end

          msg << ", &block" if a_def.yields
          msg << ")"
        end

        if matches
          cover = matches.cover
          if cover.is_a?(Cover)
            missing = cover.missing
            uniq_arg_names = arg_names.uniq!
            uniq_arg_names = uniq_arg_names.length == 1 ? uniq_arg_names.first : nil
            unless missing.empty?
              msg << "\nCouldn't find overloads for these types:"
              missing.each_with_index do |missing_types|
                if uniq_arg_names
                  msg << "\n - #{full_name(owner)}(#{missing_types.map_with_index { |missing_type, i| "#{uniq_arg_names[i]} : #{missing_type}" }.join ", "}"
                else
                  msg << "\n - #{full_name(owner)}(#{missing_types.join ", "}"
                end
                msg << ", &block" if block
                msg << ")"
              end
            end
          end
        end
      end

      raise message
    end


    def full_name(owner)
      owner.is_a?(Program) ? name : "#{owner}##{name}"
    end

    def define_new(scope, arg_types)
      # if scope.instance_type.hierarchy?
      #   matches = define_new_recursive(scope.instance_type.base_type, arg_types)
      #   return Matches.new(matches, scope)
      # end

      matches = scope.instance_type.lookup_matches("initialize", arg_types, !!block)
      if matches.empty?
        define_new_without_initialize(scope, arg_types)
      else
        define_new_with_initialize(scope, arg_types, matches)
      end
    end

    def define_new_without_initialize(scope, arg_types)
      defs = scope.instance_type.lookup_defs("initialize")
      if defs.length > 0
        raise_matches_not_found scope.instance_type, "initialize"
      end

      if defs.length == 0 && arg_types.length > 0
        raise "wrong number of arguments for '#{full_name(scope.instance_type)}' (#{self.args.length} for 0)"
      end

      alloc = Call.new(nil, "allocate")

      match_def = Def.new("new", [] of Arg, [alloc] of ASTNode)
      match = Match.new(scope, match_def, scope, arg_types)

      scope.add_def match_def

      Matches.new([match], true)
    end

    def define_new_with_initialize(scope, arg_types, matches)
      ms = matches.map do |match|
        if match.free_vars.empty?
          alloc = Call.new(nil, "allocate")
        else
          generic_class = scope.instance_type
          assert_type generic_class, GenericClassType

          type_vars = Array(ASTNode?).new(generic_class.type_vars.length, nil)
          match.free_vars.each do |name, type|
            idx = generic_class.type_vars.index(name)
            if idx
              type_vars[idx] = Ident.new([name])
            end
          end

          if type_vars.all?
            not_nil_type_vars = Array(ASTNode).new(generic_class.type_vars.length)
            type_vars.each do |type_var|
              not_nil_type_vars.push type_var.not_nil!
            end

            new_generic = NewGenericClass.new(Ident.new([generic_class.name]), not_nil_type_vars)
            alloc = Call.new(new_generic, "allocate")
          else
            alloc = Call.new(nil, "allocate")
          end
        end

        var = Var.new("x")
        new_vars = Array(ASTNode).new(args.length)
        args.each_with_index do |arg, i|
          new_vars.push Var.new("arg#{i}")
        end

        new_args = Array(Arg).new(args.length)
        args.each_with_index do |arg, i|
          arg = Arg.new("arg#{i}")
          arg.type_restriction = match.def.args[i]?.try &.type_restriction
          new_args.push arg
        end

        init = Call.new(var, "initialize", new_vars)

        match_def = Def.new("new", new_args, [
          Assign.new(var, alloc),
          init,
          var
        ])

        new_match = Match.new(scope, match_def, match.type_lookup, match.arg_types, match.free_vars)

        scope.add_def match_def

        new_match
      end
      Matches.new(ms, true)
    end

    class PreparedTypedDef
      getter :typed_def
      getter :args

      def initialize(@typed_def, @args)
      end
    end

    def prepare_typed_def_with_args(untyped_def, owner, self_type, arg_types)
      args_start_index = 0

      typed_def = untyped_def.clone
      typed_def.owner = self_type

      if body = typed_def.body
        typed_def.bind_to body
      end

      args = {} of String => Var

      if self_type.is_a?(Type)
        args["self"] = Var.new("self", self_type)
      end

      0.upto(self.args.length - 1) do |index|
        arg = typed_def.args[index]
        type = arg_types[args_start_index + index]
        var = Var.new(arg.name, type)
        var.location = arg.location
        var.bind_to(var)
        args[arg.name] = var
        arg.type = type
      end

      PreparedTypedDef.new(typed_def, args)
    end

  end
end
