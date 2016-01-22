use Dice::Roller::Rollable;
use Dice::Roller::Selector;

unit class Dice::Roller does Dice::Roller::Rollable;

# Grammar defining a dice string:-
# ------------------------------

grammar DiceGrammar {
	token                  TOP { ^ <expression> [ ';' \s* <expression> ]* ';'? $ }

	proto rule      expression {*}
	proto token         add_op {*}
	proto token       selector {*}

	rule   expression:sym<add> { <add_op>? <term> [ <add_op> <term> ]* }
	token                 term { <roll> | <modifier> }
	token        add_op:sym<+> { <sym> }
	token        add_op:sym<-> { <sym> }

	regex                 roll { <quantity> <die> <selector>* }
	token             quantity { \d+ }
	token                  die { d(\d+) }
   token     selector:sym<kh> { <sym>(\d+) }    # keep highest n
   token     selector:sym<kl> { <sym>(\d+) }    # keep lowest n
   token     selector:sym<dh> { <sym>(\d+) }    # drop highest n
   token     selector:sym<dl> { <sym>(\d+) }    # drop lowest n

	regex             modifier { (\d+) }
}

# Other classes we use internally to represent the parsed dice string:-
# -------------------------------------------------------------------

# A single polyhedron.
class Die does Dice::Roller::Rollable {
	has Int $.faces;		# All around me different faces I see
	has @.distribution;	# We will use this when rolling; this allows for non-linear dice to be added later.
	has $.value is rw;	# Which face is showing, if any?

	submethod BUILD(:$!faces) {
		# Initialise the distribution of values with a range of numbers from 1 to the number of faces the die has.
		@!distribution = 1..$!faces;
	}

	method contents {
		return [];
	}
	
	method roll {
		$!value = @.distribution.pick;
		return self;
	}

	method set-max {
		$!value = @.distribution.max;
		return self;
	}

	method set-min {
		$!value = @.distribution.min;
		return self;
	}

	method is-max returns Bool {
		return $!value == @.distribution.max;
	}

	method is-min returns Bool {
		return $!value == @.distribution.min;
	}

	method total returns Int {
		return $!value // 0;
	}

	method Num {
		return $!value;
	}

	method Str {
		return "[$!value]" if $!value;
		return "(d$!faces)";
	}
}

multi infix:<cmp>(Die $a, Die $b) {
	return $a.value cmp $b.value;
}


# Some fixed value adjusting a roll's total outcome.
class Modifier does Dice::Roller::Rollable {
	has Int $.value is required;

	method contents {
		return [];
	}

	method is-max {
		return True;
	}

	method is-min {
		return True;
	}

	method total returns Int {
		return $!value;
	}

	method Str {
		return $!value.Str;
	}
}

# A thing that selects or adjusts certain dice from a Roll.
class KeepHighest does Dice::Roller::Selector {
	has Int $.num = 1;

	method select ($roll) {
		say "Selecting highest $.num rolls from '$roll'";
		$roll.dice = $roll.dice.sort;
	}
}

# A roll of one or more polyhedra, with some rule about how we combine them.
class Roll does Dice::Roller::Rollable {
	has Int $.quantity;
	has Die @.dice is rw;
	has Dice::Roller::Selector @.selectors;

	method contents {
		return @.dice;
	}

	method roll {
		@!dice».roll;
		for @!selectors -> $selector {
			$selector.select(self);
		}
		return self;
	}

	method Str {
		if any(@!dice».value) {
			# one or more dice have been rolled, we don't need to prefix our quantity, they'll have literal values.
			return join('', @!dice);
		} else {
			# no dice have been rolled, we return a more abstract representation.
			return $!quantity ~ @!dice[0];
		}
	}
}


class Expression does Dice::Roller::Rollable {
	has Pair @.operations;

	method contents {
		return @!operations».value;
	}

	method add(Str $op, Dice::Roller::Rollable $value) {
		@!operations.push( $op => $value );
	}

	# Expression needs to reimplement Total since we can now subtract parts of the roll.
	method total returns Int {
		my $total = 0;
		for @!operations -> $op-pair {
			given $op-pair.key {
				when '+' { $total += $op-pair.value.total }
				when '-' { $total -= $op-pair.value.total }
				default  { die "unhandled Expression type " ~ $op-pair.key }
			}
		}
		return $total;
	}

	method Str {
		my Str $str = "";
		for @!operations -> $op-pair {
			$str ~= $op-pair.key if $str;
			$str ~= $op-pair.value;
		}
		return $str;
	}
}


# Because returning an Array of Expressions doesn't seem to be working well for us,
# let's stick the various (individual) rolls into one of these.
class RollSet does Dice::Roller::Rollable {
	has Dice::Roller::Rollable @.rolls;

	method contents {
		return @!rolls;
	}

	method group-totals returns List {
		return @!rolls».total;
	}

	method Str {
		return join('; ', @!rolls);
	}
}


# Actions used to build our internal representation from the grammar:-
# ------------------------------------------------------------------

class DiceActions {
	method TOP($/) {
		# .parse returns a RollSet with an array of Expression objects,
		# one entry for each of the roll expressions separated by ';' in the string.
		make RollSet.new( rolls => $<expression>».made );
	}

	method expression:sym<add>($/) {
		my $expression = Expression.new;
		my Str $op = '+';

		for $/.caps -> Pair $term_or_op {
			given $term_or_op.key {
				when "term" { 
					my $term = $term_or_op.value;
					$expression.add($op, $term.made);
				}
				when "add_op" { 
					$op = $term_or_op.value.made;
				}
			}
		}
		make $expression;
	}

	method add_op:sym<+>($/) {
		make $/.Str;
	}

	method add_op:sym<->($/) {
		make $/.Str;
	}

	method term($/) {
		make $<roll>.made // $<modifier>.made;
	}

	method roll($/) {
		# While there is only one 'die' token within the 'roll' grammar, we actually want
		# to construct the Roll object with multiple Die objects as appropriate, so that
		# we can roll and remember the face value of individual die.
		my Int $quantity = $<quantity>.made;
		my Die @dice = (1..$quantity).map({ $<die>.made.clone });

		#### TEMP: All rolls are now kh3
		make Roll.new( :$quantity, :@dice, selectors => KeepHighest.new(num => 3) );
	}

	method quantity($/) {
		make $/.Int;
	}

	method die($/) {
		make Die.new( faces => $0.Int );
	}

	method modifier($/) {
		make Modifier.new( value => "$0".Int );
	}
}

# Attributes of a Dice::Roller:-
# ----------------------------

# Attributes are all private by default, and defined with the '!' twigil. But using '.' instead instructs
# Perl 6 to define the $!string attribute and automagically generate a .string *accessor* that can be
# used publically. Note that this accessor will be read-only by default.

has Str $.string is required;
has Match $.match is required;
has RollSet $.rollset is required;

# We define a custom .new method to allow for positional (non-named) parameters:-
method new(Str $string) {
	my $match = DiceGrammar.parse($string, :actions(DiceActions));
	die "Failed to parse '$string'!" unless $match;
	#say "Parsed: ", $match.gist;
	return self.bless(string => $string, match => $match, rollset => $match.made);
}

# Note that in general, doing extra constructor work should happen in the BUILD submethod; doing our own
# special new method here may complicate things in subclasses. But we do want a nice simple constructor,
# and defining our own 'new' seems to be the best way to accomplish this.
# http://doc.perl6.org/language/objects#Object_Construction


method contents {
	return $!rollset;
}

method group-totals returns List {
	return $!rollset.group-totals;
}

method Str {
	return $!rollset.Str;
}

