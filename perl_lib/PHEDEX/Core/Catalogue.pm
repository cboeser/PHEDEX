package PHEDEX::Core::Catalogue;

=head1 NAME

PHEDEX::Core::Catalogue - a drop-in replacement for Toolkit/UtilsCatalogue

=cut

use strict;
use warnings;
use base 'Exporter';
our @EXPORT = qw(pfnLookup lfnLookup storageRules dbStorageRules applyStorageRules);
use XML::Parser;
use PHEDEX::Core::DB;

# Cache of already parsed storage rules.  Keyed by rule type, then by
# file name, and stores as value the file time stamp and parsed result.
my %cache;

# Map a LFN to a PFN using a storage mapping catalogue.  The first
# argument is either a single scalar LFN, or a reference to an array
# of LFNs.  The second and third arguments are desired protocol and
# destination node making query ("direct", "local" meaning direct
# access from the system agent is running on.  The last argument is
# the location of the storage catalogue.
#
# If given a single LFN, returns a single PFN, or undef if the name
# cannot be mapped.  If given an array of LFNs, returns a hash of
# LFN => PFN mappings; the hash will have an entry for every LFN,
# but the value will be undef if no PFN could be constructed.
sub pfnLookup
{
    my ($input, $proto, $dest, $mapping, $custodial) = @_;
    my @args = (&storageRules ($mapping, 'lfn-to-pfn'), $proto, $dest, 'pre');
    if (ref $input)
    {
	return { map { $_ => [&applyStorageRules(@args, $_, $custodial)] } @$input };
    }
    else
    {
	return &applyStorageRules(@args, $input, $custodial);
    }
}

# Map a PFN to a LFN using a storage mapping catalogue.  This is like
# pfnLookup, but simply works the other way around.
sub lfnLookup
{
    my ($input, $proto, $dest, $mapping, $custodial) = @_;
    my @args = (&storageRules ($mapping, 'pfn-to-lfn'), $proto, $dest, 'post');
    if (ref $input)
    {
	return { map { $_ => [&applyStorageRules(@args, $_, $custodial)] } @$input };
    }
    else
    {
	return &applyStorageRules(@args, $input, $custodial);
    }
}

# Read in rules for storage mappings.  Returns a reference to a hash
# by protocol, each of which points to an array of rules of $kind in
# the order in which they appeared in the <storage-mapping>.
#
# The storage rules are expected to be of the form:
#   all::   <storage-mapping> rule+ </storage-mapping>
#   rule::  <lfn-to-pfn args> | <pfn-to-lfn args>
#   args::  protocol="..." [destination-match="..."] [chain="..."]
#           path-match="..." result="..."
#
# More than one rule may be specified; the first applicable one wins.
# The value for the "protocol" argument is required and is compared
# literally to the protocol given by the client.  The "destination-
# match" argument is, if given, used as a perl regular expression to
# match the client's destination argument.  If the "chain" argument
# is present, it designates another protocol whose rules are applied
# to the file name on input (lfn-to-pfn) or ouput (pfn-to-lfn) of
# the current rule.
# 
# If the protocol and destination match, the file name is matched
# against the perl regular expression "path-match".   If matched,
# the name is transformed according to "result", following the
# conventions of the perl s/// operator.  Once the path has been
# matched rule processing ends.
#
# Example:
#   <storage-mapping>
#     <lfn-to-pfn protocol="direct"
#       path-match="/+(.*)" result="/castor/cern.ch/cms/$1"/>
#     <lfn-to-pfn protocol="srm" chain="direct"
#       path-match="(.*)" result="srm://srm.cern.ch/srm/managerv1?SFN=$1"/>
#
#     <pfn-to-lfn protocol="direct"
#       path-match="/+castor/cern\.ch/cms/(.*)" result="/$1"/>
#     <pfn-to-lfn protocol="srm" chain="direct"
#       path-match=".*\?SFN=(.*)" result="$1"/>
#   </storage-mapping>
#
# This would map LFN=/foo PROTO=srm DEST=(any) to
#   srm://srm.cern.ch/srm/managerv1?SFN=/castor/cern.ch/cms/foo.
sub storageRules
{
    my ($file, $kind) = @_;

    # Check if we have a valid cached result
    if (exists $cache{$kind}{$file})
    {
	my $modtime = (stat($file))[9];
	return $cache{$kind}{$file}{RULES}
	    if $cache{$kind}{$file}{MODTIME} == $modtime;
    }

    # Parse the catalogue and remove top-level white space
    my $tree = (new XML::Parser (Style => "Tree"))->parsefile ($file);
    splice (@$tree, 0, 2) while ($$tree[0] eq "0" && $$tree[1] =~ /^\s*$/s);
    splice (@$tree, -2) while ($$tree[scalar @$tree- 2] eq "0"
				&& $$tree[scalar @$tree- 1] =~ /^\s*$/s);

    # Verify we understand the storage catalogue structure
    die "$file: expected one top-level element\n" if scalar @$tree != 2;
    die "$file: expected storage-mapping element\n" if $$tree[0] ne 'storage-mapping';

    # Collect the rules we wanted
    my ($attrs, @rules) = @{$$tree[1]};
    my $result = {};
    while (@rules)
    {
	my ($element, $value) = splice(@rules, 0, 2);
	next if $element ne $kind;
	# $$value[0]{'path-match'} = do { my $z = $$value[0]{'path-match'}; qr/$z/ };
	# $$value[0]{'result'} = do { my $z = $$value[0]{'result'}; eval "sub { \$_[0] =~ s!\$_[1]!$z! }" };
	push (@{$$result{$$value[0]{protocol}}}, $$value[0]);
    }

    # Cache the result
    $cache{$kind}{$file} = { MODTIME => (stat($file))[9], RULES => $result };

    # Return to the caller
    return $result;
}

# Apply storage mapping rules to a file name.  See "storageRules" for details.
#
# new optional parameters: $custodial and $space_token
#
# if $custodial is not defined, it is assumed to be 'n'.
# if "is-custodial" is not defined in the rule, it is assumed to be 'n'.
# $custodial has to match "is-custodial"
#
# if the end result of applying current rule produces a defined
# space-toke, return it; otherwise, return the value passed-in
# through the argument $space_token
#
# applyStorageRules() returns ($space_token, $name)
sub applyStorageRules
{
    my ($rules, $proto, $dest, $chain, $givenname, $custodial, $space_token) = @_;

    # Bail out if $givenname is undef
    if (! defined ($givenname))
    {
        return undef;
    }

    # if omitted, $custodial is default to "n"
    if (! defined ($custodial))
    {
        $custodial = "n";
    }

    foreach my $rule (@{$$rules{$proto}})
    {
	my $name = $givenname;

	# take care of custodial flag
        #
        # if is-custodial is undefined, it matches any $custodial value
        # if is-custodial is defined, it has to match $custodial
        next if ($$rule{'is-custodial'} && ($$rule{'is-custodial'} ne $custodial));

	next if (defined $$rule{'destination-match'}
		 && $dest !~ m!$$rule{'destination-match'}!);
	if (exists $$rule{'chain'} && $chain eq 'pre') {
	    ($space_token, $name) = &applyStorageRules($rules, $$rule{'chain'}, $dest, $chain, $name, $custodial, $space_token);
	}

        # It's a failure if the name is undef
        next if (!defined ($name));

	if ($name =~ m!$$rule{'path-match'}!)
	{
	    if (ref $$rule{'result'} eq 'CODE')
	    {
		&{$$rule{'result'}} ($name, $$rule{'path-match'});
	    }
	    else
	    {
		eval "\$name =~ s!\$\$rule{'path-match'}!$$rule{'result'}!";
	    }
            if ($$rule{'space-token'})
            {
                $space_token = $$rule{'space-token'};
            }
	    ($space_token, $name) = &applyStorageRules($rules, $$rule{'chain'}, $dest, $chain, $name, $custodial, $space_token)
		if (exists $$rule{'chain'} && $chain eq 'post');
	    return ($space_token, $name);
	}
	
    }

    return undef;
}


# Fetch TFC rules for the given node and cache it to the given
# hashref.  Cache expiration to be handled outside this function.
sub dbStorageRules
{
    my ($dbh, $cats, $node) = @_;

    # If we haven't yet built the catalogue, fetch from the database.
    if (! exists $$cats{$node})
    {
        $$cats{$node} = {};

        my $q = &dbexec($dbh, qq{
	    select protocol, chain, destination_match, path_match, result_expr, is_custodial, space_token
	    from t_xfer_catalogue
	    where node = :node and rule_type = 'lfn-to-pfn'
	    order by rule_index asc},
	    ":node" => $node);

        while (my ($proto, $chain, $dest, $path, $result, $custodial, $space_token) = $q->fetchrow())
        {
	    # Check the pattern is valid.  If not, abort.
            my $pathrx = eval { qr/$path/ };
	    if ($@) {
		$$cats{$node} = {};
		die "invalid path pattern for node=$node:  $@\n";
	    }

            my $destrx = defined $dest ? eval { qr/$dest/ } : undef;
	    if ($@) {
		$$cats{$node} = {};
		die "invalid dest pattern for node=$node:  $@\n";
	    }

	    # Add the rule to our list.
	    push(@{$$cats{$node}{$proto}}, {
		    (defined $chain ? ('chain' => $chain) : ()),
		    (defined $dest ? ('destination-match' => $destrx) : ()),
                    (defined $custodial ? ('is-custodial' => $custodial) : ()),
                    (defined $space_token ? ('space-token' => $space_token) : ()),
		    'path-match' => $pathrx,
		    'result' => eval "sub { \$_[0] =~ s!\$_[1]!$result! }" });
        }
    }

    return $$cats{$node};
}


1;
