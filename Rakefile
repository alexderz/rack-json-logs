require "bundler/gem_tasks"
require 'rubygems'
require 'rake'

begin
  require 'bump/tasks'
  module Bump; class Bump
    def self.defaults
      {
        :commit => false,
        :bundle => false,
        :tag => false
      }
    end
  end; end

rescue LoadError
  puts "No bump gem."
end

Rake::Task["release"].enhance(["build"]) do
  spec = Gem::Specification::load(Dir.glob("*.gemspec").first)
  sh "gem inabox pkg/#{spec.name}-#{spec.version}.gem -o -g https://#{ ENV['GEM_SERVER'] }/"
end
