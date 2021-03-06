#!/usr/bin/env bin/crystal -run
require "../../spec_helper"

describe "Block inference" do
  it "infer type of empty block body" do
    assert_type("
      def foo; yield; end

      foo do
      end
    ") { |mod| mod.nil }
  end

  it "infer type of block body" do
    input = parse "
      def foo; yield; end

      foo do
        x = 1
      end
    "
    result = infer_type input
    assert_type input, Expressions

    call = input.last
    assert_type call, Call
    call.block.not_nil!.body.type.should eq(result.program.int32)
  end

  it "infer type of block argument" do
    input = parse "
      def foo
        yield 1
      end

      foo do |x|
        1
      end
    "
    result = infer_type input
    mod, input = result.program, result.node
    assert_type input, Expressions

    call = input.last
    assert_type call, Call

    call.block.not_nil!.args[0].type.should eq(mod.int32)
  end

  it "infer type of local variable" do
    assert_type("
      def foo
        yield 1
      end

      y = 'a'
      foo do |x|
        y = x
      end
      y
    ") { union_of(char, int32) }
  end

  it "infer type of yield" do
    assert_type("
      def foo
        yield
      end

      foo do
        1
      end
    ") { int32 }
  end

  # it "infer type with union" do
  #   assert_type(%q(
  #     require "int"
  #     require "pointer"
  #     require "array"
  #     a = [1] || [1.1]
  #     a.each { |x| x }
  #   )) { union_of(array_of(int32), array_of(float64)) }
  # end

  # it "break from block without value" do
  #   assert_type(%q(
  #     def foo; yield; end

  #     foo do
  #       break
  #     end
  #   )) { self.nil }
  # end

  # it "break without value has nil type" do
  #   assert_type(%q(
  #     def foo; yield; 1; end
  #     foo do
  #       break if false
  #     end
  #   )) { union_of(self.nil, int32) }
  # end

  it "infers type of block before call" do
    result = assert_type("
      class Int32
        def foo
          10.5
        end
      end

      class Foo(T)
        def initialize(x : T)
          @x = x
        end
      end

      def bar(&block : Int32 -> U)
        Foo(U).new(yield 1)
      end

      bar { |x| x.foo }
      ") do
      foo = types["Foo"]
      assert_type foo, GenericClassType
      foo.instantiate([float64])
    end
    mod = result.program
    type = result.node.type
    assert_type type, GenericClassInstanceType
    type.type_vars["T"].type.should eq(mod.float64)
    type.instance_vars["@x"].type.should eq(mod.float64)
  end

  it "infers type of block before call taking other args free vars into account" do
    assert_type("
      class Foo(X)
        def initialize(x : X)
          @x = x
        end
      end

      def foo(x : U, &block: U -> T)
        Foo(T).new(yield x)
      end

      a = foo(1) do |x|
        10.5
      end
      ") do
      foo = types["Foo"]
      assert_type foo, GenericClassType
      foo.instantiate([float64])
    end
  end

  it "reports error if yields a type that's not that one in the block specification" do
    assert_error "
      def foo(&block: Int32 -> )
        yield 10.5
      end

      foo {}
      ",
      "argument #1 of yield expected to be Int32, not Float64"
  end

  it "reports error if yields a type that's not that one in the block specification and type changes" do
    assert_error "
      $global = 1

      def foo(&block: Int32 -> )
        yield $global
        $global = 10.5
      end

      foo {}
      ",
      "type must be Int32, not"
  end

  it "doesn't report error if yields nil but nothing is yielded" do
    assert_type("
      def foo(&block: Int32, Nil -> )
        yield 1
      end

      foo { |x| x }
      ") { int32 }
  end

  it "reports error if missing arguments to yield" do
    assert_error "
      def foo(&block: Int32, Int32 -> )
        yield 1
      end

      foo { |x| x }
      ",
      "missing argument #2 of yield with type Int32"
  end

  it "reports error if block didn't return expected type" do
    assert_error "
      def foo(&block: Int32 -> Float64)
        yield 1
      end

      foo { 'a' }
      ",
      "block expected to return Float64, not Char"
  end

  it "reports error if block changes type" do
    assert_error "
      def foo(&block: Int32 -> Float64)
        yield 1
      end

      $global = 10.5
      foo { $global }
      $global = 1
      ",
      "type must be Float64"
  end

  it "matches block arg return type" do
    assert_type("
      class Foo(T)
      end

      def foo(&block: Int32 -> Foo(T))
        yield 1
        Foo(T).new
      end

      foo { Foo(Float64).new }
      ") do
      foo = types["Foo"]
      assert_type foo, GenericClassType
      foo.instantiate([float64])
    end
  end

  it "infers type of block with generic type" do
    assert_type("
      class Foo(T)
      end

      def foo(&block: Foo(Int32) -> )
        yield Foo(Int32).new
      end

      foo do |x|
        10.5
      end
      ") { float64 }
  end

  it "infer type with self block arg" do
    assert_type("
      class Foo
        def foo(&block : self -> )
          yield self
        end
      end

      f = Foo.new
      a = nil
      f.foo do |x|
        a = x
      end
      a
      ") { |mod| union_of(types["Foo"], mod.nil) }
  end

  it "error with self input type doesn't match" do
    assert_error "
      class Foo
        def foo(&block : self -> )
          yield 1
        end
      end

      f = Foo.new
      f.foo {}
      ",
      "argument #1 of yield expected to be Foo, not Int32"
  end

  it "error with self output type doesn't match" do
    assert_error "
      class Foo
        def foo(&block : Int32 -> self )
          yield 1
        end
      end

      f = Foo.new
      f.foo { 1 }
      ",
      "block expected to return Foo, not Int32"
  end

  it "errors when block varaible shadows local variable" do
    assert_syntax_error "a = 1; foo { |a| }",
      "block argument 'a' shadows local variable 'a'"
  end

  it "errors when using local varaible with block argument name" do
    assert_error "def foo; yield; end; foo { |a| }; a",
      "undefined local variable or method 'a'"
  end

  it "types empty block" do
    assert_type("
      def foo
        ret = yield
        ret
      end

      foo { }
    ") { |mod| mod.nil }
  end

  # it "preserves type filters in block" do
  #   assert_type(%q(
  #     class Foo
  #       def bar
  #         'a'
  #       end
  #     end

  #     def foo
  #       yield 1
  #     end

  #     a = Foo.new || nil
  #     if a
  #       foo do |x|
  #         a.bar
  #       end
  #     else
  #       'b'
  #     end
  #     )) { char }
  # end

  # it "checks block type with hierarchy type" do
  #   assert_type(%q(
  #     require "prelude"

  #     class A
  #     end

  #     class B < A
  #     end

  #     a = [] of A
  #     a << B.new

  #     a.map { |x| x.to_s }

  #     1
  #     )) { int32 }
  # end
end
