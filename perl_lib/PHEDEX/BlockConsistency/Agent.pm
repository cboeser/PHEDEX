package PHEDEX::BlockConsistency::Agent;

=head1 NAME

PHEDEX::BlockConsistency::Agent - the Block Consistency Checking agent.

=head1 SYNOPSIS

pending...

=head1 DESCRIPTION

pending...

=head1 SEE ALSO...

L<PHEDEX::Core::Agent|PHEDEX::Core::Agent>, 
L<PHEDEX::BlockConsistency::SQL|PHEDEX::BlockConsistency::SQL>.

=cut
use strict;
use warnings;
use base 'PHEDEX::Core::Agent', 'PHEDEX::BlockConsistency::SQL', 'PHEDEX::Core::Logging';

use File::Path;
use File::Basename;
use Cwd;
use Data::Dumper;
use PHEDEX::Core::Command;
use PHEDEX::Core::Timing;
use PHEDEX::Core::Catalogue ( qw / storageRules dbStorageRules applyStorageRules / );
use PHEDEX::Core::DB;
use PHEDEX::BlockConsistency::Core;
use PHEDEX::Namespace;
use PHEDEX::Core::Loader;
use POE;
use POE::Queue::Array;

our %params =
	(
	  WAITTIME	=> 300 + rand(15),	# Agent activity cycle
	  PROTOCOL	=> 'direct',		# File access protocol
	  STORAGEMAP	=> undef,		# Storage path mapping rules
	  USE_SRM	=> 'n',			# Use SRM or native technology?
	  RFIO_USES_RFDIR => 0,			# Use rfdir instead of nsls?
	  PRELOAD	=> undef,		# Library to preload for dCache?
	  ME => 'BlockDownloadVerify',		# Name for the record...
	  NAMESPACE	=> undef,
	  max_priority	=> 0,			# max of active requests
	  QUEUE_LENGTH	=> 40,			# length of queue per cycle
	);

sub new
{
  my $proto = shift;
  my $class = ref($proto) || $proto;
  my $self  = $class->SUPER::new(%params,@_);
  $self->{bcc} = PHEDEX::BlockConsistency::Core->new();
  $self->{QUEUE} = POE::Queue::Array->new();
  $self->{NAMESPACE} =~ s%['"]%%g if $self->{NAMESPACE};
  bless $self, $class;

  return $self;
}

sub AUTOLOAD
{
  my $self = shift;
  my $attr = our $AUTOLOAD;
  $attr =~ s/.*:://;
  if ( exists($params{$attr}) )
  {
    $self->{$attr} = shift if @_;
    return $self->{$attr};
  }
  return unless $attr =~ /[^A-Z]/;  # skip DESTROY and all-cap methods
  my $parent = "SUPER::" . $attr;
  $self->$parent(@_);
}

sub doDBSCheck
{
  my ($self, $request) = @_;
  my ($n_files,$n_tested,$n_ok);
  my @nodes = ();

  $self->Logmsg("doDBSCheck: starting") if ( $self->{DEBUG} );
  $self->{bcc}->Checks($request->{TEST}) or
    die "Test $request->{TEST} not known to ",ref($self),"!\n";

  $self->Logmsg("doDBSCheck: Request ",$request->{ID}) if ( $self->{DEBUG} );
  $n_files = $request->{N_FILES};
  my $t = time;

# fork the dbs call and harvest the results
  my $d = dirname($0);
  if ( $d !~ m%^/% ) { $d = cwd() . '/' . $d; }
  my $dbs = $d . '/DBSgetLFNsFromBlock';
  my $r = $self->getDBSFromBlockIDs($request->{BLOCK});
  my $dbsurl = $r->[0] or die "Cannot get DBS url?\n";
  my $blockname = $self->getBlocksFromIDs($request->{BLOCK})->[0];

  open DBS, "$dbs --url $dbsurl --block $blockname |" or do
  {
    $self->Alert("$dbs: $!\n");
    return 0;
  };
  my %dbs;
  while ( <DBS> ) { if ( m%^LFN=(\S+)$% ) { $dbs{$1}++; } }
  close DBS or do
  {
    $self->Alert("$dbs: $!\n");
    return 0;
  };

  eval
  {
    $n_tested = $n_ok = 0;
    $n_files = $request->{N_FILES};
    foreach my $r ( @{$request->{LFNs}} )
    {
      if ( delete $dbs{$r->{LOGICAL_NAME}} ) { $r->{STATUS} = 'OK'; }
      else                                   { $r->{STATUS} = 'Error'; }
      $self->setFileState($request->{ID},$r);
      $n_tested++;
      $n_ok++ if $r->{STATUS} eq 'OK';
    }
    $n_files = $n_tested + scalar keys %dbs;
    $self->setRequestFilecount($request->{ID},$n_tested,$n_ok);
    if ( scalar keys %dbs )
    {
      die "Hmm, how to handle this...? DBS has more than TMDB!\n";
      $self->setRequestState($request,'Suspended');
    }
    if ( $n_files == 0 )
    {
      $self->setRequestState($request,'Indeterminate');
    }
    elsif ( $n_ok == $n_files )
    {
      $self->setRequestState($request,'OK');
    }
    elsif ( $n_tested == $n_files && $n_ok != $n_files )
    {
      $self->setRequestState($request,'Fail');
    }
    else
    {
      print "Hmm, what state should I set here? I have (n_files,n_ok,n_tested) = ($n_files,$n_ok,$n_tested) for request $request->{ID}\n";
    }
    $self->{DBH}->commit();
  };

  do
  {
    chomp ($@);
    $self->Alert ("database error: $@");
    eval { $self->{DBH}->rollback() };
    return 0;
  } if $@;
 
  my $status = ( $n_files == $n_ok ) ? 1 : 0;
  return $status;
}

sub doNSCheck
{
  my ($self, $request) = @_;
  my ($n_files,$n_tested,$n_ok);
  my ($ns,$loader,$cmd,$mapping);
  my @nodes = ();

  $self->Logmsg("doNSCheck: starting") if ( $self->{DEBUG} );

  $self->{bcc}->Checks($request->{TEST}) or
    die "Test $request->{TEST} not known to ",ref($self),"!\n";

  if ( $self->{STORAGEMAP} )
  {
    $mapping = storageRules( $self->{STORAGEMAP}, 'lfn-to-pfn' );
  }
  else
  {
    my $cats;
    my $nodeID = $self->{NODES_ID}{$self->{NODES}[0]};
    $mapping = dbStorageRules( $self->{DBH}, $cats, $nodeID );
  }

  my $tfcprotocol = 'direct';
  if ( $self->{NAMESPACE} )
  {
    $loader = PHEDEX::Core::Loader->new( NAMESPACE => 'PHEDEX::Namespace' );
    $ns = $loader->Load($self->{NAMESPACE})->new( AGENT => $self );
    if ( $request->{TEST} eq 'size' )      { $cmd = 'size'; }
    if ( $request->{TEST} eq 'migration' ) { $cmd = 'is_migrated'; }
    $tfcprotocol = $ns->Protocol();
  }
  else
  {
    $ns = PHEDEX::Namespace->new
		(
			DBH		=> $self->{DBH},
			STORAGEMAP	=> $self->{STORAGEMAP},
			RFIO_USES_RFDIR	=> $self->{RFIO_USES_RFDIR},
			PRELOAD		=> $self->{PRELOAD},
		);
    if ( $request->{TEST} eq 'size' )        { $cmd = 'statsize'; }
    if ( $request->{TEST} eq 'migration' )   { $cmd = 'statmode'; }
    if ( $request->{TEST} eq 'is_migrated' ) { $cmd = 'statmode'; }

    if ( $self->{USE_SRM} eq 'y' or $request->{USE_SRM} eq 'y' )
    {
      $ns->protocol( 'srmv2' );
      $ns->TFCPROTOCOL( 'srmv2' );
    }
    else
    {
      my $technology = $self->{bcc}->Buffers(@{$self->{NODES}});
      $ns->technology( $technology );
    }
  }

  if ( $self->{USE_SRM} eq 'y' or $request->{USE_SRM} eq 'y' )
  { $tfcprotocol = 'srm'; }

  $self->Logmsg("doNSCheck: Request ",$request->{ID}) if ( $self->{DEBUG} );
  $n_files = $request->{N_FILES};
  my $t = time;
  foreach my $r ( @{$request->{LFNs}} )
  {
    no strict 'refs';
    my $pfn;
    my $node = $self->{NODES}[0];
    my $lfn = $r->{LOGICAL_NAME};
    $pfn = &applyStorageRules($mapping,$tfcprotocol,$node,'pre',$lfn,'n');
    if ( $request->{TEST} eq 'size' )
    {
      my $size = $ns->$cmd($pfn);
      if ( defined($size) && $size == $r->{FILESIZE} ) { $r->{STATUS} = 'OK'; }
      else { $r->{STATUS} = 'Error'; }
    }
    elsif ( $request->{TEST} eq 'migration' ||
	    $request->{TEST} eq 'is_migrated' )
    {
      my $mode = $ns->$cmd($pfn);
      if ( defined($mode) && $mode ) { $r->{STATUS} = 'OK'; }
      else { $r->{STATUS} = 'Error'; }
    }
    $r->{TIME_REPORTED} = time();
    last unless --$n_files;
    if ( time - $t > 60 )
    {
      $self->Logmsg("$n_files files remaining") if ( $self->{DEBUG} );
      $t = time;
    }
  }

  eval
  {
    $n_tested = $n_ok = 0;
    $n_files = $request->{N_FILES};
    foreach my $r ( @{$request->{LFNs}} )
    {
      next unless $r->{STATUS};
      $self->setFileState($request->{ID},$r);
      $n_tested++;
      $n_ok++ if $r->{STATUS} eq 'OK';
    }
    $self->setRequestFilecount($request->{ID},$n_tested,$n_ok);
    if ( $n_files == 0 )
    {
      $self->setRequestState($request,'Indeterminate');
    }
    elsif ( $n_ok == $n_files )
    {
      $self->setRequestState($request,'OK');
    }
    elsif ( $n_tested == $n_files && $n_ok != $n_files )
    {
      $self->setRequestState($request,'Fail');
    }
    else
    {
      print "Hmm, what state should I set here? I have (n_files,n_ok,n_tested) = ($n_files,$n_ok,$n_tested) for request $request->{ID}\n";
    }
    $self->{DBH}->commit();
  };

  do
  {
    chomp ($@);
    $self->Alert ("database error: $@");
    eval { $self->{DBH}->rollback() };
    return 0;
  } if $@;
 
  my $status = ( $n_files == $n_ok ) ? 1 : 0;
  return $status;
}

sub _poe_init
{
  my ($self,$kernel) = @_[ OBJECT, KERNEL ];
  $kernel->state('do_tests',$self);
  $kernel->state('get_work',$self);
  $kernel->state('requeue_later',$self);
  $kernel->yield('get_work');
}

sub do_tests
{
  my ($self, $kernel) = @_[ OBJECT, KERNEL ];
  my ($request,$r,$id,$priority);

  ($priority,$id,$request) = $self->{QUEUE}->dequeue_next();
  return unless $request;
# I got a request, so make sure I come back again soon for another one
  $kernel->yield('do_tests');

  $self->{pmon}->State('do_tests','start');
# Sanity checking
  &timeStart($$self{STARTTIME});

  eval {
    $self->connectAgent();
    $self->{bcc}->DBH( $self->{DBH} );

    if ( $request->{TIME_EXPIRE} <= time() )
    {
      $self->setRequestState($request,'Expired');
      $self->Logmsg("do_tests: return after Expiring $request->{ID}");
      return;
    }

    if ( $request->{TEST} eq 'size' ||
         $request->{TEST} eq 'migration' ||
         $request->{TEST} eq 'is_migrated' )
    {
      $self->setRequestState($request,'Active');
      my $result = $self->doNSCheck ($request);
    }
    elsif ( $request->{TEST} eq 'dbs' )
    {
      $self->setRequestState($request,'Active');
      my $result = $self->doDBSCheck ($request);
    }
    else
    {
      $self->setRequestState($request,'Rejected');
      $self->Logmsg("do_tests: return after Rejecting $request->{ID}");
    }
  };
  if ($@) {
    chomp ($@);
    $self->Alert ("Error during test: $@");
#   put everything back the way it was...
    $self->{DBH}->rollback();
#   ...and requeue the request in memory. But, schedule it for later, and lower
#   the priority. That way, if it is a hard error, it should not block things
#   totally, and if it is a soft error, it should go away eventually.
#   (N.B. 'lower' priority means numerically higher!)
    $request->{PRIORITY} = ++$self->{max_priority};
    $kernel->delay_set('requeue_later',60,$request);
  } else {
    $self->{DBH}->commit();
  }

  $self->{pmon}->State('do_tests','stop');
}

sub requeue_later
{
  my ($self, $kernel, $request) = @_[ OBJECT, KERNEL, ARG0 ];
  if ( ++$request->{attempt} > 10 )
  {
    $self->Alert('giving up on request ID=',$request->{ID},', too many hard errors');
    return;
  }

# Before re-queueing, check if any other requests are active. If not, I need
# to kick this into action when I re-queue. Otherwise, it waits for the next
# time get_work finds something to do!
  $self->Logmsg('Requeue request ID=',$request->{ID},' after ',$request->{attempt},' attempts');
  if ( ! $self->{QUEUE}->get_item_count() ) { $kernel->yield('do_tests'); }
  $self->{QUEUE}->enqueue($request->{PRIORITY},$request);
};

# Get a list of pending requests
sub requestQueue
{
  my ($self, $limit, $mfilter, $mfilter_args, $ofilter, $ofilter_args) = @_;
  my (@requests,$sql,%p,$q,$q1,$n,$i);

  $self->Logmsg("requestQueue: starting") if ( $self->{DEBUG} );
  my $now = &mytimeofday();

# Find all the files that we are expected to work on
  $n = 0;

  $sql = qq{
		select b.id, block, n_files, time_expire, priority,
		name test, use_srm
		from t_dvs_block b join t_dvs_test t on b.test = t.id
		join t_status_block_verify v on b.id = v.id
		where ${$mfilter}
		and status in (0,3)
		${$ofilter}
		order by priority asc, time_expire asc
       };
  %p = (  %{$mfilter_args}, %{$ofilter_args} );
  $q = &dbexec($self->{DBH},$sql,%p);

  $sql = qq{ select logical_name, checksum, filesize, vf.fileid,
		nvl(time_reported,0) time_reported, nvl(status,0) status
		from t_dps_file pf join t_dvs_file vf on vf.fileid = pf.id
		left join t_dvs_file_result vfr on vfr.fileid = vf.fileid
		where vf.request = :request
		order by fileid asc, time_reported desc
	   };
  while ( my $h = $q->fetchrow_hashref() )
  {
#   max_priority is guaranteed to be correct at the end of this loop by the
#  'order by priority asc' in the sql. Use it to adjust priority in case of
#   unknown problems
    $self->{max_priority} = $h->{PRIORITY};
    %p = ( ':request' => $h->{ID} );
    $q1 = &dbexec($self->{DBH},$sql,%p);
    my %f;
    while ( my $g = $q1->fetchrow_hashref() )
    {
      $f{$g->{FILEID}} = $g unless exists( $f{$g->{FILEID}} );
    }
    @{$h->{LFNs}} = values %f;
    $n += scalar @{$h->{LFNs}};
    push @requests, $h;
    last if ++$i >= $limit;
  }

  $self->Logmsg("Got ",scalar @requests," requests, for $n files in total") if ( $n );
  return @requests;
}

sub get_work
{
# get work from the database. This function reschedules itself for the future, to fetch
# newer work. If there is unfinished work, this function will call itself again soon,
# and then exit without doing anything. Otherwise, it attempts to get a large chunk of
# work, and re-schedules itself somewhat later.
  my ($self, $kernel) = @_[ OBJECT, KERNEL ];
  my @nodes = ();

  if ( $self->{QUEUE}->get_item_count() )
  {
#   There is work queued, so the agent is 'busy'. Check again soon
    $kernel->delay_set('get_work',10);
    return;
  }
# The agent is idle. Check somewhat less frequently
  $kernel->delay_set('get_work',$self->{WAITTIME});

  $self->{pmon}->State('get_work','start');
  eval
  {
    $self->connectAgent();
    @nodes = $self->expandNodes();
    @nodes or die "No node found? Typo perhaps?\n";
    my ($mfilter, %mfilter_args) =    $self->myNodeFilter ("b.node");
    my ($ofilter, %ofilter_args) = $self->otherNodeFilter ("b.node");

#   Get a list of requests to process
    foreach my $request ($self->requestQueue($self->{QUEUE_LENGTH},
					\$mfilter, \%mfilter_args,
					\$ofilter, \%ofilter_args))
    {
      $self->{QUEUE}->enqueue($request->{PRIORITY},$request);
      $self->setRequestState($request,'Queued');
    }
    $self->{DBH}->commit();
  };
  do {
     chomp ($@);
     $self->Alert ("database error: $@");
     $self->{DBH}->rollback();
  } if $@;

# If we found new tests to perform, but there were none already in the queue, kick off
# the do_tests loop
  if ( $self->{QUEUE}->get_item_count() ) { $kernel->yield('do_tests'); }
  else
  {
    # Disconnect from the database
    $self->disconnectAgent();
  }
  $self->{pmon}->State('get_work','stop');

  return;
}

sub setFileState
{
# Change the state of a file-test in the database
  my ($self, $request, $result) = @_;
  my ($sql,%p,$q);
  return unless defined $result;

  $sql = qq{
	insert into t_dvs_file_result fr 
	(id,request,fileid,time_reported,status)
	values
	(seq_dvs_file_result.nextval,:request,:fileid,:time,
	 (select id from t_dvs_status where name like :status_name )
	)
       };
  %p = ( ':fileid'      => $result->{FILEID},
  	 ':request'     => $request,
         ':status_name' => $result->{STATUS},
         ':time'        => $result->{TIME_REPORTED},
       );
  $q = &dbexec($self->{DBH},$sql,%p);
}

sub setRequestFilecount
{
  my ($self,$id,$n_tested,$n_ok) = @_;
  my ($sql,%p,$q);

  $sql = qq{ update t_status_block_verify set n_tested = :n_tested,
		n_ok = :n_ok where id = :id };
  %p = ( ':n_tested' => $n_tested,
	 ':n_ok'     => $n_ok,
	 ':id'       => $id
       );
  $q = &dbexec($self->{DBH},$sql,%p);
}

sub setRequestState
{
# Change the state of a request in the database
  my ($self, $request, $state) = @_;
  my ($sql,%p,$q);
  my (@nodes);
  return unless defined $request->{ID};

  $self->Logmsg("Request=$request->{ID}, state=$state");

  $sql = qq{
	update t_status_block_verify sbv 
	set time_reported = :time,
	status = 
	 (select id from t_dvs_status where name like :state )
	where id = :id
       };
  %p = ( ':id'    => $request->{ID},
         ':state' => $state,
         ':time'  => time()
       );
  while ( 1 )
  {
    eval { $q = &dbexec($self->{DBH},$sql,%p); };
    last unless $@;
    die $@ if ( $@ !~ m%ORA-25408% );
    sleep 63; # wait a bit and retry...
  }
}

sub isInvalid
{
  my $self = shift;
  my $errors = $self->SUPER::isInvalid
		(
		  REQUIRED => [ qw / NODES DBCONFIG / ],
		);
  return $errors;
}

1;
