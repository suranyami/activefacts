#
#       ActiveFacts Generators.
#       Generate ActiveRecord models and migrations from an ActiveFacts vocabulary.
#
# Copyright (c) 2012 David Parry. Read the LICENSE file.
#
require 'activefacts/vocabulary'
require 'activefacts/persistence'
require 'active_record'
require 'active_support'
require 'active_support/all'

module ActiveFacts
  module Generate
    # Generate ActiveRecord models and migrations for an ActiveFacts vocabulary.
    # Invoke as
    #   afgen --ar[=options] <file>.cql
    # Options are comma or space separated:
    class Ar
      include Persistence

      def initialize(vocabulary, *options)
        @vocabulary = vocabulary
        @vocabulary = @vocabulary.Vocabulary.values[0] if ActiveFacts::API::Constellation === @vocabulary
        @dir =        options.detect {|opt| opt =~ /\Adir=(.*)/} && $1
        @schema_dir = options.detect {|opt| opt =~ /\Aschema-dir=(.*)/} && $1
        @out = $>
      end

      def puts s
        @out.puts s
      end

      def go s
        puts s + ";\n\n"
      end

      public
      def generate(out = $>)
        @out = out
        out_schema
        out_models
      end

      private

      def out_models
        @vocabulary.tables.collect do |table|
          path = File.join(@dir, "#{table.name.capitalize.underscore}.rb")
          @out = File.open(path, 'w')
          ar_model = model(table) do
            table.columns.collect do |column|
              type, params, constraints = column.type
              col_name = column.name.underscore
              attrs = attribute(col_name)
              consts = constraints.collect do |constraint|
                validation(col_name, constraint)
              end
              "#{attrs}\n#{consts}"
            end.join
          end
          puts ar_model
        end
      end

      def out_schema
        m = @vocabulary.tables.collect do |table|
          migration(table) do
            table.columns.collect do |column|
              type, params, constraints = column.type
              col(column.name, type)
            end.join
          end
        end
        puts m.join
      end

      def model(table)
<<-HERE
class #{table.name.classify} < ActiveRecord::Base
#{yield}
end
HERE
      end

      def attribute(column)
<<-HERE
  attr_accessible :#{column}
HERE
      end

      def validation(column, constraint)
        case constraint.class
        when ActiveFacts::Metamodel::ValueConstraint
          allowed_range = constraint.all_allowed_range
          min = allowed_range.value_range.minimum_bound.value
          max = allowed_range.value_range.maximum_bound.value
          numerical = (min.is_a?(Number) && max.is_a?(Number))
return <<-HERE
  validates :#{column}, :numericality => true
HERE
        when ActiveFacts::Metamodel::PresenceConstraint
          if constraint.is_mandatory
return <<-HERE
  validates :#{column}, :presence => true
HERE
          end
        end
      end

      def col(name, type)
        type = normalise_type(type)
        <<-HERE
              t.#{type} :#{name.underscore}
HERE
      end

      def migration(table)
        <<-HERE
        class Create#{table.name.capitalize.pluralize} < ActiveRecord::Migration
          def change
            create_table #{table.name.tableize} do |t|
#{yield}
              t.timestamps
            end
          end
        end

        HERE
      end


      def normalise_type(type, length = 0)
        case type
        when /^Auto ?Counter$/
          'integer'

        when /^Unsigned ?Integer$/,
          /^Signed ?Integer$/,
          /^Unsigned ?Small ?Integer$/,
          /^Signed ?Small ?Integer$/,
          /^Unsigned ?Tiny ?Integer$/
          'integer'

        when /^Decimal$/
          'decimal'

        when /^Fixed ?Length ?Text$/, /^Char$/
          'string'
        when /^Variable ?Length ?Text$/, /^String$/
          'string'
        when /^Large ?Length ?Text$/, /^Text$/
          'text'

        when /^Date ?And ?Time$/, /^Date ?Time$/
          'datetime'
        when /^Date$/
              'datetime' # SQLSVR 2K5: 'date'
        when /^Time$/
          'datetime' # SQLSVR 2K5: 'time'
        when /^Auto ?Time ?Stamp$/
          'timestamp'

        when /^Money$/
          'decimal'
        when /^Picture ?Raw ?Data$/, /^Image$/
          'blob'
        when /^Variable ?Length ?Raw ?Data$/, /^Blob$/
          'blob'
        when /^BIT$/
          'boolean'
        else
          type
        end
      end
    end
  end
end
