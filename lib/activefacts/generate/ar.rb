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

      private

      def col(name, type)
        type = normalise_type(type)
        <<-HERE
              t.#{type} "#{name}"
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
          'bit'
        else
          type
        end
      end
    end
  end
end
