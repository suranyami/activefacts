require 'spec_helper'
require 'activefacts/vocabulary'
require 'activefacts/support'
require 'activefacts/input/orm'
require 'activefacts/generate/ar'

describe "loading AR" do
  it "is callable" do
    ActiveFacts::Generate::AR.new(nil)
  end
end
