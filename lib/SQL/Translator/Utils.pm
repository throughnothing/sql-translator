package SQL::Translator::Utils;

use strict;
use warnings;
use Digest::SHA qw( sha1_hex );
use File::Spec;

our $VERSION = '1.59';
our $DEFAULT_COMMENT = '-- ';

use base qw(Exporter);
our @EXPORT_OK = qw(
    debug normalize_name header_comment parse_list_arg truncate_id_uniquely
    $DEFAULT_COMMENT parse_mysql_version parse_dbms_version
    ddl_parser_instance
);
use constant COLLISION_TAG_LENGTH => 8;

sub debug {
    my ($pkg, $file, $line, $sub) = caller(0);
    {
        no strict qw(refs);
        return unless ${"$pkg\::DEBUG"};
    }

    $sub =~ s/^$pkg\:://;

    while (@_) {
        my $x = shift;
        chomp $x;
        $x =~ s/\bPKG\b/$pkg/g;
        $x =~ s/\bLINE\b/$line/g;
        $x =~ s/\bSUB\b/$sub/g;
        #warn '[' . $x . "]\n";
        print STDERR '[' . $x . "]\n";
    }
}

sub normalize_name {
    my $name = shift or return '';

    # The name can only begin with a-zA-Z_; if there's anything
    # else, prefix with _
    $name =~ s/^([^a-zA-Z_])/_$1/;

    # anything other than a-zA-Z0-9_ in the non-first position
    # needs to be turned into _
    $name =~ tr/[a-zA-Z0-9_]/_/c;

    # All duplicated _ need to be squashed into one.
    $name =~ tr/_/_/s;

    # Trim a trailing _
    $name =~ s/_$//;

    return $name;
}

sub header_comment {
    my $producer = shift || caller;
    my $comment_char = shift;
    my $now = scalar localtime;

    $comment_char = $DEFAULT_COMMENT
        unless defined $comment_char;

    my $header_comment =<<"HEADER_COMMENT";
${comment_char}
${comment_char}Created by $producer
${comment_char}Created on $now
${comment_char}
HEADER_COMMENT

    # Any additional stuff passed in
    for my $additional_comment (@_) {
        $header_comment .= "${comment_char}${additional_comment}\n";
    }

    return $header_comment;
}

sub parse_list_arg {
    my $list = UNIVERSAL::isa( $_[0], 'ARRAY' ) ? shift : [ @_ ];

    #
    # This protects stringification of references.
    #
    if ( @$list && ref $list->[0] ) {
        return $list;
    }
    #
    # This processes string-like arguments.
    #
    else {
        return [
            map { s/^\s+|\s+$//g; $_ }
            map { split /,/ }
            grep { defined && length } @$list
        ];
    }
}

sub truncate_id_uniquely {
    my ( $desired_name, $max_symbol_length ) = @_;

    return $desired_name
      unless defined $desired_name && length $desired_name > $max_symbol_length;

    my $truncated_name = substr $desired_name, 0,
      $max_symbol_length - COLLISION_TAG_LENGTH - 1;

    # Hex isn't the most space-efficient, but it skirts around allowed
    # charset issues
    my $digest = sha1_hex($desired_name);
    my $collision_tag = substr $digest, 0, COLLISION_TAG_LENGTH;

    return $truncated_name
         . '_'
         . $collision_tag;
}


sub parse_mysql_version {
    my ($v, $target) = @_;

    return undef unless $v;

    $target ||= 'perl';

    my @vers;

    # X.Y.Z style
    if ( $v =~ / ^ (\d+) \. (\d{1,3}) (?: \. (\d{1,3}) )? $ /x ) {
        push @vers, $1, $2, $3;
    }

    # XYYZZ (mysql) style
    elsif ( $v =~ / ^ (\d) (\d{2}) (\d{2}) $ /x ) {
        push @vers, $1, $2, $3;
    }

    # XX.YYYZZZ (perl) style or simply X
    elsif ( $v =~ / ^ (\d+) (?: \. (\d{3}) (\d{3}) )? $ /x ) {
        push @vers, $1, $2, $3;
    }
    else {
        #how do I croak sanely here?
        die "Unparseable MySQL version '$v'";
    }

    if ($target eq 'perl') {
        return sprintf ('%d.%03d%03d', map { $_ || 0 } (@vers) );
    }
    elsif ($target eq 'mysql') {
        return sprintf ('%d%02d%02d', map { $_ || 0 } (@vers) );
    }
    else {
        #how do I croak sanely here?
        die "Unknown version target '$target'";
    }
}

sub parse_dbms_version {
    my ($v, $target) = @_;

    return undef unless $v;

    my @vers;

    # X.Y.Z style
    if ( $v =~ / ^ (\d+) \. (\d{1,3}) (?: \. (\d{1,3}) )? $ /x ) {
        push @vers, $1, $2, $3;
    }

    # XX.YYYZZZ (perl) style or simply X
    elsif ( $v =~ / ^ (\d+) (?: \. (\d{3}) (\d{3}) )? $ /x ) {
        push @vers, $1, $2, $3;
    }
    else {
        #how do I croak sanely here?
        die "Unparseable database server version '$v'";
    }

    if ($target eq 'perl') {
        return sprintf ('%d.%03d%03d', map { $_ || 0 } (@vers) );
    }
    elsif ($target eq 'native') {
        return join '.' => grep defined, @vers;
    }
    else {
        #how do I croak sanely here?
        die "Unknown version target '$target'";
    }
}

#my ($parsers_libdir, $checkout_dir);
sub ddl_parser_instance {

    my $type = shift;

    # it may differ from our caller, even though currently this is not the case
    eval "require SQL::Translator::Parser::$type"
        or die "Unable to load grammar-spec container SQL::Translator::Parser::$type:\n$@";

    # handle DB2 in a special way, since the grammar source was lost :(
    if ($type eq 'DB2') {
      require SQL::Translator::Parser::DB2::Grammar;
      return SQL::Translator::Parser::DB2::Grammar->new;
    }

    require Parse::RecDescent;
    return Parse::RecDescent->new(do {
      no strict 'refs';
      ${"SQL::Translator::Parser::${type}::GRAMMAR"}
        || die "No \$SQL::Translator::Parser::${type}::GRAMMAR defined, unable to instantiate PRD parser\n"
    });

# this is disabled until RT#74593 is resolved
=begin for general sadness

    unless ($parsers_libdir) {

        # are we in a checkout?
        if ($checkout_dir = _find_co_root()) {
            $parsers_libdir = File::Spec->catdir($checkout_dir, 'share', 'PrecompiledParsers');
        }
        else {
            require File::ShareDir;
            $parsers_libdir = File::Spec->catdir(
              File::ShareDir::dist_dir('SQL-Translator'),
              'PrecompiledParsers'
            );
        }

        unshift @INC, $parsers_libdir;
    }

    my $precompiled_mod = "Parse::RecDescent::DDL::SQLT::$type";

    # FIXME FIXME FIXME
    # Parse::RecDescent has horrible architecture where each precompiled parser
    # instance shares global state with all its siblings
    # What we do here is gross, but scarily efficient - the parser compilation
    # is much much slower than an unload/reload cycle
    require Class::Unload;
    Class::Unload->unload($precompiled_mod);

    # There is also a sub-namespace that P::RD uses, but simply unsetting
    # $^W to stop redefine warnings seems to be enough
    #Class::Unload->unload("Parse::RecDescent::$precompiled_mod");

    eval "local \$^W; require $precompiled_mod" or do {
        if ($checkout_dir) {
            die "Unable to find precompiled grammar for $type - run Makefile.PL to generate it\n";
        }
        else {
            die "Unable to load precompiled grammar for $type... this is not supposed to happen if you are not in a checkout, please file a bugreport:\n$@"
        }
    };

    my $grammar_spec_fn = $INC{"SQL/Translator/Parser/$type.pm"};
    my $precompiled_fn = $INC{"Parse/RecDescent/DDL/SQLT/$type.pm"};

    if (
        (stat($grammar_spec_fn))[9]
            >
        (stat($precompiled_fn))[9]
    ) {
        die (
            "Grammar spec '$grammar_spec_fn' is newer than precompiled parser '$precompiled_fn'"
          . ($checkout_dir
                ? " - run Makefile.PL to regenerate stale versions\n"
                : "... this is not supposed to happen if you are not in a checkout, please file a bugreport\n"
            )
        );
    }

    return $precompiled_mod->new;
=cut

}

# Try to determine the root of a checkout/untar if possible
# or return undef
sub _find_co_root {

    my @mod_parts = split /::/, (__PACKAGE__ . '.pm');
    my $rel_path = join ('/', @mod_parts);  # %INC stores paths with / regardless of OS

    return undef unless ($INC{$rel_path});

    # a bit convoluted, but what we do here essentially is:
    #  - get the file name of this particular module
    #  - do 'cd ..' as many times as necessary to get to lib/SQL/Translator/../../..

    my $root = (File::Spec::Unix->splitpath($INC{$rel_path}))[1];
    for (1 .. @mod_parts) {
        $root = File::Spec->catdir($root, File::Spec->updir);
    }

    return ( -f File::Spec->catfile($root, 'Makefile.PL') )
        ? $root
        : undef
    ;
}

1;

=pod

=head1 NAME

SQL::Translator::Utils - SQL::Translator Utility functions

=head1 SYNOPSIS

  use SQL::Translator::Utils qw(debug);
  debug("PKG: Bad things happened");

=head1 DESCSIPTION

C<SQL::Translator::Utils> contains utility functions designed to be
used from the other modules within the C<SQL::Translator> modules.

Nothing is exported by default.

=head1 EXPORTED FUNCTIONS AND CONSTANTS

=head2 debug

C<debug> takes 0 or more messages, which will be sent to STDERR using
C<warn>.  Occurances of the strings I<PKG>, I<SUB>, and I<LINE>
will be replaced by the calling package, subroutine, and line number,
respectively, as reported by C<caller(1)>.

For example, from within C<foo> in F<SQL/Translator.pm>, at line 666:

  debug("PKG: Error reading file at SUB/LINE");

Will warn

  [SQL::Translator: Error reading file at foo/666]

The entire message is enclosed within C<[> and C<]> for visual clarity
when STDERR is intermixed with STDOUT.

=head2 normalize_name

C<normalize_name> takes a string and ensures that it is suitable for
use as an identifier.  This means: ensure that it starts with a letter
or underscore, and that the rest of the string consists of only
letters, numbers, and underscores.  A string that begins with
something other than [a-zA-Z] will be prefixer with an underscore, and
all other characters in the string will be replaced with underscores.
Finally, a trailing underscore will be removed, because that's ugly.

  normalize_name("Hello, world");

Produces:

  Hello_world

A more useful example, from the C<SQL::Translator::Parser::Excel> test
suite:

  normalize_name("silly field (with random characters)");

returns:

  silly_field_with_random_characters

=head2 header_comment

Create the header comment.  Takes 1 mandatory argument (the producer
classname), an optional comment character (defaults to $DEFAULT_COMMENT),
and 0 or more additional comments, which will be appended to the header,
prefixed with the comment character.  If additional comments are provided,
then a comment string must be provided ($DEFAULT_COMMENT is exported for
this use).  For example, this:

  package My::Producer;

  use SQL::Translator::Utils qw(header_comment $DEFAULT_COMMENT);

  print header_comment(__PACKAGE__,
                       $DEFAULT_COMMENT,
                       "Hi mom!");

produces:

  --
  -- Created by My::Prodcuer
  -- Created on Fri Apr 25 06:56:02 2003
  --
  -- Hi mom!
  --

Note the gratuitous spacing.

=head2 parse_list_arg

Takes a string, list or arrayref (all of which could contain
comma-separated values) and returns an array reference of the values.
All of the following will return equivalent values:

  parse_list_arg('id');
  parse_list_arg('id', 'name');
  parse_list_arg( 'id, name' );
  parse_list_arg( [ 'id', 'name' ] );
  parse_list_arg( qw[ id name ] );

=head2 truncate_id_uniquely

Takes a string ($desired_name) and int ($max_symbol_length). Truncates
$desired_name to $max_symbol_length by including part of the hash of
the full name at the end of the truncated name, giving a high
probability that the symbol will be unique. For example,

  truncate_id_uniquely( 'a' x 100, 64 )
  truncate_id_uniquely( 'a' x 99 . 'b', 64 );
  truncate_id_uniquely( 'a' x 99,  64 )

Will give three different results; specifically:

  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_7f900025
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_6191e39a
  aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa_8cd96af2

=head2 $DEFAULT_COMMENT

This is the default comment string, '-- ' by default.  Useful for
C<header_comment>.

=head2 parse_mysql_version

Used by both L<Parser::MySQL|SQL::Translator::Parser::MySQL> and
L<Producer::MySQL|SQL::Translator::Producer::MySQL> in order to provide a
consistent format for both C<< parser_args->{mysql_parser_version} >> and
C<< producer_args->{mysql_version} >> respectively. Takes any of the following
version specifications:

  5.0.3
  4.1
  3.23.2
  5
  5.001005  (perl style)
  30201     (mysql style)

=head2 parse_dbms_version

Takes a version string (X.Y.Z) or perl style (XX.YYYZZZ) and a target ('perl'
or 'native') transforms the string to the given target style.
to

=head1 AUTHORS

Darren Chamberlain E<lt>darren@cpan.orgE<gt>,
Ken Y. Clark E<lt>kclark@cpan.orgE<gt>.

=cut
