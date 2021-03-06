require "../ast"
require "../types"

module Crystal
  class ASTNode
    def is_restriction_of?(other : ASTNode, owner)
      self == other
    end

    def is_restriction_of?(other, owner)
      raise "Bug: called #{self}.is_restriction_of?(#{other})"
    end
  end

  class SelfType
    def is_restriction_of?(type : Type, owner)
      owner.is_restriction_of?(type, owner)
    end

    def is_restriction_of?(type : SelfType, owner)
      true
    end

    def is_restriction_of?(type : ASTNode, owner)
      false
    end
  end

  class Def
    def is_restriction_of?(other : Def, owner)
      args.zip(other.args) do |self_arg, other_arg|
        self_type = self_arg.type? || self_arg.type_restriction
        other_type = other_arg.type? || other_arg.type_restriction
        return false if self_type == nil && other_type != nil
        if self_type && other_type
          return false unless self_type.is_restriction_of?(other_type, owner)
        end
      end
      true
    end
  end


  class Ident
    def is_restriction_of?(other : Ident, owner)
      return true if self == other

      self_type = owner.lookup_type(names)
      if self_type
        other_type = owner.lookup_type(other.names)
        if other_type
          return self_type.is_restriction_of?(other_type, owner)
        else
          return true
        end
      end

      false
    end

    def is_restriction_of?(other, owner)
      false
    end
  end

  class Type
    def restrict(other : Nil, owner, type_lookup, free_vars)
      self
    end

    def restrict(other : Type, owner, type_lookup, free_vars)
      if self == other
        return self
      end

      if parents = self.parents
        if parents.any? &.is_restriction_of?(other, nil)
          return self
        end
      end

      nil
    end

    def restrict(other : Ident, owner, type_lookup, free_vars)
      single_name = other.names.length == 1
      if single_name
        ident_type = free_vars[other.names.first]?
      end

      ident_type ||= type_lookup.lookup_type other.names
      if ident_type
        restrict ident_type, owner, type_lookup, free_vars
      elsif single_name
        free_vars[other.names.first] = self
      else
        self
      end
    end

    def restrict(other : NewGenericClass, owner, type_lookup, free_vars)
      nil
    end

    def restrict(other : SelfType, owner, type_lookup, free_vars)
      restrict(owner, owner, type_lookup, free_vars)
    end

    def restrict(other : UnionType, owner, type_lookup, free_vars)
      restricted = other.union_types.any? { |union_type| is_restriction_of?(union_type, nil) }
      restricted ? self : nil
    end

    def restrict(other : IdentUnion, owner, type_lookup, free_vars)
      matches = [] of Type
      other.idents.each do |ident|
        match = restrict ident, owner, type_lookup, free_vars
        matches << match if match
      end
      matches.length > 0 ? program.type_merge(matches) : nil
    end

    def restrict(other : ASTNode, owner, type_lookup, free_vars)
      raise "Bug: unsupported restriction: #{other}"
    end

    def is_restriction_of?(other : UnionType, owner)
      other.union_types.all? { |subtype| is_restriction_of?(subtype, subtype) }
    end

    def is_restriction_of?(other : Type, owner)
      if self == other
        return true
      end

      if parents = self.parents
        return parents.any? &.is_restriction_of?(other, owner)
      end

      false
    end

    def is_restriction_of?(other : ASTNode, owner)
      raise "Bug: called #{self}.is_restriction_of?(#{other})"
    end

    def is_restriction_of_all?(type : UnionType)
      type.union_types.all? { |subtype| is_restriction_of? subtype, subtype }
    end

    def is_restriction_of_all?(type)
      is_restriction_of? type, type
    end
  end

  class UnionType
    def is_restriction_of?(type, owner)
      union_types.any? &.is_restriction_of?(type, owner)
    end

    def restrict(other : Type, owner, type_lookup, free_vars)
      program.type_merge_union_of(union_types.map &.restrict(other, owner, type_lookup, free_vars))
    end
  end

  class GenericClassInstanceType
    def restrict(other : Ident, type_lookup, free_vars)
      ident_type = type_lookup.lookup_type other.names
      generic_class == ident_type ? self : nil
    end

    def restrict(other : NewGenericClass, owner, type_lookup, free_vars)
      generic_class = type_lookup.lookup_type other.name.names
      return nil unless generic_class == self.generic_class

      assert_type generic_class, GenericClassType
      return nil unless generic_class.type_vars.length == self.generic_class.type_vars.length

      i = 0
      type_vars.each do |name, type_var|
        other_type_var = other.type_vars[i]
        restricted = type_var.type.restrict other_type_var, owner, type_lookup, free_vars
        return nil unless restricted
        i += 1
      end

      self
    end
  end
end
