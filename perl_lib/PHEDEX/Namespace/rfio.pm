package PHEDEX::Namespace::rfio;

=head1 NAME

PHEDEX::Namespace::rfio - implement namespace framework for rfio protocol

=cut

use strict;
use warnings;
no strict 'refs';
use base 'PHEDEX::Namespace::Common';
use PHEDEX::Core::Loader;
use Data::Dumper;
use Getopt::Long;

sub new
{
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my %h = @_;
  my ($help,%params,%options);

# Params and options are module-specific
  %params = (
		VERBOSE	 => 0,
		DEBUG	 => 0,
		CACHE	 => undef,
		NOCACHE	 => 0,
		RFIO_USE_CASTOR_V2 => 'YES',
            );
  %options = (
		'help'		=> \$help,
		'verbose!'	=> \$params{VERBOSE},
		'debug+'	=> \$params{DEBUG},
		'nocache'	=> \$params{NOCACHE},
		'rfio_use_castor_v2' => \$params{RFIO_USE_CASTOR_V2},
             );
  GetOptions(%options);
  my $self = \%params;
  bless($self, $class);
  $self->SUPER::_init( NAMESPACE => __PACKAGE__ );
  map { $self->{$_} = $h{$_} } keys %h;

  $self->{ENV} = "RFIO_USE_CASTOR_V2=" . ($self->{RFIO_USE_CASTOR_V2} || '');
  $self->SUPER::_init_commands;
  print Dumper($self) if $self->{DEBUG};
  $self->Help if $help;
  return $self;
}

sub Help
{
  my $self = shift;
  print "\n Usage for ",__PACKAGE__,"\n";
  print <<EOF;

 This module takes the standard options:
 --help, --debug, --(no)verbose

 Commands known to this module:
EOF

  $self->SUPER::_help();
}

1;
