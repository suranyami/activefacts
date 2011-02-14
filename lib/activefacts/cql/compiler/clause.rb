module ActiveFacts
  module CQL
    class Compiler < ActiveFacts::CQL::Parser

      class Clause
        attr_reader :phrases
        attr_accessor :qualifiers, :context_note
        attr_accessor :conjunction      # one of {nil, 'and', ',', 'or', 'where'}
        attr_reader :fact_type, :reading, :role_sequence    # These are the Metamodel objects
        attr_reader :side_effects
        attr_writer :fact_type          # Assigned for a bare (existential) objectification fact
        attr_accessor :fact             # When binding fact instances the fact goes here
        attr_accessor :objectified_as   # The VarRef which objectified this fact type

        def initialize phrases, qualifiers = [], context_note = nil
          @phrases = phrases
          var_refs.each { |var_ref| var_ref.clause = self }
          @qualifiers = qualifiers
          @context_note = context_note
        end

        def var_refs
          @phrases.select{|r| r.is_a?(VarRef)}
        end

        # A clause that contains only the name of a ObjectType and no literal or reading text
        # refers only to the existence of that ObjectType (as opposed to an instance of the object_type).
        def is_existential_type
          @phrases.size == 1 and
            @phrases[0].is_a?(VarRef) and
            !@phrases[0].literal
        end

        def display
          to_s
        end

        def inspect
          to_s
        end

        def to_s
          "#{
            @qualifiers && @qualifiers.size > 0 ? @qualifiers.sort.inspect+' ' : nil
          }#{
            quotes = false
            @phrases.inject(""){|s, p|
              if VarRef === p
                s[0..-2] + (quotes ? (quotes = false; '" ') : '') + p.to_s +
                  ((oj = p.nested_clauses) ?  ' ('+ oj.map{|c| ((j=c.conjunction) ? j+' ' : '') + c.to_s}*' ' + ')' : '') +
                ' '
              elsif FunctionCallChain === p
                s[0..-2] + (quotes ? (quotes = false; '" ') : '') + p.to_s
              elsif String === p
                s + (quotes ? '' : (quotes = true; '"')) + p.to_s + ' '
              else
                raise "Unexpected phrase type in clause: #{p.to_s}"
              end
            }.sub(/ $/,'') + (quotes ? '"' : '')
          }#{
            @context_note && ' ' + @context_note.inspect
          }"
        end

        def identify_players_with_role_name context
          var_refs.each do |var_ref|
            var_ref.identify_player(context) if var_ref.role_name
            # Include players in nested clauses, if any
            var_ref.nested_clauses.each{|clause| clause.identify_players_with_role_name(context)} if var_ref.nested_clauses
          end
        end

        def identify_other_players context
          var_refs.each do |var_ref|
            var_ref.identify_player(context) unless var_ref.player
            # Include players in nested clauses, if any
            var_ref.nested_clauses.each{|clause| clause.identify_other_players(context)} if var_ref.nested_clauses
          end
        end

        def includes_literals
          var_refs.detect{|var_ref| var_ref.literal || (ja = var_ref.nested_clauses and ja.detect{|jr| jr.includes_literals })}
        end

        def is_equality_comparison
          false
        end

        def bind_roles context
          role_names = var_refs.map{ |var_ref| var_ref.role_name }.compact

          # Check uniqueness of role names and subscripts within this clause:
          role_names.each do |rn|
            next if role_names.select{|rn2| rn2 == rn}.size == 1
            raise "Duplicate role #{rn.is_a?(Integer) ? "subscript" : "name"} '#{rn}' in clause"
          end

          var_refs.each do |var_ref|
            var_ref.bind context
            # Include players in nested clauses, if any
            var_ref.nested_clauses.each{|clause| clause.bind_roles(context)} if var_ref.nested_clauses
          end
        end

        def phrases_match(phrases)
          @phrases.zip(phrases).each do |mine, theirs|
            return false if mine.is_a?(VarRef) != theirs.is_a?(VarRef)
            if mine.is_a?(VarRef)
              return false unless mine.key == theirs.key
            else
              return false unless mine == theirs
            end
          end
          true
        end

        # This method chooses the existing fact type which matches most closely.
        # It returns nil if there is none, or a ClauseMatchSideEffects object if matched.
        #
        # As this match may not necessarily be used (depending on the side effects),
        # no change is made to this Clause object - those will be done later.
        #
        def match_existing_fact_type context, options = {}
          raise "Internal error, clause already matched, should not match again" if @fact_type
          # If we fail to match, try to a left contraction (or save this for a subsequent left contraction):
          left_contract_this_onto = context.left_contractable_clause
          new_conjunction = (conjunction == nil || conjunction == ',')
          changed_conjunction = (lcc = context.left_contraction_conjunction) && lcc != conjunction
          if context.left_contraction_allowed && (new_conjunction || changed_conjunction)
            # Conjunctions are that/who, where, comparison-operator, ','
            debug :matching, "A left contraction will be against #{self.inspect}, conjunction is #{conjunction.inspect}"
            context.left_contractable_clause = self
            left_contract_this_onto = nil # Can't left-contract this clause
          end
          context.left_contraction_conjunction = new_conjunction ? nil : @conjunction

          contracted_role = nil

          vrs = []+var_refs
          begin
            players = vrs.map{|vr| vr.player}
            raise "Must identify players before matching fact types" if players.include? nil
            raise "A fact type must involve at least one object type, but there are none in '#{inspect}'" if players.size == 0 && !left_contract_this_onto

            player_names = players.map{|p| p.name}

            debug :matching, "Looking for existing #{players.size}-ary fact types matching '#{contracted_role && contracted_role.inspect+' '}#{inspect}'" do
              debug :matching, "Players are '#{player_names.inspect}'"

              # Match existing fact types in nested clauses first (not for contractions):
              if !contracted_role
                vrs.each do |var_ref|
                  next unless joins = var_ref.nested_clauses and !joins.empty?
                  var_ref.nested_clauses.each do |oj|
                    ft = oj.match_existing_fact_type(context)
                    raise "Unrecognised fact type #{oj.display}" unless ft
                    if (ft && ft.entity_type == var_ref.player)
                      var_ref.objectification_of = ft
                      oj.objectified_as = var_ref
                    end
                  end
                  raise "#{var_ref.inspect} contains objectification joins that do not objectify it" unless var_ref.objectification_of
                end
              end

              # For each role player, find the compatible types (the set of all subtypes and supertypes).
              # For a player that's an objectification, we don't allow implicit supertype joins
              player_related_types =
                vrs.zip(players).map do |var_ref, player|
                  disallow_subtyping = var_ref && var_ref.objectification_of || options[:exact_type]
                  ((disallow_subtyping ? [] : player.supertypes_transitive) +
                    player.subtypes_transitive).uniq
                end

              debug :matching, "Players must match '#{player_related_types.map{|pa| pa.map{|p|p.name}}.inspect}'"

              # The candidate fact types have the right number of role players of related types.
              # If any role is played by a supertype or subtype of the required type, there's an implicit subtyping join
              candidate_fact_types =
                player_related_types[0].map do |related_type|
                  related_type.all_role.select do |role|
                    all_roles = role.fact_type.all_role
                    next if all_roles.size != players.size      # Wrong number of players
                    next if role.fact_type.is_a?(ActiveFacts::Metamodel::ImplicitFactType)

                    all_players = all_roles.map{|r| r.object_type}  # All the players of this candidate fact type

                    next if player_related_types[1..-1].        # We know the first player is compatible, check the rest
                      detect do |player_types|                  # Make sure that there remains a compatible player
                        # player_types is an array of the types compatible with the Nth player
                        compatible_player = nil
                        all_players.each_with_index do |p, i|
                          if player_types.include?(p)
                            compatible_player = p
                            all_players.delete_at(i)
                            break
                          end
                        end
                        !compatible_player
                      end

                    true
                  end.
                    map{ |role| role.fact_type}
                end.flatten.uniq

              # If there is more than one possible exact match (same adjectives) with different subyping, the implicit join is ambiguous and is not allowed

              debug :matching, "Looking amongst #{candidate_fact_types.size} existing fact types for one matching '#{contracted_role && contracted_role.inspect+' '}#{inspect}'" do
                matches = {}
                candidate_fact_types.map do |fact_type|
                  fact_type.all_reading.map do |reading|
                    next unless side_effects = clause_matches(fact_type, reading, contracted_role)
                    matches[reading] = side_effects if side_effects
                  end
                end

                # REVISIT: Side effects that leave extra adjectives should only be allowed if the
                # same extra adjectives exist in some other clause in the same declaration.
                # The extra adjectives are then necessary to associate the two role players
                # when consumed adjectives were required to bind to the underlying fact types.
                # This requires the final decision on fact type matching to be postponed until
                # the whole declaration has been processed and the extra adjectives can be matched.

                best_matches = matches.keys.sort_by{|match|
                  # Between equivalents, prefer the one without a join on the first role
                  (m = matches[match]).cost*2 + ((!(e = m.role_side_effects[0]) || e.cost) == 0 ? 0 : 1)
                }
                debug :matching_fails, "Found #{matches.size} valid matches#{matches.size > 0 ? ', best is '+best_matches[0].expand : ''}"

                if matches.size > 1
                  first = matches[best_matches[0]]
                  cost = first.cost
                  equal_best = matches.select{|k,m| m.cost == cost}

                  if equal_best.size > 1 and equal_best.detect{|k,m| !m.fact_type.is_a?(Metamodel::TypeInheritance)}
                    # Complain if there's more than one equivalent cost match (unless all are TypeInheritance):
                    raise "#{@phrases.inspect} could match any of the following:\n\t"+
                      best_matches.map { |reading| reading.expand + " with " + matches[reading].describe } * "\n\t"
                  end
                end

                if matches.size >= 1
                  @reading = best_matches[0]
                  @side_effects = matches[@reading]
                  @fact_type = @side_effects.fact_type
                  debug :matching, "Matched '#{@fact_type.default_reading}'"
                  @phrases.unshift(contracted_role) if contracted_role
                  apply_side_effects(context, @side_effects)
                  return @fact_type
                end

              end
              debug :matching, "No fact type matched, candidates were '#{candidate_fact_types.map{|ft| ft.default_reading}*"', '"}'"
            end
            if left_contract_this_onto && !contracted_role
              contracted_from = left_contract_this_onto.var_refs[0]
              contraction_player = contracted_from.player
              contracted_role = VarRef.new(contraction_player.name)
              contracted_role.player = contracted_from.player
              contracted_role.role_name = contracted_from.role_name
              contracted_role.bind(context)
              vrs.unshift contracted_role

              debug :matching, "Failed to match #{inspect}. Trying again using left contraction onto #{contraction_player.name}"
              redo
            end
          end until true  # Once through, unless we hit a redo
          if contracted_role
            contracted_role.unbind context
          end
          @fact_type = nil
        end

        # The Reading passed has the same players as this Clause. Does it match?
        # Twisty curves. This is a complex bit of code!
        # Find whether the phrases of this clause match the fact type reading,
        # which may require absorbing unmarked adjectives.
        #
        # If it does match, make the required changes and set @var_ref to the matching role ref.
        # Adjectives that were used to match are removed (and leaving any additional adjectives intact).
        #
        # Approach:
        #   Match each element where element means:
        #     a role player phrase (perhaps with adjectives)
        #       Our phrase must either be
        #         a player that contains the same adjectives as in the reading.
        #         a word (unmarked leading adjective) that introduces a sequence
        #           of adjectives leading up to a matching player
        #       trailing adjectives, both marked and unmarked, are absorbed too.
        #     a word that matches the reading's
        #
        def clause_matches(fact_type, reading, contracted_role = nil)
          side_effects = []    # An array of items for each role, describing any side-effects of the match.
          intervening_words = nil
          residual_adjectives = false
          phrases = [contracted_role].compact+@phrases
          debug :matching_fails, "Does '#{phrases.inspect}' match '#{reading.expand}'" do
            phrase_num = 0
            reading_parts = reading.text.split(/\s+/)
            reading_parts.each do |element|
              if element !~ /\{(\d+)\}/
                # Just a word; it must match
                unless phrases[phrase_num] == element
                  debug :matching_fails, "Mismatched ordinary word #{phrases[phrase_num].inspect} (wanted #{element})"
                  return nil
                end
                phrase_num += 1
                next
              else
                role_ref = reading.role_sequence.all_role_ref.sort_by{|rr| rr.ordinal}[$1.to_i]
              end

              player = role_ref.role.object_type

              # Figure out what's next in this phrase (the next player and the words leading up to it)
              next_player_phrase = nil
              intervening_words = []
              while (phrase = phrases[phrase_num])
                phrase_num += 1
                if phrase.is_a?(VarRef)
                  next_player_phrase = phrase
                  next_player_phrase_num = phrase_num-1
                  break
                else
                  intervening_words << phrase
                end
              end
              return nil unless next_player_phrase  # reading has more players than we do.
              next_player = next_player_phrase.player

              # The next player must match:
              common_supertype = nil
              if next_player != player
                # This relies on the supertypes being in breadth-first order:
                common_supertype = (next_player.supertypes_transitive & player.supertypes_transitive)[0]
                if !common_supertype
                  debug :matching_fails, "Reading discounted because next player #{player.name} doesn't match #{next_player.name}"
                  return nil
                end

                debug :matching_fails, "Subtype join is required between #{player.name} and #{next_player_phrase.player.name} via common supertype #{common_supertype.name}"
              else
                if !next_player_phrase
                  next    # Contraction succeeded so far
                end
              end

              # It's the right player. Do the adjectives match? This must include the intervening_words, if any.

              role_has_residual_adjectives = false
              absorbed_precursors = 0
              if la = role_ref.leading_adjective and !la.empty?
                # The leading adjectives must match, one way or another
                la = la.split(/\s+/)
                return nil unless la[0,intervening_words.size] == intervening_words
                # Any intervening_words matched, see what remains
                la.slice!(0, intervening_words.size)

                # If there were intervening_words, the remaining reading adjectives must match the phrase's leading_adjective exactly.
                phrase_la = (next_player_phrase.leading_adjective||'').split(/\s+/)
                return nil if !intervening_words.empty? && la != phrase_la
                # If not, the phrase's leading_adjectives must *end* with the reading's
                return nil if phrase_la[-la.size..-1] != la
                role_has_residual_adjectives = true if phrase_la.size > la.size
                # The leading adjectives and the player matched! Check the trailing adjectives.
                absorbed_precursors = intervening_words.size
                intervening_words = []
              elsif intervening_words.size > 0 || next_player_phrase.leading_adjective
                role_has_residual_adjectives = true
              end

              absorbed_followers = 0
              if ta = role_ref.trailing_adjective and !ta.empty?
                ta = ta.split(/\s+/)  # These are the trailing adjectives to match

                phrase_ta = (next_player_phrase.trailing_adjective||'').split(/\s+/)
                i = 0   # Pad the phrases up to the size of the trailing_adjectives
                while phrase_ta.size < ta.size
                  break unless (word = phrases[phrase_num+i]).is_a?(String)
                  phrase_ta << word
                  i += 1
                end
                # ta is the adjectives in the fact type being matched
                # phrase_ta is the explicit adjectives augmented with implicit ones to the same size
                return nil if ta != phrase_ta[0,ta.size]
                role_has_residual_adjectives = true if phrase_ta.size > ta.size
                absorbed_followers = i
                phrase_num += i # Skip following words that were consumed as trailing adjectives
              elsif next_player_phrase.trailing_adjective
                role_has_residual_adjectives = true
              end

              # REVISIT: I'm not even sure I should be caring about role names here.
              # Role names are on roles, and are only useful within the fact type definition.
              # At some point, we need to worry about role names on clauses within fact type derivations,
              # which means they'll move to the Role Ref class; but even then they only match within the
              # definition that creates that Role Ref.
=begin
              if a = (!phrase.role_name.is_a?(Integer) && phrase.role_name) and
                  e = role_ref.role.role_name and
                  a != e
                debug :matching, "Role names #{e.inspect} for #{player.name} and #{a.inspect} for #{next_player_phrase.player.name} don't match"
                return nil
              end
=end

              residual_adjectives ||= role_has_residual_adjectives
              if residual_adjectives && next_player_phrase.variable.refs.size == 1
                # This makes matching order-dependent, because there may be no "other purpose"
                # until another reading has been matched and the roles rebound.
                debug :matching_fails, "Residual adjectives have no other purpose, so this match fails"
                return nil
              end

              # The phrases matched this reading's next role_ref, save data to apply the side-effects:
              side_effects << ClauseMatchSideEffect.new(next_player_phrase, role_ref, next_player_phrase_num, absorbed_precursors, absorbed_followers, common_supertype, role_has_residual_adjectives)
            end

            if phrase_num != phrases.size || !intervening_words.empty?
              debug :matching_fails, "Extra words #{(intervening_words + phrases[phrase_num..-1]).inspect}"
              return nil
            end

            if fact_type.is_a?(Metamodel::TypeInheritance)
              # There may be only one subtyping join on a TypeInheritance fact type.
              ti_joins = side_effects.select{|side_effect| side_effect.common_supertype}
              if ti_joins.size > 1   # Not allowed
                debug :matching_fails, "Can't have more than one subtyping join on a TypeInheritance fact type"
                return nil
              end

              if ti = ti_joins[0]
                # The Type Inheritance join must continue in the same direction as this reading.
                allowed = fact_type.supertype == ti.role_ref.role.object_type ?
                    fact_type.subtype.supertypes_transitive :
                    fact_type.supertype.subtypes_transitive
                if !allowed.include?(ti.common_supertype)
                  debug :matching_fails, "Implicit subtyping join extends in the wrong direction"
                  return nil
                end
              end
            end

            debug :matching, "Matched reading '#{reading.expand}' (with #{
                  side_effects.map{|side_effect|
                    side_effect.absorbed_precursors+side_effect.absorbed_followers + (side_effect.common_supertype ? 1 : 0)
                  }.inspect
                } side effects)#{residual_adjectives ? ' and residual adjectives' : ''}"
          end
          # There will be one side_effects for each role player
          ClauseMatchSideEffects.new(fact_type, self, residual_adjectives, side_effects)
        end

        def apply_side_effects(context, side_effects)
          @applied_side_effects = side_effects
          # Enact the side-effects of this match (delete the consumed adjectives):
          # Since this deletes words from the phrases, we do it in reverse order.
          debug :matching, "Apply side-effects" do
            side_effects.apply_all do |side_effect|
              phrase = side_effect.phrase

              # We re-use the role_ref if possible (no extra adjectives were used, no rolename or join, etc).
              debug :matching, "side-effect means variable #{phrase.inspect} matches role ref #{side_effect.role_ref.role.object_type.name}"
              phrase.role_ref = side_effect.role_ref

              changed = false

              # Where this phrase has leading or trailing adjectives that are in excess of those of
              # the role_ref, those must be local, and we'll need to extract them.

              if rra = side_effect.role_ref.trailing_adjective
                debug :matching, "Deleting matched trailing adjective '#{rra}'#{side_effect.absorbed_followers>0 ? " in #{side_effect.absorbed_followers} followers" : ""}"

                # These adjective(s) matched either an adjective here, or a follower word, or both.
                if a = phrase.trailing_adjective
                  if a.size >= rra.size
                    a = a[rra.size+1..-1]
                    phrase.trailing_adjective = a == '' ? nil : a
                    changed = true
                  end
                elsif side_effect.absorbed_followers > 0
                  # The following statement is incorrect. The absorbed adjective is what caused the match.
                  # This phrase is absorbing non-hyphenated adjective(s), which changes its variable
                  # phrase.trailing_adjective =
                  @phrases.slice!(side_effect.num+1, side_effect.absorbed_followers)*' '
                  changed = true
                end
              end

              if rra = side_effect.role_ref.leading_adjective
                debug :matching, "Deleting matched leading adjective '#{rra}'#{side_effect.absorbed_precursors>0 ? " in #{side_effect.absorbed_precursors} precursors" : ""}}"

                # These adjective(s) matched either an adjective here, or a precursor word, or both.
                if a = phrase.leading_adjective
                  if a.size >= rra.size
                    a = a[0...-rra.size]
                    phrase.leading_adjective = a == '' ? nil : a
                    changed = true
                  end
                elsif side_effect.absorbed_precursors > 0
                  # The following statement is incorrect. The absorbed adjective is what caused the match.
                  # This phrase is absorbing non-hyphenated adjective(s), which changes its variable
                  #phrase.leading_adjective =
                  @phrases.slice!(side_effect.num-side_effect.absorbed_precursors, side_effect.absorbed_precursors)*' '
                  changed = true
                end
              end
              if changed
                phrase.rebind context
              end

            end
          end
        end

        # Make a new fact type with roles for this clause.
        # Don't assign @fact_type; that will happen when the reading is added
        def make_fact_type vocabulary
          fact_type = vocabulary.constellation.FactType(:new)
          debug :matching, "Making new fact type for #{@phrases.inspect}" do
            @phrases.each do |phrase|
              next unless phrase.is_a?(VarRef)
              phrase.role = vocabulary.constellation.Role(fact_type, fact_type.all_role.size, :object_type => phrase.player)
              phrase.role.role_name = phrase.role_name if phrase.role_name && phrase.role_name.is_a?(String)
            end
          end
          fact_type
        end

        def make_reading vocabulary, fact_type
          @fact_type = fact_type
          constellation = vocabulary.constellation
          @role_sequence = constellation.RoleSequence(:new)
          reading_words = @phrases.clone
          index = 0
          debug :matching, "Making new reading for #{@phrases.inspect}" do
            reading_words.map! do |phrase|
              if phrase.is_a?(VarRef)
                # phrase.role will be set if this reading was used to make_fact_type.
                # Otherwise we have to find the existing role via the Variable. This is pretty ugly.
                unless phrase.role
                  # Find another variable for this phrase which already has a role_ref to the same fact type:
                  ref = phrase.variable.refs.detect{|ref| ref.role_ref && ref.role_ref.role.fact_type == fact_type}
                  role_ref = ref.role_ref
                  phrase.role = role_ref.role
                end
                rr = constellation.RoleRef(@role_sequence, index, :role => phrase.role)
                phrase.role_ref = rr

                if la = phrase.leading_adjective
                  # If we have used one or more adjective to match an existing reading, that has already been removed.
                  rr.leading_adjective = la
                end
                if ta = phrase.trailing_adjective
                  rr.trailing_adjective = ta
                end

                if phrase.value_constraint
                  raise "The role #{rr.inspect} already has a value constraint" if rr.role.role_value_constraint
                  phrase.value_constraint.constellation = fact_type.constellation
                  rr.role.role_value_constraint = phrase.value_constraint.compile
                end

                index += 1
                "{#{index-1}}"
              else
                phrase
              end
            end
            if existing = @fact_type.all_reading.detect{|r|
                r.text == reading_words*' ' and
                  r.role_sequence.all_role_ref_in_order.map{|rr| rr.role.object_type} ==
                    role_sequence.all_role_ref_in_order.map{|rr| rr.role.object_type}
              }
              existing
              #raise "Reading '#{existing.expand}' already exists, so why are we creating a duplicate?"
            end
            constellation.Reading(@fact_type, @fact_type.all_reading.size, :role_sequence => @role_sequence, :text => reading_words*" ")
          end
        end

        # When we match an existing reading, we might have matched using additional adjectives.
        # These adjectives have been removed from the phrases. If there are any remaining adjectives,
        # we need to make a new RoleSequence, otherwise we can use the existing one.
        def adjust_for_match
          return unless @applied_side_effects
          new_role_sequence_needed = @applied_side_effects.residual_adjectives

          role_phrases = []
          reading_words = []
          new_role_sequence_needed = false
          @phrases.each do |phrase|
            if phrase.is_a?(VarRef)
              role_phrases << phrase
              reading_words << "{#{phrase.role_ref.ordinal}}"
              if phrase.role_name != phrase.role_ref.role.role_name ||
                  phrase.leading_adjective ||
                  phrase.trailing_adjective
                debug :matching, "phrase in matched clause has residual adjectives or role name, so needs a new role_sequence" if @fact_type.all_reading.size > 0
                new_role_sequence_needed = true
              end
            else
              reading_words << phrase
              false
            end
          end

          debug :matching, "Clause '#{reading_words*' '}' #{new_role_sequence_needed ? 'requires' : 'does not require'} a new Role Sequence"

          constellation = @fact_type.constellation
          reading_text = reading_words*" "
          if new_role_sequence_needed
            @role_sequence = constellation.RoleSequence(:new)
            extra_adjectives = []
            role_phrases.each_with_index do |rp, i|
              role_ref = constellation.RoleRef(@role_sequence, i, :role => rp.role_ref.role)
              if a = rp.leading_adjective
                role_ref.leading_adjective = a
                extra_adjectives << a+"-"
              end
              if a = rp.trailing_adjective
                role_ref.trailing_adjective = a
                extra_adjectives << "-"+a
              end
              if (a = rp.role_name) && (e = rp.role_ref.role.role_name) && a != e
                raise "Can't create new reading '#{reading_text}' for '#{reading.expand}' with alternate role name #{a}"
                extra_adjectives << "(as #{a})"
              end
            end
            debug :matching, "Making new role sequence for new reading #{reading_text} due to #{extra_adjectives.inspect}"
          else
            # Use existing RoleSequence
            @role_sequence = role_phrases[0].role_ref.role_sequence
            if @role_sequence.all_reading.detect{|r| r.text == reading_text }
              debug :matching, "No need to re-create identical reading for #{reading_text}"
              return @role_sequence
            else
              debug :matching, "Using existing role sequence for new reading '#{reading_text}'"
            end
          end
          if @fact_type.all_reading.
            detect do |r|
              r.text == reading_text and
              r.role_sequence.all_role_ref_in_order.map{|rr| rr.role.object_type} ==
                @role_sequence.all_role_ref_in_order.map{|rr| rr.role.object_type}
            end
            # raise "Reading '#{@reading.expand}' already exists, so why are we creating a duplicate (with #{extra_adjectives.inspect})?"
          else
            constellation.Reading(@fact_type, @fact_type.all_reading.size, :role_sequence => @role_sequence, :text => reading_text)
          end
          @role_sequence
        end

        def make_embedded_constraints vocabulary
          var_refs.each do |var_ref|
            next unless var_ref.quantifier
            # puts "Quantifier #{var_ref.inspect} not implemented as a presence constraint"
            var_ref.make_embedded_presence_constraint vocabulary
          end

          if @qualifiers && @qualifiers.size > 0
            # We shouldn't make a new ring constraint if there's already one over this ring.
            existing_rcs = 
              @role_sequence.all_role_ref.map{|rr| rr.role.all_ring_constraint.to_a }.flatten.uniq
            unless existing_rcs[0]
              rc = RingConstraint.new(@role_sequence, @qualifiers)
              rc.vocabulary = vocabulary
              rc.constellation = vocabulary.constellation
              rc.compile
            else
              # Ignore the fact that the ring might be of a different type.
            end

            # REVISIT: Check maybe and other qualifiers:
            debug :constraint, "Need to make constraints for #{@qualifiers*', '}" if @qualifiers.size > 0
          end
        end

        def is_naked_object_type
          @phrases.size == 1 && var_refs.size == 1
        end

      end

      # An instance of ClauseMatchSideEffects is created when the compiler matches an existing fact type.
      # It captures the details that have to be adjusted for the match to be regarded a success.
      class ClauseMatchSideEffect
        attr_reader :phrase, :role_ref, :num, :absorbed_precursors, :absorbed_followers, :common_supertype, :residual_adjectives

        def initialize phrase, role_ref, num, absorbed_precursors, absorbed_followers, common_supertype, residual_adjectives
          @phrase = phrase
          @role_ref = role_ref
          @num = num
          @absorbed_precursors = absorbed_precursors
          @absorbed_followers = absorbed_followers
          @common_supertype = common_supertype
          @residual_adjectives = residual_adjectives
          debug :matching_fails, "Saving side effects for #{@phrase.term}, absorbs #{@absorbed_precursors}/#{@absorbed_followers}#{@common_supertype ? ', join over supertype '+ @common_supertype.name : ''}" if @absorbed_precursors+@absorbed_followers+(@common_supertype ? 1 : 0) > 0
        end

        def cost
          absorbed_precursors + absorbed_followers + (common_supertype ? 1 : 0)
        end

        def to_s
          "#{@phrase.inspect} absorbs #{@absorbed_precursors||0}/#{@absorbed_followers||0} at #{@num}#{@common_supertype && ' super '+@common_supertype.name}#{@residual_adjectives ? ' with residual adjectives' : ''}"
        end
      end

      class ClauseMatchSideEffects
        attr_reader :residual_adjectives
        attr_reader :fact_type
        attr_reader :role_side_effects    # One array of values per VarRef matched, in order

        def initialize fact_type, clause, residual_adjectives, role_side_effects
          @fact_type = fact_type
          @clause = clause
          @residual_adjectives = residual_adjectives
          @role_side_effects = role_side_effects
        end

        def to_s
          'side-effects are [' +
            @role_side_effects.map{|r| r.to_s}*', ' +
            ']' +
            "#{@residual_adjectives ? ' with residual adjectives' : ''}"
        end

        def apply_all &b
          @role_side_effects.reverse.each{ |role_side_effect| b.call(*role_side_effect) }
        end

        def cost
          c = 0
          @role_side_effects.each do |side_effect|
            c += side_effect.cost
          end
          c + (@residual_adjectives ? 1 : 0)
        end

        def describe
          actual_effects =
            @role_side_effects.map do |side_effect|
              ( [side_effect.common_supertype ? "supertype join over #{side_effect.common_supertype.name}" : nil] +
                [side_effect.absorbed_precursors > 0 ? "absorbs #{side_effect.absorbed_precursors} preceding words" : nil] +
                [side_effect.absorbed_followers > 0 ? "absorbs #{side_effect.absorbed_followers} following words" : nil]
              )
            end.flatten.compact*','
          actual_effects.empty? ? "no side effects" : actual_effects
        end
      end

      class VarRef
        attr_reader :term, :trailing_adjective, :quantifier, :function_call, :role_name, :value_constraint, :literal, :nested_clauses
        attr_accessor :leading_adjective, :trailing_adjective
        attr_accessor :player
        attr_accessor :variable
        attr_accessor :clause    # The clause that this VarRef is part of
        attr_accessor :role       # This refers to the ActiveFacts::Metamodel::Role
        attr_accessor :role_ref   # This refers to the ActiveFacts::Metamodel::RoleRef
        attr_accessor :objectification_of # If nested_clauses is set, this is the fact type it objectifies
        attr_reader :embedded_presence_constraint   # This refers to the ActiveFacts::Metamodel::PresenceConstraint
        attr_writer :leading_adjective
        attr_writer :role_name    # For assigning subscript when found in identifying roles list

        def initialize term, leading_adjective = nil, trailing_adjective = nil, quantifier = nil, function_call = nil, role_name = nil, value_constraint = nil, literal = nil, nested_clauses = nil
          @term = term
          @leading_adjective = leading_adjective
          @trailing_adjective = trailing_adjective
          @quantifier = quantifier
          # @function_call = function_call # Not used or implemented
          @role_name = role_name
          @value_constraint = value_constraint
          @literal = literal
          @nested_clauses = nested_clauses
        end

        def inspect
          to_s
        end

        def to_s
          "{#{
            @quantifier && @quantifier.inspect+' '
          }#{
            @leading_adjective && @leading_adjective.sub(/ |$/,'- ').sub(/ *$/,' ')
          }#{
            @term
          }#{
            @trailing_adjective && ' '+@trailing_adjective.sub(/(.* |^)/, '\1-')
          }#{
            @role_name and @role_name.is_a?(Integer) ? "(#{@role_name})" : " (as #{@role_name})"
          }#{
            @literal && ' '+@literal.inspect
          }#{
            @value_constraint && ' '+@value_constraint.to_s
          }}"
        end

        def <=>(other)
          ( 4*(@term <=> other.term) +
            2*((@leading_adjective||'') <=> (other.leading_adjective||'')) +
            1*((@trailing_adjective||'') <=> (other.trailing_adjective||''))
          ) <=> 0
        end

        def includes_literals
          @nested_clauses && @nested_clauses.detect{|oj| oj.includes_literals}
        end

        def identify_player context
          @player = context.object_type @term
          raise "ObjectType #{@term} unrecognised" unless @player
          context.player_by_role_name[@role_name] = player if @role_name
          @player
        end

        def uses_role_name?
          @term != @player.name
        end

        def key
          if @role_name
            key = [@term, @role_name]         # Defines a role name
          elsif uses_role_name?
            key = [@player.name, @term]       # Uses a role name
          else
            l = @leading_adjective
            t = @trailing_adjective
            key = [!l || l.empty? ? nil : l, @term, !t || t.empty? ? nil : t]
            key
          end
        end

        def bind context
          if role_name = @role_name
            # Omit these tests to see if anything evil eventuates:
            #if @leading_adjective || @trailing_adjective
            #  raise "Role reference may not have adjectives if it defines a role name or uses a subscript: #{inspect}"
            #end
          else
            if uses_role_name?
              if @leading_adjective || @trailing_adjective
                raise "Role reference may not have adjectives if it uses a role name: #{inspect}"
              end
              role_name = @term
            end
          end
          @variable = (context.variables[key] ||= Variable.new(@player, role_name))
          @variable.refs << self
          @variable
        end

        def unbind context
          # The key has changed.
          @variable.refs.delete(self)
          if @variable.refs.empty?
            # Remove the variable from the context if this was the last reference
            context.variables.delete_if {|k,v| v == @variable }
          end
          @variable = nil
        end

        def rebind(context)
          unbind context
          bind context
        end

        def rebind_to(context, other_var_ref)
          debug :binding, "Rebinding #{inspect} to #{other_var_ref.inspect}"

          old_variable = variable   # Remember to move all refs across
          unbind(context)

          new_variable = other_var_ref.variable
          [self, *old_variable.refs].each do |ref|
            ref.variable = new_variable
            new_variable.refs << ref
          end
          old_variable.rebound_to = new_variable
        end

        # These are called when we successfully match a fact type reading that has relevant adjectives:
        def wipe_leading_adjective
          @leading_adjective = nil
        end

        def wipe_trailing_adjective
          @trailing_adjective = nil
        end

        def find_pc_over_roles(roles)
          return nil if roles.size == 0 # Safeguard; this would chuck an exception otherwise
          roles[0].all_role_ref.each do |role_ref|
            next if role_ref.role_sequence.all_role_ref.map(&:role) != roles
            pc = role_ref.role_sequence.all_presence_constraint.single  # Will return nil if there's more than one.
            #puts "Existing PresenceConstraint matches those roles!" if pc
            return pc if pc
          end
          nil
        end

        def make_embedded_presence_constraint vocabulary
          raise "No Role for embedded_presence_constraint" unless @role_ref
          fact_type = @role_ref.role.fact_type
          constellation = vocabulary.constellation

          debug :constraint, "Processing embedded constraint #{@quantifier.inspect} on #{@role_ref.role.object_type.name} in #{fact_type.describe}" do
            # Preserve the role order of the clause, excluding this role:
            constrained_roles = (@clause.var_refs-[self]).map{|vr| vr.role_ref.role}
            if constrained_roles.empty?
              debug :constraint, "Quantifier over unary role has no effect"
              return
            end
            constraint = find_pc_over_roles(constrained_roles)
            if constraint
              debug :constraint, "Setting max frequency to #{@quantifier.max} for existing constraint #{constraint.object_id} over #{constraint.role_sequence.describe} in #{fact_type.describe}"
              raise "Conflicting maximum frequency for constraint" if constraint.max_frequency && constraint.max_frequency != @quantifier.max
              constraint.max_frequency = @quantifier.max
              raise "Conflicting minimum frequency for constraint" if constraint.min_frequency && constraint.min_frequency != @quantifier.min
              constraint.min_frequency = @quantifier.min
            else
              role_sequence = constellation.RoleSequence(:new)
              constrained_roles.each_with_index do |constrained_role, i|
                role_ref = constellation.RoleRef(role_sequence, i, :role => constrained_role)
              end
              constraint = constellation.PresenceConstraint(
                  :new,
                  :vocabulary => vocabulary,
                  :role_sequence => role_sequence,
                  :is_mandatory => @quantifier.min && @quantifier.min > 0,  # REVISIT: Check "maybe" qualifier?
                  :max_frequency => @quantifier.max,
                  :min_frequency => @quantifier.min
                )
              debug :constraint, "Made new PC min=#{@quantifier.min.inspect} max=#{@quantifier.max.inspect} constraint #{constraint.object_id} over #{(e = fact_type.entity_type) ? e.name : role_sequence.describe} in #{fact_type.describe}"
              @quantifier.enforcement.compile(constellation, constraint) if @quantifier.enforcement
              @embedded_presence_constraint = constraint
            end
            constraint
          end

        end

        def leaf_operand
          self
        end

        def result(context = nil)
          self
        end
      end

      class Quantifier
        attr_accessor :enforcement
        attr_reader :min, :max

        def initialize min, max, enforcement = nil
          @min = min
          @max = max
          @enforcement = enforcement
        end

        def inspect
          "[#{@min}..#{@max}]"
        end
      end

    end
  end
end
