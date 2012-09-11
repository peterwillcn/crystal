require 'spec_helper'

describe 'Code gen: primitives' do
  it 'codegens int' do
    run('1').to_i.should eq(1)
  end

  it 'codegens float' do
    run('1; 2.5').to_f.should eq(2.5)
  end
end