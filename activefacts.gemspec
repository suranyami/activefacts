# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "activefacts/version"

Gem::Specification.new do |s|
  s.name = 'activefacts'
  s.version = ActiveFacts::VERSION
  s.platform    = Gem::Platform::RUBY
  s.summary = "A semantic modeling and query language (CQL) and application runtime (the Constellation API)"
  s.description = %q{
ActiveFacts provides a semantic modeling language, the Constellation
Query Language (CQL).  CQL combines natural language verbalisation and
formal logic, producing a formal language that reads like plain
English. ActiveFacts converts semantic models from CQL to relational
and object models in SQL, Ruby and other languages.
}
  # s.url = "http://dataconstellation.com/ActiveFacts/"
  s.authors     = ["Clifford Heath"]
  s.email       = ["cjh@dataconstellation.org"]
  # s.changes              = s.paragraphs_of("History.txt", 0..1).join("\n\n")
  s.post_install_message = 'For more information on ActiveFacts, see http://dataconstellation.com/ActiveFacts'
  s.rubyforge_project    = "activefacts"
  s.homepage             = 'https://github.com/suranyami/activefacts'

  s.add_dependency 'activefacts-api', '>= 0.8.12'
  s.add_dependency 'treetop', '>= 1.4.1'
  s.add_dependency 'rake', '>= 0.8.7'

  s.add_development_dependency 'bundler', '> 1.0.10'
  s.add_development_dependency 'hoe'
  s.add_development_dependency 'newgem'
  s.add_development_dependency 'rspec'

  s.executables = ['afgen', 'cql']
  # s.extensions << 'lib/activefacts/cql/Rakefile'

  # s.spec_extras[:extensions] = 'lib/activefacts/cql/Rakefile'
  # # Magic Hoe hook to prevent the generation of diagrams:
  # ENV['NODOT'] = 'yes'
  # s.spec_extras[:rdoc_options] = ['-S'] +
  #   # RDoc used to have these options: -A has_one -A one_to_one -A maybe
  #   %w{
  #     -x lib/activefacts/cql/.*.rb
  #     -x lib/activefacts/vocabulary/.*.rb
  #   }
  # s.clean_globs |= %w[**/.DS_Store tmp *.log]
  # path = (s.rubyforge_name == s.name) ? s.rubyforge_name : "\#{s.rubyforge_name}/\#{s.name}"
  # s.remote_rdoc_dir = File.join(path.gsub(/^#{s.rubyforge_name}\/?/,''), 'rdoc')
  # s.rsync_args = '-av --delete --ignore-errors'
end
