require "parser"
require "type_inference"
require "visitor"
require "llvm"
require "codegen/*"
require "program"

LLVM.init_x86

module Crystal
  DUMP_LLVM = ENV["DUMP"] == "1"
  MAIN_NAME = "__crystal_main"

  class Program
    def run(code)
      node = Parser.parse(code)
      node = normalize node
      node = infer_type node
      evaluate node
    end

    def evaluate(node)
      llvm_mod = build node
      engine = LLVM::JITCompiler.new(llvm_mod)

      argc = LibLLVM.create_generic_value_of_int(LLVM::Int32, 0_u64, 1)
      argv = LibLLVM.create_generic_value_of_pointer(nil)

      engine.run_function llvm_mod.functions[MAIN_NAME], [argc, argv]
    end

    def build(node)
      visitor = CodeGenVisitor.new(self, node)
      begin
        node.accept visitor
        visitor.finish
      rescue ex
        visitor.llvm_mod.dump
        raise ex
      end
      visitor.llvm_mod.dump if Crystal::DUMP_LLVM
      visitor.llvm_mod

    end
  end

  class LLVMVar
    getter pointer
    getter type
    getter treated_as_pointer

    def initialize(@pointer, @type, @treated_as_pointer = false)
    end
  end

  class CodeGenVisitor < Visitor
    getter :llvm_mod
    getter :fun
    getter :builder
    getter :typer
    getter :main
    getter! :type

    def initialize(@mod, @node)
      @llvm_mod = LLVM::Module.new("Crystal")
      @main_mod = @llvm_mod
      @llvm_typer = LLVMTyper.new
      @main_ret_type = node.type
      ret_type = @llvm_typer.llvm_type(node.type)
      @fun = @llvm_mod.functions.add(MAIN_NAME, [LLVM::Int32, LLVM.pointer_type(LLVM.pointer_type(LLVM::Int8))], ret_type)
      @main = @fun

      @argc = @fun.get_param(0)
      LLVM.set_name @argc, "argc"

      @argv = @fun.get_param(1)
      LLVM.set_name @argv, "argv"

      builder = LLVM::Builder.new
      @builder = CrystalLLVMBuilder.new builder, self
      @alloca_block, @const_block, @entry_block = new_entry_block_chain ["alloca", "const", "entry"]
      @const_block_entry = @const_block
      @vars = {} of String => LLVMVar
      @lib_vars = {} of String => LibLLVM::ValueRef
      @strings = {} of String => LibLLVM::ValueRef
      @type = @mod
      @last = llvm_nil
      @in_const_block = false
      @block_context = [] of BlockContext
      # @return_union = llvm_nil
    end

    def finish
      br_block_chain [@alloca_block, @const_block_entry]
      br_block_chain [@const_block, @entry_block]

      return_from_fun nil, @main_ret_type
    end

    def visit(node : FunDef)
      unless node.external.dead
        codegen_fun node.real_name, node.external, nil, true
      end

      false
    end

    # Can only happen in a Const
    def visit(node : Primitive)
      @last = case node.name
              when :argc
                @argc
              when :argv
                @argv
              when :float32_infinity
                LLVM.float(Float32::INFINITY)
              when :float64_infinity
                LLVM.double(Float64::INFINITY)
              else
                raise "Bug: unhandled primitive in codegen: #{node.name}"
              end
    end

    def codegen_primitive(node, target_def, call_args)
      @last = case node.name
              when :binary
                codegen_primitive_binary node, target_def, call_args
              when :cast
                codegen_primitive_cast node, target_def, call_args
              when :allocate
                codegen_primitive_allocate node, target_def, call_args
              when :pointer_malloc
                codegen_primitive_pointer_malloc node, target_def, call_args
              when :pointer_set
                codegen_primitive_pointer_set node, target_def, call_args
              when :pointer_get
                codegen_primitive_pointer_get node, target_def, call_args
              when :pointer_address
                codegen_primitive_pointer_address node, target_def, call_args
              when :pointer_new
                codegen_primitive_pointer_new node, target_def, call_args
              when :pointer_realloc
                codegen_primitive_pointer_realloc node, target_def, call_args
              when :pointer_add
                codegen_primitive_pointer_add node, target_def, call_args
              when :pointer_cast
                codegen_primitive_pointer_cast node, target_def, call_args
              when :byte_size
                codegen_primitive_byte_size node, target_def, call_args
              when :struct_new
                codegen_primitive_struct_new node, target_def, call_args
              when :struct_set
                codegen_primitive_struct_set node, target_def, call_args
              when :struct_get
                codegen_primitive_struct_get node, target_def, call_args
              when :union_new
                codegen_primitive_union_new node, target_def, call_args
              when :union_set
                codegen_primitive_union_set node, target_def, call_args
              when :union_get
                codegen_primitive_union_get node, target_def, call_args
              when :external_var_set
                codegen_primitive_external_var_set node, target_def, call_args
              when :external_var_get
                codegen_primitive_external_var_get node, target_def, call_args
              when :object_id
                codegen_primitive_object_id node, target_def, call_args
              when :math_sqrt_float32
                codegen_primitive_math_sqrt_float32 node, target_def, call_args
              when :math_sqrt_float64
                codegen_primitive_math_sqrt_float64 node, target_def, call_args
              else
                raise "Bug: unhandled primitive in codegen: #{node.name}"
              end
    end

    def codegen_primitive_binary(node, target_def, call_args)
      p1, p2 = call_args
      t1, t2 = target_def.owner, target_def.args[0].type
      codegen_binary_op target_def.name, t1, t2, p1, p2
    end

    def codegen_binary_op(op, t1 : BoolType, t2 : BoolType, p1, p2)
      case op
      when "==" then @builder.icmp LibLLVM::IntPredicate::EQ, p1, p2
      when "!=" then @builder.icmp LibLLVM::IntPredicate::NE, p1, p2
      else raise "Bug: trying to codegen #{t1} #{op} #{t2}"
      end
    end

    def codegen_binary_op(op, t1 : CharType, t2 : CharType, p1, p2)
      case op
      when "==" then return @builder.icmp LibLLVM::IntPredicate::EQ, p1, p2
      when "!=" then return @builder.icmp LibLLVM::IntPredicate::NE, p1, p2
      when "<" then return @builder.icmp LibLLVM::IntPredicate::ULT, p1, p2
      when "<=" then return @builder.icmp LibLLVM::IntPredicate::ULE, p1, p2
      when ">" then return @builder.icmp LibLLVM::IntPredicate::UGT, p1, p2
      when ">=" then return @builder.icmp LibLLVM::IntPredicate::UGT, p1, p2
      else raise "Bug: trying to codegen #{t1} #{op} #{t2}"
      end
    end

    def codegen_binary_op(op, t1 : IntegerType, t2 : IntegerType, p1, p2)
      if t1.normal_rank == t2.normal_rank
        # Nothing to do
      elsif t1.rank < t2.rank
        p1 = t1.signed? ? @builder.sext(p1, t2.llvm_type) : @builder.zext(p1, t2.llvm_type)
      else
        p2 = t2.signed? ? @builder.sext(p2, t1.llvm_type) : @builder.zext(p2, t1.llvm_type)
      end

      @last = case op
              when "+" then @builder.add p1, p2
              when "-" then @builder.sub p1, p2
              when "*" then @builder.mul p1, p2
              when "/" then t1.signed? ? @builder.sdiv(p1, p2) : @builder.udiv(p1, p2)
              when "%" then t1.signed? ? @builder.srem(p1, p2) : @builder.urem(p1, p2)
              when "<<" then @builder.shl(p1, p2)
              when ">>" then t1.signed? ? @builder.ashr(p1, p2) : @builder.lshr(p1, p2)
              when "|" then @builder.or(p1, p2)
              when "&" then @builder.and(p1, p2)
              when "^" then @builder.xor(p1, p2)
              when "==" then return @builder.icmp LibLLVM::IntPredicate::EQ, p1, p2
              when "!=" then return @builder.icmp LibLLVM::IntPredicate::NE, p1, p2
              when "<" then return @builder.icmp (t1.signed? ? LibLLVM::IntPredicate::SLT : LibLLVM::IntPredicate::ULT), p1, p2
              when "<=" then return @builder.icmp (t1.signed? ? LibLLVM::IntPredicate::SLE : LibLLVM::IntPredicate::ULE), p1, p2
              when ">" then return @builder.icmp (t1.signed? ? LibLLVM::IntPredicate::SGT : LibLLVM::IntPredicate::UGT), p1, p2
              when ">=" then return @builder.icmp (t1.signed? ? LibLLVM::IntPredicate::SGT : LibLLVM::IntPredicate::UGT), p1, p2
              else raise "Bug: trying to codegen #{t1} #{op} #{t2}"
              end

      if t1.normal_rank != t2.normal_rank  && t1.rank < t2.rank
        @last = @builder.trunc @last, t1.llvm_type
      end

      @last
    end

    def codegen_binary_op(op, t1 : IntegerType, t2 : FloatType, p1, p2)
      p1 = if t1.signed?
            @builder.si2fp(p1, t2.llvm_type)
           else
             @builder.ui2fp(p1, t2.llvm_type)
           end
      codegen_binary_op(op, t2, t2, p1, p2)
    end

    def codegen_binary_op(op, t1 : FloatType, t2 : IntegerType, p1, p2)
      p2 = if t2.signed?
            @builder.si2fp(p2, t1.llvm_type)
           else
             @builder.ui2fp(p2, t1.llvm_type)
           end
      codegen_binary_op op, t1, t1, p1, p2
    end

    def codegen_binary_op(op, t1 : FloatType, t2 : FloatType, p1, p2)
      if t1.rank < t2.rank
        p1 = @builder.fpext(p1, t2.llvm_type)
      elsif t1.rank > t2.rank
        p2 = @builder.fpext(p2, t1.llvm_type)
      end

      @last = case op
              when "+" then @builder.fadd p1, p2
              when "-" then @builder.fsub p1, p2
              when "*" then @builder.fmul p1, p2
              when "/" then @builder.fdiv p1, p2
              when "==" then return @builder.fcmp LibLLVM::RealPredicate::OEQ, p1, p2
              when "!=" then return @builder.fcmp LibLLVM::RealPredicate::ONE, p1, p2
              when "<" then return @builder.fcmp LibLLVM::RealPredicate::OLT, p1, p2
              when "<=" then return @builder.fcmp LibLLVM::RealPredicate::OLE, p1, p2
              when ">" then return @builder.fcmp LibLLVM::RealPredicate::OGT, p1, p2
              when ">=" then return @builder.fcmp LibLLVM::RealPredicate::OGE, p1, p2
              else raise "Bug: trying to codegen #{t1} #{op} #{t2}"
              end

      if t1.rank < t2.rank
        @last = @builder.fptrunc(@last, t1.llvm_type)
      end

      @last
    end

    def codegen_binary_op(op, t1, t2, p1, p2)
      raise "Bug: codegen_binary_op called with #{t1} #{op} #{t2}"
    end

    def codegen_primitive_cast(node, target_def, call_args)
      p1 = call_args[0]
      from_type, to_type = target_def.owner, target_def.type
      codegen_cast from_type, to_type, p1
    end

    def codegen_cast(from_type : IntegerType, to_type : IntegerType, arg)
      if from_type.normal_rank == to_type.normal_rank
        @last
      elsif from_type.rank < to_type.rank
        from_type.signed? ? @builder.sext(arg, to_type.llvm_type) : @builder.zext(arg, to_type.llvm_type)
      else
        @builder.trunc(arg, to_type.llvm_type)
      end
    end

    def codegen_cast(from_type : IntegerType, to_type : FloatType, arg)
      if from_type.signed?
        @builder.si2fp(arg, to_type.llvm_type)
      else
        @builder.ui2fp(arg, to_type.llvm_type)
      end
    end

    def codegen_cast(from_type : FloatType, to_type : IntegerType, arg)
      if to_type.signed?
        @builder.fp2si(arg, to_type.llvm_type)
      else
        @builder.fp2ui(arg, to_type.llvm_type)
      end
    end

    def codegen_cast(from_type : FloatType, to_type : FloatType, arg)
      if from_type.rank < to_type.rank
        @last = @builder.fpext(arg, to_type.llvm_type)
      elsif from_type.rank > to_type.rank
        @last = @builder.fptrunc(arg, to_type.llvm_type)
      end
      @last
    end

    def codegen_cast(from_type : IntegerType, to_type : CharType, arg)
      codegen_cast(from_type, @mod.int8, arg)
    end

    def codegen_cast(from_type : CharType, to_type : IntegerType, arg)
      @builder.zext(arg, to_type.llvm_type)
    end

    def codegen_cast(from_type, to_type, arg)
      raise "Bug: codegen_cast called from #{from_type} to #{to_type}"
    end

    def codegen_primitive_allocate(node, target_def, call_args)
      malloc llvm_struct_type(node.type)
    end

    def codegen_primitive_pointer_malloc(node, target_def, call_args)
      type = node.type
      assert_type type, PointerInstanceType

      llvm_type = llvm_embedded_type(type.var.type)
      @builder.array_malloc(llvm_type, call_args[1])
    end

    def codegen_primitive_pointer_set(node, target_def, call_args)
      value = call_args[1]

      type = @type
      assert_type type, PointerInstanceType

      if node.type.c_struct? || node.type.c_union?
        loaded_value = @builder.load value
        @builder.store loaded_value, call_args[0]
      elsif node.type.union?
        value = @builder.alloca llvm_type(node.type)
        target = call_args[1]
        target = @builder.load(target) if node.type.passed_by_val?
        @builder.store target, value
      end

      codegen_assign call_args[0], type.var.type, node.type, value

      value
    end

    def codegen_primitive_pointer_get(node, target_def, call_args)
      type = @type
      assert_type type, PointerInstanceType

      if type.var.type.union? || type.var.type.c_struct? || type.var.type.c_union?
        @last = call_args[0]
      else
        @builder.load call_args[0]
      end
    end

    def codegen_primitive_pointer_address(node, target_def, call_args)
      @builder.ptr2int call_args[0], LLVM::Int64
    end

    def codegen_primitive_pointer_new(node, target_def, call_args)
      @builder.int2ptr(call_args[1], llvm_type(node.type))
    end

    def codegen_primitive_pointer_realloc(node, target_def, call_args)
      type = @type
      assert_type type, PointerInstanceType

      casted_ptr = cast_to_void_pointer(call_args[0])
      size = call_args[1]
      size = @builder.mul size, llvm_size(type.var.type)
      reallocated_ptr = realloc casted_ptr, size
      @last = cast_to_pointer reallocated_ptr, type.var.type
    end

    def codegen_primitive_pointer_add(node, target_def, call_args)
      @last = @builder.gep call_args[0], [call_args[1]]
    end

    def codegen_primitive_pointer_cast(node, target_def, call_args)
      @last = cast_to call_args[0], node.type
    end

    def codegen_primitive_byte_size(node, target_def, call_args)
      llvm_size(type.instance_type)
    end

    def codegen_primitive_struct_new(node, target_def, call_args)
      struct_type = llvm_struct_type(node.type)
      @last = malloc struct_type
      memset @last, int8(0), LLVM.size_of(struct_type)
      @last
    end

    def codegen_primitive_struct_set(node, target_def, call_args)
      type = @type
      assert_type type, CStructType

      name = target_def.name[0 .. -2]

      ptr = gep call_args[0], 0, type.index_of_var(name)
      @last = call_args[1]
      value = @last
      value = @builder.load @last if node.type.c_struct? || node.type.c_union?
      @builder.store value, ptr
      call_args[1]
    end

    def codegen_primitive_struct_get(node, target_def, call_args)
      type = @type
      assert_type type, CStructType

      name = target_def.name

      var = type.vars[name]
      index = type.index_of_var(name)
      if var.type.c_struct? || var.type.c_union?
        gep call_args[0], 0, index
      else
        struct = @builder.load call_args[0]
        @builder.extract_value struct, index, name
      end
    end

    def codegen_primitive_union_new(node, target_def, call_args)
      struct_type = llvm_struct_type(node.type)
      @last = malloc struct_type
      memset @last, int8(0), LLVM.size_of(struct_type)
      @last
    end

    def codegen_primitive_union_set(node, target_def, call_args)
      type = @type
      assert_type type, CUnionType

      name = target_def.name[0 .. -2]

      var = type.vars[name]
      ptr = gep call_args[0], 0, 0
      casted_value = cast_to_pointer ptr, var.type
      @last = call_args[1]
      @builder.store @last, casted_value
      @last
    end

    def codegen_primitive_union_get(node, target_def, call_args)
      type = @type
      assert_type type, CUnionType

      name = target_def.name

      var = type.vars[name]
      ptr = gep call_args[0], 0, 0
      if var.type.c_struct? || var.type.c_union?
        @last = @builder.bit_cast(ptr, LLVM.pointer_type(llvm_struct_type(var.type)))
      else
        casted_value = cast_to_pointer ptr, var.type
        @last = @builder.load casted_value
      end
    end

    def codegen_primitive_external_var_set(node, target_def, call_args)
      name = target_def.name[0 .. -2]
      var = declare_lib_var name, node.type
      @last = call_args[0]
      @builder.store @last, var
      @last
    end

    def codegen_primitive_external_var_get(node, target_def, call_args)
      name = target_def.name
      var = declare_lib_var name, node.type
      @builder.load var
    end

    def codegen_primitive_object_id(node, target_def, call_args)
      @builder.ptr2int call_args[0], LLVM::Int64
    end

    def codegen_primitive_math_sqrt_float32(node, target_def, call_args)
      @builder.call @mod.sqrt_float32(@llvm_mod), [call_args[1]]
    end

    def codegen_primitive_math_sqrt_float64(node, target_def, call_args)
      @builder.call @mod.sqrt_float64(@llvm_mod), [call_args[1]]
    end

    def visit(node : PointerOf)
      node_var = node.var
      case node_var
      when Var
        var = @vars[node_var.name]
        @last = var.pointer

        node_type = node.type
        assert_type node_type, PointerInstanceType

        @last = @builder.load @last if node_type.var.type.c_struct? || node_type.var.type.c_union?
      when InstanceVar
        type = @type
        assert_type type, InstanceVarContainer

        @last = gep llvm_self_ptr, 0, type.index_of_instance_var(node_var.name)
      else
        raise "Bug: #{node}.ptr"
      end
      false
    end

    def visit(node : ASTNode)
      true
    end

    def visit(node : NumberLiteral)
      case node.kind
      when :i8, :u8
        @last = int8(node.value.to_i)
      when :i16, :u16
        @last = int16(node.value.to_i)
      when :i32, :u32
        @last = int32(node.value.to_i)
      when :i64, :u64
        @last = int64(node.value.to_i64)
      when :f32
        @last = LLVM.float(node.value)
      when :f64
        @last = LLVM.double(node.value)
      end
    end

    def visit(node : BoolLiteral)
      @last = int1(node.value ? 1 : 0)
    end

    def visit(node : LongLiteral)
      @last = int64(node.value.to_i)
    end

    def visit(node : CharLiteral)
      @last = int8(node.value[0].ord)
    end

    def visit(node : StringLiteral)
      @last = build_string_constant(node.value)
    end

    def visit(node : Nop)
      @last = llvm_nil
    end

    def visit(node : NilLiteral)
      @last = llvm_nil
    end

    def visit(node : ClassDef)
      node.body.accept self
      @last = llvm_nil
      false
    end

    def visit(node : ModuleDef)
      node.body.accept self
      @last = llvm_nil
      false
    end

    def visit(node : LibDef)
      @last = llvm_nil
      false
    end

    def visit(node : TypeMerge)
      false
    end

    def visit(node : Include)
      @last = llvm_nil
      false
    end

    def build_string_constant(str, name = "str")
      # name = name.gsub('@', '.')
      @strings[str] ||= begin
        global = @llvm_mod.globals.add(LLVM.array_type(LLVM::Int8, str.length + 5), name)
        LLVM.set_linkage global, LibLLVM::Linkage::Private
        LLVM.set_global_constant global, true

        # Pack the string bytes
        bytes = [] of LibLLVM::ValueRef
        length = str.length
        length_ptr = length.ptr.as(UInt8)
        (0..3).each { |i| bytes << int8(length_ptr[i]) }
        str.each_char { |c| bytes << int8(c.ord) }
        bytes << int8(0)

        LLVM.set_initializer global, LLVM.array(LLVM::Int8, bytes)
        cast_to global, @mod.string
      end
    end

    def cast_to(value, type)
      @builder.bit_cast(value, llvm_type(type))
    end

    def cast_to_pointer(value, type)
      @builder.bit_cast(value, LLVM.pointer_type(llvm_type(type)))
    end

    def cast_to_void_pointer(pointer)
      @builder.bit_cast pointer, LLVM.pointer_type(LLVM::Int8)
    end

    def visit(node : If)
      accept(node.cond)

      then_block, else_block = new_blocks ["then", "else"]
      codegen_cond_branch(node.cond, then_block, else_block)

      branch = new_branched_block(node)

      @builder.position_at_end then_block
      accept(node.then)
      add_branched_block_value(branch, node.then.type, @last)

      @builder.position_at_end else_block
      accept(node.else)
      add_branched_block_value(branch, node.else.type, @last)

      close_branched_block(branch)

      false
    end

    def visit(node : While)
      # old_break_type = @break_type
      # old_break_table = @break_table
      # old_break_union = @break_union
      # @break_type = @break_table = @break_union = nil

      while_block, body_block, exit_block = new_blocks ["while", "body", "exit"]

      @builder.br node.run_once ? body_block : while_block

      @builder.position_at_end while_block

      accept(node.cond)
      codegen_cond_branch(node.cond, body_block, exit_block)

      @builder.position_at_end body_block
      old_while_exit_block = @while_exit_block
      @while_exit_block = exit_block
      accept(node.body)
      @while_exit_block = old_while_exit_block
      @builder.br while_block

      @builder.position_at_end exit_block
      # @builder.unreachable if node.no_returns? || (node.body.yields? && block_breaks?)

      @last = llvm_nil
      # @break_type = old_break_type
      # @break_table = old_break_table
      # @break_union = old_break_union

      false
    end

    def codegen_cond_branch(node_cond, then_block, else_block)
      @builder.cond(codegen_cond(node_cond.type), then_block, else_block)

      nil
    end

    def codegen_cond(type : NilType)
      int1(0)
    end

    def codegen_cond(type : BoolType)
      @last
    end

    def codegen_cond(type : NilableType)
      not_null_pointer?(@last)
    end

    def codegen_cond(type : UnionType)
      has_nil = type.union_types.any? &.nil_type?
      has_bool = type.union_types.any? &.bool_type?

      if has_nil || has_bool
        type_id = @builder.load union_type_id(@last)
        value = @builder.load(@builder.bit_cast union_value(@last), LLVM.pointer_type(LLVM::Int1))

        is_nil = @builder.icmp LibLLVM::IntPredicate::EQ, type_id, int(@mod.nil.type_id)
        is_bool = @builder.icmp LibLLVM::IntPredicate::EQ, type_id, int(@mod.bool.type_id)
        is_false = @builder.icmp(LibLLVM::IntPredicate::EQ, value, int1(0))
        cond = @builder.not(@builder.or(is_nil, @builder.and(is_bool, is_false)))
      elsif has_nil
        type_id = @builder.load union_type_id(@last)
        cond = @builder.icmp LibLLVM::IntPredicate::NE, type_id, int(@mod.nil.type_id)
      elsif has_bool
        type_id = @builder.load union_type_id(@last)
        value = @builder.load(@builder.bit_cast union_value(@last), LLVM.pointer_type(LLVM::Int1))

        is_bool = @builder.icmp LibLLVM::IntPredicate::EQ, type_id, int(@mod.bool.type_id)
        is_false = @builder.icmp(LibLLVM::IntPredicate::EQ, value, int1(0))
        cond = @builder.not(@builder.and(is_bool, is_false))
      else
        cond = int1(1)
      end
    end

    def codegen_cond(type : PointerInstanceType)
      not_null_pointer?(@last)
    end

    def codegen_cond(type : TypeDefType)
      codegen_cond type.typedef
    end

    def codegen_cond(node_cond)
      int1(1)
    end

    abstract class BranchedBlock
      property node
      property count
      property exit_block

      def initialize(@node, @exit_block, @codegen)
        @count = 0
      end
    end

    class UnionBranchedBlock < BranchedBlock
      def initialize(node, exit_block, codegen)
        super
        @union_ptr = @codegen.alloca(@codegen.llvm_type(node.type))
      end

      def add_value(block, type, value)
        @codegen.assign_to_union(@union_ptr, @node.type, type, value)
        @count += 1
      end

      def close
        @union_ptr
      end
    end

    class PhiBranchedBlock < BranchedBlock
      def initialize(node, exit_block, codegen)
        super
        @incoming_blocks = [] of LibLLVM::BasicBlockRef
        @incoming_values = [] of LibLLVM::ValueRef
      end

      def add_value(block, type, value)
        @incoming_blocks << block

        if @node.type.nilable? && LLVM.type_kind_of(LLVM.type_of value) == LibLLVM::TypeKind::Integer
          @incoming_values << @codegen.builder.int2ptr(value, @codegen.llvm_type(node.type))
        else
          @incoming_values << value
        end
        @count += 1
      end

      def close
        # if branch[:count] == 0
        #   @builder.unreachable
        # elsif branch[:phi_table].empty?
        #   # All branches are void or no return
        #   @last = llvm_nil
        # else
        @codegen.builder.phi @codegen.llvm_type(@node.type), @incoming_blocks, @incoming_values
      end
    end

    def new_branched_block(node)
      exit_block = new_block("exit")
      node_type = node.type
      if node_type && node_type.union?
        UnionBranchedBlock.new node, exit_block, self
      else
        PhiBranchedBlock.new node, exit_block, self
      end
    end

    def add_branched_block_value(branch, type, value : LibLLVM::ValueRef)
      if false # !type || type.no_return?
        # @builder.unreachable
      elsif false # type.equal?(@mod.void)
        # Nothing to do
        branch.count += 1
      else
        branch.add_value @builder.insert_block, type, value
        @builder.br branch.exit_block
      end
    end

    def close_branched_block(branch)
      @builder.position_at_end branch.exit_block
      if false # branch.node.returns? || branch.node.no_returns?
        # @builder.unreachable
      else
        @last = branch.close
      end
    end

    def visit(node : Assign)
      codegen_assign_node(node.target, node.value)
    end

    def codegen_assign_node(target, value)
      if target.is_a?(Ident)
        @last = llvm_nil
        return false
      end

      # if target.is_a?(ClassVar) && target.class_scope
      #   global_name = class_var_global_name(target)
      #   in_const_block(global_name) do
      #     accept(value)
      #     llvm_value = @last
      #     ptr = assign_to_global global_name, target.type
      #     codegen_assign(ptr, target.type, value.type, llvm_value)
      #   end
      #   return
      # end

      accept(value)

      # if value.no_returns?
      #   return
      # end

      codegen_assign_target(target, value, @last) if @last

      false
    end

    def codegen_assign_target(target : InstanceVar, value, llvm_value)
      type = @type
      assert_type type, InstanceVarContainer

      ivar = type.lookup_instance_var(target.name)
      index = type.index_of_instance_var(target.name)

      ptr = gep llvm_self_ptr, 0, index
      codegen_assign(ptr, target.type, value.type, llvm_value, true)
    end

    def codegen_assign_target(target : Global, value, llvm_value)
      ptr = get_global target.name, target.type
      codegen_assign(ptr, target.type, value.type, llvm_value)
    end

    def codegen_assign_target(target : ClassVar, value, llvm_value)
      ptr = get_global class_var_global_name(target), target.type
      codegen_assign(ptr, target.type, value.type, llvm_value)
    end

    def codegen_assign_target(target : Var, value, llvm_value)
      var = declare_var(target)
      ptr = var.pointer
      codegen_assign(ptr, target.type, value.type, llvm_value)
    end

    def codegen_assign_target(target, value, llvm_value)
      raise "Unknown assign target in codegen: #{target}"
    end

    def get_global(name, type)
      ptr = @llvm_mod.globals[name]?
      unless ptr
        llvm_type = llvm_type(type)
        ptr = @llvm_mod.globals.add(llvm_type, name)
        LLVM.set_linkage ptr, LibLLVM::Linkage::Internal
        LLVM.set_initializer ptr, LLVM.null(llvm_type)
      end
      ptr
    end

    def class_var_global_name(node)
      "#{node.owner}#{node.var.name.replace('@', ':')}"
    end

    def codegen_assign(pointer, target_type, value_type, value, instance_var = false)
      if target_type == value_type
        value = @builder.load value if target_type.union? || (instance_var && (target_type.c_struct? || target_type.c_union?))
        @builder.store value, pointer
      else
        assign_to_union(pointer, target_type, value_type, value)
      end
      nil
    end

    def assign_to_union(union_pointer, union_type : NilableType, type, value)
      if LLVM.type_kind_of(LLVM.type_of value) == LibLLVM::TypeKind::Integer
        value = @builder.int2ptr value, llvm_type(union_type)
      end
      @builder.store value, union_pointer
      nil
    end

    def assign_to_union(union_pointer, union_type, type, value)
      type_id_ptr, value_ptr = union_type_id_and_value(union_pointer)

      if type.union?
        casted_value = cast_to_pointer value, union_type
        @builder.store @builder.load(casted_value), union_pointer
      elsif type.is_a?(NilableType)
        index = @builder.select null_pointer?(value), int(@mod.nil.type_id), int(type.not_nil_type.type_id)

        @builder.store index, type_id_ptr

        casted_value_ptr = cast_to_pointer value_ptr, type.not_nil_type
        @builder.store value, casted_value_ptr
      else
        index = type.type_id
        @builder.store int32(index), type_id_ptr

        casted_value_ptr = cast_to_pointer value_ptr, type
        @builder.store value, casted_value_ptr
      end
      nil
    end

    def union_type_id_and_value(union_pointer)
      type_id_ptr = union_type_id(union_pointer)
      value_ptr = union_value(union_pointer)
      [type_id_ptr, value_ptr]
    end

    def union_type_id(union_pointer)
      gep union_pointer, 0, 0
    end

    def union_value(union_pointer)
      gep union_pointer, 0, 1
    end

    def visit(node : Var)
      var = @vars[node.name]
      var_type = var.type
      @last = var.pointer
      if var_type == node.type
        @last = @builder.load(@last) unless var.treated_as_pointer || var_type.union?
      elsif var_type.is_a?(NilableType)
        if node.type.nil_type?
          @last = null_pointer?(@last)
        else
          @last = @builder.load(@last) unless var.treated_as_pointer
        end
      elsif node.type.union?
        @last = cast_to_pointer @last, node.type
      else
        value_ptr = union_value(@last)
        @last = cast_to_pointer value_ptr, node.type
        @last = @builder.load(@last) unless node.type.passed_by_val?
      end
    end

    def visit(node : CastedVar)
      var = @vars[node.name]
      var_type = var.type
      @last = var.pointer
      if var_type == @mod.void
        # Nothing to do
      elsif var_type == node.type
        @last = @builder.load(@last) unless (var.treated_as_pointer || var_type.union?)
      elsif var_type.is_a?(NilableType)
        if node.type.nil_type?
          @last = llvm_nil
        elsif node.type == @mod.object
          @last = cast_to @last, @mod.object
      #   elsif node.type.equal?(@mod.object.hierarchy_type)
      #     @last = box_object_in_hierarchy(var.type, node.type, var[:ptr], !var.treated_as_pointer)
        else
          @last = @builder.load(@last, node.name) unless var.treated_as_pointer
          # if node.type.hierarchy?
          #   @last = box_object_in_hierarchy(var.type.nilable_type, node.type, @last, !var.treated_as_pointer)
          # end
        end
      elsif var.type.metaclass?
        # Nothing to do
      elsif node.type.union?
        @last = cast_to_pointer @last, node.type
      else
        value_ptr = union_value(@last)
        casted_value_ptr = cast_to_pointer value_ptr, node.type
        @last = @builder.load(casted_value_ptr)
      end
    end

    def visit(node : Global)
      read_global node.name.to_s, node.type
    end

    def visit(node : ClassVar)
      read_global class_var_global_name(node), node.type
    end

    def read_global(name, type)
      @last = get_global name, type
      @last = @builder.load @last unless type.union?
      @last
    end

    def visit(node : InstanceVar)
      type = @type
      assert_type type, InstanceVarContainer

      ivar = type.lookup_instance_var(node.name)
      if ivar.type.union? || ivar.type.c_struct? || ivar.type.c_union?
        @last = gep llvm_self_ptr, 0, type.index_of_instance_var(node.name)
        unless node.type == ivar.type
          if node.type.union?
            @last = cast_to_pointer @last, node.type
          else
            value_ptr = union_value(@last)
            @last = cast_to_pointer value_ptr, node.type
            @last = @builder.load(@last)
          end
        end
      else
        index = type.index_of_instance_var(node.name)

        struct = @builder.load llvm_self_ptr
        @last = @builder.extract_value struct, index, node.name
      end
    end

    def visit(node : IsA)
      const_type = node.const.type.instance_type
      codegen_type_filter(node) { |type| type.implements?(const_type) }
    end

    def codegen_type_filter(node)
      accept(node.obj)

      obj_type = node.obj.type

      # if obj_type.is_a?(HierarchyType)
      #   codegen_type_filter_many_types(obj_type.subtypes, &block)
      if obj_type.is_a?(UnionType)
        codegen_type_filter_many_types(obj_type.concrete_types) { |type| yield type }
      # elsif obj_type.nilable?
      #   np = null_pointer?(@last)
      #   nil_matches = block.call(@mod.nil)
      #   other_matches = block.call(obj_type.nilable_type)
      #   @last = @builder.or(
      #     @builder.and(np, int1(nil_matches ? 1 : 0)),
      #     @builder.and(@builder.not(np), int1(other_matches ? 1 : 0))
      #   )
      else
        matches = yield obj_type
        # matches = block.call(obj_type)
        @last = int1(matches ? 1 : 0)
      end

      false
    end

    def codegen_type_filter_many_types(types)
      matching_ids = types.select { |t| yield t }.map { |t| int32(t.type_id) }
      case matching_ids.length
      when 0
        @last = int1(0)
      when types.count
        @last = int1(1)
      else
        type_id = @builder.load union_type_id(@last)

        result = nil
        matching_ids.each do |matching_id|
          cmp = @builder.icmp LibLLVM::IntPredicate::EQ, type_id, matching_id
          result = result ? @builder.or(result, cmp) : cmp
        end

        if result
          @last = result
        else
          raise "BUg: matching_ids was empty"
        end
      end
    end

    def declare_var(var)
      @vars[var.name] ||= begin
        llvm_var = LLVMVar.new(alloca(llvm_type(var.type), var.name), var.type)
        # if var.type.is_a?(UnionType) && var.type.types.any?(&:nil_type?)
        #   in_alloca_block { assign_to_union(llvm_var[:ptr], var.type, @mod.nil, llvm_nil) }
        # end
        llvm_var
      end
    end

    def declare_lib_var(name, type)
      unless var = @lib_vars[name]?
        var = @llvm_mod.globals.add(llvm_type(type), name)
        LLVM.set_linkage var, LibLLVM::Linkage::External
        # var.thread_local = true if RUBY_PLATFORM =~ /linux/
        @lib_vars[name] = var
      end
      var
    end

    def visit(node : Def)
      false
    end

    def visit(node : Macro)
      false
    end

    def visit(node : Ident)
      const = node.target_const
      if const
        global_name = const.llvm_name
        global = @llvm_mod.globals[global_name]?

        unless global
          global = @llvm_mod.globals.add(llvm_type(const.value.type), global_name)
          LLVM.set_linkage global, LibLLVM::Linkage::Internal

          if const.value.needs_const_block?
            in_const_block("const_#{global_name}") do
              accept(const.value)

              if LLVM.constant? @last
                LLVM.set_initializer global, @last
                LLVM.set_global_constant global, true
              else
                LLVM.set_initializer global, LLVM.null(LLVM.type_of @last)
                @builder.store @last, global
              end
            end
          else
            accept(const.value)
            LLVM.set_initializer global, @last
            LLVM.set_global_constant global, true
          end
        end

        @last = @builder.load global
      else
        @last = int64(node.type.instance_type.type_id)
      end
      false
    end

    class BlockContext
      getter block
      getter vars
      getter type
      getter return_block
      getter return_block_table_blocks
      getter return_block_table_values
      getter return_type

      def initialize(@block, @vars, @type, @return_block, @return_block_table_blocks, @return_block_table_values, @return_type)
      end
    end

    def visit(node : Yield)
      if @block_context.length > 0
        context = @block_context.pop
        new_vars = context.vars.dup
        block = context.block

        # if node.scope
        #   node.scope.accept self
        #   new_vars['%scope'] = { ptr: @last, type: node.scope.type, treated_as_pointer: false }
        # end

        if block.args
          block.args.each_with_index do |arg, i|
            exp = node.exps[i]?
            if exp
              exp_type = exp.type
              exp.accept self
            else
              exp_type = @mod.nil
              @last = llvm_nil
            end

            copy = alloca llvm_type(arg.type), "block_#{arg.name}"

            codegen_assign copy, arg.type, exp_type, @last
            new_vars[arg.name] = LLVMVar.new(copy, arg.type)
          end
        end

        old_vars = @vars
        old_type = @type
        old_return_block = @return_block
        old_return_block_table_blocks = @return_block_table_blocks
        old_return_block_table_values = @return_block_table_values
        old_return_type = @return_type
        # old_return_union = @return_union
        # old_while_exit_block = @while_exit_block
        # old_break_table = @break_table
        # old_break_type = @break_type
        # old_break_union = @break_union
        # @while_exit_block = @return_block
        # @break_table = @return_block_table
        # @break_type = @return_type
        # @break_union = @return_union
        @vars = new_vars
        @type = context.type
        @return_block = context.return_block
        @return_block_table_blocks = context.return_block_table_blocks
        @return_block_table_values = context.return_block_table_values
        @return_type = context.return_type
        # @return_union = context[:return_union]

        accept(block)

        if !node.type? || node.type.nil_type?
          @last = llvm_nil
        end

        # @while_exit_block = old_while_exit_block
        # @break_table = old_break_table
        # @break_type = old_break_type
        # @break_union = old_break_union
        @vars = old_vars
        @type = old_type
        @return_block = old_return_block
        @return_block_table_blocks = old_return_block_table_blocks
        @return_block_table_values = old_return_block_table_values
        @return_type = old_return_type
        # @return_union = old_return_union
        @block_context << context
      end
      false
    end

    def visit(node : Call)
      target_defs = node.target_defs

      if target_defs && target_defs.length > 1
        codegen_dispatch(node, target_defs)
        return false
      end

      owner = node.target_def.owner

      call_args = [] of LibLLVM::ValueRef

      if (obj = node.obj) && obj.type.passed_as_self?
        accept(obj)
        call_args << @last
      elsif owner && owner.passed_as_self?
        call_args << llvm_self
      end

      node.args.each_with_index do |arg, i|
        accept(arg)
        call_args << @last
      end

      if block = node.block
        # @block_context << { block: node.block, vars: @vars, type: @type,
        #   return_block: @return_block, return_block_table: @return_block_table,
        #   return_type: @return_type, return_union: @return_union }
        @block_context << BlockContext.new(block, @vars, @type, @return_block, @return_block_table_blocks, @return_block_table_values, @return_type)
        @vars = {} of String => LLVMVar

        if owner && owner.passed_as_self?
          @type = owner
          args_base_index = 1
          if owner.union?
            ptr = alloca(llvm_type(owner))
            value = call_args[0]
            value = @builder.load(value) if owner.passed_by_val?
            @builder.store value, ptr
            @vars["self"] = LLVMVar.new(ptr, owner)
          else
            @vars["self"] = LLVMVar.new(call_args[0], owner, true)
          end
        else
          args_base_index = 0
        end

        node.target_def.args.each_with_index do |arg, i|
          ptr = alloca(llvm_type(arg.type), arg.name)
          @vars[arg.name] = LLVMVar.new(ptr, arg.type)
          value = call_args[args_base_index + i]
          value = @builder.load(value) if arg.type.passed_by_val?
          @builder.store value, ptr
        end

        return_block = @return_block = new_block "return"
        return_block_table_blocks = @return_block_table_blocks = [] of LibLLVM::BasicBlockRef
        return_block_table_values = @return_block_table_values = [] of LibLLVM::ValueRef
        @return_type = node.type
        # if @return_type.union?
        #   @return_union = alloca(llvm_type(node.type), 'return')
        # else
        #   @return_union = nil
        # end

        accept(node.target_def.body)

        # if node.target_def.no_returns? || (node.target_def.body && node.target_def.body.no_returns?)
        #   @builder.unreachable
        # else
          # if node.target_def.type && !node.target_def.type.nil_type? && !node.block.breaks?
          #   if @return_union
          #     if node.target_def.body && node.target_def.body.type
          #       codegen_assign(@return_union, @return_type, node.target_def.body.type, @last)
          #     else
          #       @builder.unreachable
          #     end
          #   elsif node.target_def.type.nilable? && node.target_def.body && node.target_def.body.type && node.target_def.body.type.nil_type?
          #     @return_block_table[@builder.insert_block] = LLVM::Constant.null(llvm_type(node.target_def.type.nilable_type))
          #   else
              return_block_table_blocks << @builder.insert_block
              return_block_table_values << @last
          #   end
          # elsif (node.target_def.type.nil? || node.target_def.type.nil_type?) && node.type.nilable?
            # @return_block_table[@builder.insert_block] = @builder.int2ptr llvm_nil, llvm_type(node.type)
          # end
          @builder.br return_block
        # end

        @builder.position_at_end return_block

        # if node.no_returns? || node.returns? || block_returns? || (node.block.yields? && block_breaks?)
        #   @builder.unreachable
        # else
          # if node.type && !node.type.nil_type?
          #   if @return_union
          #     @last = @return_union
            # else
              phi_type = llvm_type(node.type)
              # phi_type = LLVM::Pointer(phi_type) if node.type.union?
              @last = @builder.phi phi_type, return_block_table_blocks, return_block_table_values
            # end
          # end
        # end

        old_context = @block_context.pop
        @vars = old_context.vars
        @type = old_context.type
        @return_block = old_context.return_block
        @return_block_table_blocks = old_context.return_block_table_blocks
        @return_block_table_values = old_context.return_block_table_values
        @return_type = old_context.return_type
        # @return_union = old_context[:return_union]
      else
        codegen_call(node, owner, call_args)
      end

      false
    end

    def codegen_dispatch(node, target_defs)
      branch = new_branched_block(node)

      if node_obj = node.obj
        owner = node_obj.type
        node_obj.accept(self)

        if owner.union?
          obj_type_id = @builder.load union_type_id(@last)
        # elsif owner.nilable? || owner.hierarchy_metaclass?
        #   obj_type_id = @last
        end
      else
        owner = node.scope

        if owner == @mod.program
          # Nothing
        elsif owner.union?
          obj_type_id = @builder.load union_type_id(llvm_self)
        else
          obj_type_id = llvm_self
        end
      end

      call = Call.new(node_obj ? CastedVar.new("%self") : nil, node.name, Array(ASTNode).new(node.args.length) { |i| CastedVar.new("%arg#{i}") }, node.block)
      call.scope = node.scope

      new_vars = @vars.dup

      if node_obj && node_obj.type.passed_as_self?
        new_vars["%self"] = LLVMVar.new(@last, node_obj.type, true)
      end

      arg_type_ids = [] of LibLLVM::ValueRef?
      node.args.each_with_index do |arg, i|
        arg.accept self
        if arg.type.union?
          arg_type_ids.push @builder.load(union_type_id(@last))
        # elsif arg.type.nilable?
        #   arg_type_ids.push @last
        else
          arg_type_ids.push nil
        end
        new_vars["%arg#{i}"] = LLVMVar.new(@last, arg.type, true)
      end

      old_vars = @vars
      @vars = new_vars

      next_def_label = nil
      target_defs.each do |a_def|
        if owner.union?
          result = match_any_type_id(a_def.owner.not_nil!, obj_type_id)
        # elsif owner.nilable?
        #   if a_def.owner.nil_type?
        #     result = null_pointer?(obj_type_id)
        #   else
        #     result = not_null_pointer?(obj_type_id)
        #   end
        # elsif owner.hierarchy_metaclass?
        #   result = match_any_type_id(a_def.owner, obj_type_id)
        else
          result = int1(1)
        end

        a_def.args.each_with_index do |arg, i|
          if node.args[i].type.union?
            comp = match_any_type_id(arg.type, arg_type_ids[i])
            result = @builder.and(result, comp)
          # elsif node.args[i].type.nilable?
          #   if arg.type.nil_type?
          #     result = @builder.and(result, null_pointer?(arg_type_ids[i]))
          #   else
          #     result = @builder.and(result, not_null_pointer?(arg_type_ids[i]))
          #   end
          end
        end

        current_def_label, next_def_label = new_blocks ["current_def", "next_def"]
        @builder.cond result, current_def_label, next_def_label

        @builder.position_at_end current_def_label

        if call_obj = call.obj
          call_obj.set_type(a_def.owner)
        end

        call.target_defs = [a_def] of Def
        call.args.zip(a_def.args) do |call_arg, a_def_arg|
          call_arg.set_type(a_def_arg.type)
        end
        # if node.block && node.block.break
        #   call.set_type @mod.type_merge a_def.type, node.block.break.type
        # else
          call.set_type a_def.type
        # end
        call.accept self

        add_branched_block_value(branch, a_def.type, @last)
        @builder.position_at_end next_def_label
      end

      @builder.unreachable
      close_branched_block(branch)
      @vars = old_vars
    end

    def codegen_call(node, self_type, call_args)
      target_def = node.target_def
      body = target_def.body
      if body.is_a?(Primitive)
        old_type = @type
        @type = self_type
        codegen_primitive(body, target_def, call_args)
        @type = old_type
        return
      end

      mangled_name = target_def.mangled_name(self_type)

      func = @llvm_mod.functions[mangled_name]? || codegen_fun(mangled_name, target_def, self_type)

      @last = @builder.call func, call_args

      if target_def.type.union?
        union = alloca llvm_type(target_def.type)
        @builder.store @last, union
        @last = union
      end
    end

    def codegen_fun(mangled_name, target_def, self_type, is_exported_fun_def = false)
      # if target_def.type.same?(@mod.void)
      #   llvm_return_type = LLVM.Void
      # else
        llvm_return_type = llvm_type(target_def.type)
      # end

      old_position = @builder.insert_block
      old_fun = @fun
      old_vars = @vars
      old_entry_block = @entry_block
      old_alloca_block = @alloca_block
      old_type = @type
      old_target_def = @target_def

      @vars = {} of String => LLVMVar

      args = [] of Arg
      if self_type && self_type.passed_as_self?
        @type = self_type
        args << Arg.new_with_type("self", self_type)
      end
      args.concat target_def.args

      if target_def.is_a?(External)
        is_external = true
        varargs = target_def.varargs
      end

      @fun = @llvm_mod.functions.add(
        mangled_name,
        args.map { |arg| llvm_arg_type(arg.type) },
        llvm_return_type,
        varargs
      )

      unless is_external
        @fun.linkage = LibLLVM::Linkage::Internal
      end

      args.each_with_index do |arg, i|
        param = @fun.get_param(i)
        LLVM.set_name param, arg.name
        LLVM.add_attribute param, LibLLVM::Attribute::ByVal if arg.type.passed_by_val?
      end

      if (!is_external && target_def.body) || is_exported_fun_def
        body = target_def.body
        new_entry_block

        args.each_with_index do |arg, i|
          if (self_type && i == 0 && !self_type.union?) || arg.type.passed_by_val?
            @vars[arg.name] = LLVMVar.new(@fun.get_param(i), arg.type, true)
          else
            pointer = alloca(llvm_type(arg.type), arg.name)
            @vars[arg.name] = LLVMVar.new(pointer, arg.type)
            @builder.store @fun.get_param(i), pointer
          end
        end

        if body
          old_return_type = @return_type
          # old_return_union = @return_union
          @return_type = target_def.type
          return_type = @return_type
          # @return_union = alloca(llvm_type(return_type), "return") if return_type.union?

          accept body

          return_from_fun target_def, return_type

          @return_type = old_return_type
          # @return_union = old_return_union
        end

        br_from_alloca_to_entry

        @builder.position_at_end old_position
      end

      @last = llvm_nil

      the_fun = @fun

      @vars = old_vars
      @fun = old_fun
      @entry_block = old_entry_block
      @alloca_block = old_alloca_block
      @type = old_type

      the_fun
    end

    def return_from_fun(target_def, return_type)
      # if target_def.type == @mod.void
      #   ret nil
      # elsif target_def.body.no_returns?
      #   @builder.unreachable
      # else
        if return_type.union?
          # if target_def.body.type != @return_type && !target_def.body.returns?
          #   assign_to_union(@return_union, @return_type, target_def.body.type, @last)
          #   @last = @builder.load @return_union
          # else
            @last = @builder.load @last
          # end
        end

        # if @return_type.nilable? && target_def.body.type && target_def.body.type.nil_type?
        #   ret LLVM::Constant.null(llvm_type(@return_type))
        # else
          ret(@last)
        # end
      # end
    end

    def match_any_type_id(type, type_id : LibLLVM::ValueRef)
      # Special case: if the type is Object+ we want to match against Reference+,
      # because Object+ can only mean a Reference type (so we exclude Nil, for example).
      # type = @mod.reference.hierarchy_type if type.equal?(@mod.object.hierarchy_type)
      # type = type.instance_type if type.hierarchy_metaclass?

      if type.union?
        # if type.hierarchy? && type.base_type.subclasses.empty?
        #   return @builder.icmp :eq, int(type.base_type.type_id), type_id
        # end

        match_fun_name = "~match<#{type}>"
        func = @main_mod.functions[match_fun_name]? || create_match_fun(match_fun_name, type)
        # func = check_main_fun match_fun_name, func
        return @builder.call func, [type_id] of LibLLVM::ValueRef
      end

      @builder.icmp LibLLVM::IntPredicate::EQ, int(type.type_id), type_id
    end

    def match_any_type_id(type, type_id : Nil)
      raise "Bug: match_any_type_id recieved nil type_id"
    end

    def create_match_fun(name, type : UnionType)
      @main_mod.functions.add(name, ([LLVM::Int32] of LibLLVM::TypeRef), LLVM::Int1) do |func|
        type_id = func.get_param(0)
        func.append_basic_block("entry") do |builder|
          result = nil
          type.each_concrete_type do |sub_type|
            sub_type_cond = builder.icmp(LibLLVM::IntPredicate::EQ, int(sub_type.type_id), type_id)
            result = result ? builder.or(result, sub_type_cond) : sub_type_cond
          end
          if result
            builder.ret result
          else
            raise "Bug: result is nil"
          end
        end
      end
    end

    def create_match_fun(name, type)
      raise "Bug: shouldn't create match fun for #{type}"
    end

    def new_entry_block
      @alloca_block, @entry_block = new_entry_block_chain ["alloca", "entry"]
    end

    def new_entry_block_chain names
      blocks = new_blocks names
      @builder.position_at_end blocks.last
      blocks
    end

    def br_from_alloca_to_entry
      br_block_chain [@alloca_block, @entry_block]
    end

    def br_block_chain blocks
      old_block = @builder.insert_block

      0.upto(blocks.count - 2) do |i|
        @builder.position_at_end blocks[i]
        @builder.br blocks[i + 1]
      end

      @builder.position_at_end old_block
    end

    def new_block(name)
      @fun.append_basic_block(name)
    end

    def new_blocks(names)
      names.map { |name| new_block name }
    end

    def alloca(type, name = "")
      in_alloca_block { @builder.alloca type, name }
    end

    def in_alloca_block
      old_block = @builder.insert_block
      @builder.position_at_end @alloca_block
      value = yield
      @builder.position_at_end old_block
      value
    end

    def in_const_block(const_block_name)
      old_position = @builder.insert_block
      old_fun = @fun
      old_in_const_block = @in_const_block
      @in_const_block = true

      @fun = @main
      const_block = new_block const_block_name
      @builder.position_at_end const_block

      yield

      new_const_block = @builder.insert_block
      @builder.position_at_end @const_block
      @builder.br const_block
      @const_block = new_const_block

      @builder.position_at_end old_position
      @fun = old_fun
      @in_const_block = old_in_const_block
    end

    def gep(ptr, index0, index1)
      @builder.gep ptr, [int32(index0), int32(index1)]
    end

    def null_pointer?(value)
      @builder.icmp LibLLVM::IntPredicate::EQ, @builder.ptr2int(value, LLVM::Int32), int(0)
    end

    def not_null_pointer?(value)
      @builder.icmp LibLLVM::IntPredicate::NE, @builder.ptr2int(value, LLVM::Int32), int(0)
    end

    def malloc(type)
      @builder.malloc type
    end

    def memset(pointer, value, size)
      pointer = cast_to_void_pointer pointer
      @builder.call @mod.memset(@llvm_mod), [pointer, value, @builder.trunc(size, LLVM::Int32), int32(4), int1(0)]
    end

    def realloc(buffer, size)
      @builder.call @mod.realloc(@llvm_mod), [buffer, size]
    end

    def llvm_type(type)
      @llvm_typer.llvm_type(type)
    end

    def llvm_struct_type(type)
      @llvm_typer.llvm_struct_type(type)
    end

    def llvm_arg_type(type)
      @llvm_typer.llvm_arg_type(type)
    end

    def llvm_embedded_type(type)
      @llvm_typer.llvm_embedded_type(type)
    end

    def llvm_size(type)
      LLVM.size_of llvm_type(type)
    end

    def llvm_self
      @vars["self"].pointer
    end

    def llvm_self_ptr
      llvm_self
    end

    def llvm_nil
      int1(0)
    end

    def int1(n)
      LLVM.int LLVM::Int1, n
    end

    def int8(n)
      LLVM.int LLVM::Int8, n
    end

    def int16(n)
      LLVM.int LLVM::Int16, n
    end

    def int32(n)
      LLVM.int LLVM::Int32, n
    end

    def int64(n)
      LLVM.int LLVM::Int64, n
    end

    def int(n)
      int32(n)
    end

    def accept(node)
      # old_current_node = @current_node
      node.accept self
      # @current_node = old_current_node
    end

    def ret(value)
      # if @needs_gc
      #   @builder.call set_root_index_fun, @gc_root_index
      # end

      @builder.ret value
    end
  end
end
