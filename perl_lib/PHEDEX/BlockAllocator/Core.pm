package PHEDEX::BlockAllocator::Core;

=head1 NAME

PHEDEX::BlockAllocator::Core - the Block Allocator core.

=head1 SYNOPSIS

pending...

=head1 DESCRIPTION

pending...

=head1 SEE ALSO...

L<PHEDEX::Core::Agent|PHEDEX::Core::Agent>

=cut

use strict;
use warnings;
use base 'PHEDEX::BlockAllocator::SQL', 'PHEDEX::BlockLatency::SQL';
use PHEDEX::Core::Logging;

our %params = (
	      );

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

# Phase I:  Subscription-level state changes
#   1.  Remove block subscriptions where there is a dataset subscription
#   2.  Mark fully transferred subscriptions as complete/done
#     2a.  Mark move subscriptions done when all the deletes are finished
#     2b.  Change finished move subscriptions into a replica subscription
#   3.  Mark complete/done subscriptions as incomplete if they are not complete anymore
sub subscriptions
{
    no warnings qw(uninitialized);  # lots of undef variables expected here from empty timestamps

    my ($self, $now) = @_;

    my %stats;
    my @stats_order = ('subs completed', 'move subs done', 'copy subs done',
		       'move subs aborted', 'move request aborted',
		       'subs marked incomplete', 'subs removed',
		       'moves pending deletion', 'moves pending confirmation',
		       'subs updated');
    $stats{$_} = 0 foreach @stats_order;

    my $q_subs = $self->execute_sql( qq{
	    select NVL2(s.block, 'BLOCK', 'DATASET') subs_item_level,
	      NVL2(s.block, s.block, s.dataset) subs_item_id,
	      NVL2(s.block, b.name, ds.name) subs_item_name,
	      NVL2(s.block, b.is_open, ds.is_open) subs_item_open,
	      ds.id dataset_id, ds.name dataset_name,
	      n.id destination_id, n.name destination_name,
	      s.destination subs_destination, s.dataset subs_dataset, s.block subs_block,
	      s.priority, s.is_move, s.is_transient,
	      s.time_suspend_until, s.time_create,
	      s.time_clear, s.time_complete, s.time_done,
	      reps.exist_files, reps.node_files, reps.dest_files,
	      reps.exist_bytes, reps.node_bytes, reps.dest_bytes
	    from t_dps_subscription s
	    join t_adm_node n on n.id = s.destination
	    left join t_dps_block b on b.id = s.block
	    left join t_dps_dataset ds on ds.id = s.dataset or ds.id = b.dataset
	    join
	    (select s2.destination, s2.dataset, s2.block,
		    sum(b2.files) exist_files, sum(b2.bytes) exist_bytes,
		    sum(br.node_files) node_files, sum(br.dest_files) dest_files,
		    sum(br.node_bytes) node_bytes, sum(br.dest_bytes) dest_bytes
	       from t_dps_subscription s2
	       left join t_dps_block b2 on b2.dataset = s2.dataset or b2.id = s2.block
	       left join t_dps_block_replica br on br.node = s2.destination and br.block = b2.id
	       group by s2.destination, s2.dataset, s2.block
	    ) reps
	    on reps.destination = s.destination
	   and (reps.dataset = s.dataset or reps.block = s.block)
       }, () );

    # Fetch all subscription data
    my @all_subscriptions;
    while (my $subscription = $q_subs->fetchrow_hashref()) {
	push @all_subscriptions, $subscription;
    }

    my %uargs;

  SUBSCRIPTION: foreach my $subs (@all_subscriptions) {
      my $subs_identifier = "$subs->{SUBS_ITEM_NAME} to $subs->{DESTINATION_NAME}";

      # Remove all block subscriptions for a site for which we have
      # dataset subscriptions containing those blocks already.
      if ($subs->{SUBS_ITEM_LEVEL} eq 'BLOCK' && 
	  grep ($_->{SUBS_ITEM_LEVEL} eq 'DATASET' &&
		$_->{DESTINATION_ID} == $subs->{DESTINATION_ID} &&
		$_->{DATASET_ID} == $subs->{DATASET_ID}, @all_subscriptions)) {
	  $self->delete_subscription($subs);
	  &logmsg("removing subscription for $subs_identifier:  ",
		  "superceded by dataset subscription");
	  $stats{'subs removed'}++;
	  next SUBSCRIPTION;
      }

      my $subs_update = { 
	  IS_MOVE => $subs->{IS_MOVE},
	  TIME_CLEAR => $subs->{TIME_CLEAR},
	  TIME_COMPLETE => $subs->{TIME_COMPLETE},
	  TIME_DONE => $subs->{TIME_DONE}
      };

      # Remove all subscriptions which have passed the time_clear
      # Change moves to replications which have passed the time_clear
      # Unset time_clear if there is no longer a move subscription
      if ($subs->{TIME_CLEAR} && $subs->{TIME_CLEAR} <= $now) {
	  if ($subs->{IS_MOVE} eq 'n') {
	      $self->delete_subscription($subs);
	      &logmsg("removing subscription for $subs_identifier:  ",
		      "marked for clearing");
	      $stats{'subs removed'}++;
	      next SUBSCRIPTION;
	  } else {
	      $subs_update->{IS_MOVE} = 'n';
	      $subs_update->{TIME_CLEAR} = undef;
	      &logmsg("move subscription for $subs_identifier aborted");
	      $stats{'move subs aborted'}++;
	  }
      } elsif ($subs->{TIME_CLEAR} && $subs->{TIME_CLEAR} > $now &&
	       ! grep($_->{IS_MOVE} eq 'y' && 
		      $_->{DESTINATION_ID} != $subs->{DESTINATION_ID} &&
		      $_->{DATASET_ID} == $subs->{DATASET_ID}, @all_subscriptions)) {
	  $subs_update->{TIME_CLEAR} = undef;
	  &logmsg("move request flag removed for $subs_identifier");
	  $stats{'move request aborted'}++;
      }

      # Update newly complete subscriptions
      if (!$subs->{TIME_COMPLETE} &&
	  $subs->{NODE_FILES} >= $subs->{EXIST_FILES} &&
	  $subs->{NODE_BYTES} >= $subs->{EXIST_BYTES}) {
	  $subs_update->{TIME_COMPLETE} = $now;
	  &logmsg("subscription complete for $subs_identifier");
	  $stats{'subs completed'}++;
      }

      # Update newly done moves - moves can only be "done" on closed items
      if ( !$subs->{TIME_DONE} && $subs->{IS_MOVE} eq 'y' && $subs->{SUBS_ITEM_OPEN} eq 'n' 
	   && ($subs_update->{TIME_COMPLETE} || $subs->{TIME_COMPLETE}) ) {

	  # Query the deletions we are waiting for
	  # Note:  We do not wait for T1 deletions, moves from T1s are not a use case (yet)
	  my $q_del = $self->execute_sql( qq{
	    select n.name node, nvl2(s2.destination, 1, 0) subs_exists, s2.time_clear subs_clear,
	           sum(br.node_files) n_files
              from t_dps_subscription s
              join t_dps_block sb on sb.dataset = s.dataset or sb.id = s.block
              join t_dps_block_replica br on br.node != s.destination
	                                 and br.block = sb.id
              join t_adm_node n on n.id = br.node
         left join t_dps_subscription s2 on s2.destination = br.node
                                        and (s2.dataset = sb.dataset or s2.block = sb.id)
	     where n.name not like 'T1_%' 
               and nvl(s.dataset, -1) = nvl(:dataset, -1)
               and nvl(s.block, -1) = nvl(:block, -1)
               and s.destination = :destination
               and br.node_files != 0
	     group by n.name, s2.destination, s2.time_clear
	   },
		(
		  ':dataset'	 => $subs->{SUBS_DATASET},
		  ':block'	 => $subs->{SUBS_BLOCK},
		  ':destination' => $subs->{SUBS_DESTINATION}
		)
	);
	  
	  my $n_to_delete = 0;
	  while (my ($node, $subs_exists, $subs_clear, $n_files) = $q_del->fetchrow()) {
	      my ($wait_delete, $wait_confirm) = (0, 0);
	      if (!$subs_exists || ($subs_exists && $subs_clear && $subs_clear <= $now)) {
		  $n_to_delete += $n_files;
		  &logmsg("waiting for $n_files files at $node ",
			  "to be deleted before marking move of $subs->{SUBS_ITEM_NAME} done");
		  $wait_delete++;
	      } elsif ($subs_exists && $subs_clear && $subs_clear > $now) {
		  $n_to_delete += $n_files;
		  &logmsg("waiting for $node to confirm move of $n_files files at $subs->{SUBS_ITEM_NAME} ",
			  "before marking done");
		  $wait_confirm++;
		  if (!$subs->{TIME_CLEAR}) {
		      $subs_update->{TIME_CLEAR} = $now + 7*24*3600; # give up waiting in one week
		      &logmsg("waiting 1 week for move confirmations of $subs_identifier");
		  }
	      }
	      $stats{'moves pending deletion'} += $wait_delete ? 1 : 0;
	      $stats{'moves pending confirmation'} += $wait_confirm ? 1 : 0;
	  }
	  
	  if ($n_to_delete == 0) {
	      $subs_update->{TIME_DONE} = $now;
	      $subs_update->{IS_MOVE} = 'n';
	      $subs_update->{TIME_CLEAR} = undef;
	      &logmsg("move subscription is done for $subs_identifier, changed to replica subscription");
	      $stats{'move subs done'}++;
	  }
      }

      # Update newly done replications - replications are only "done" on closed items
      if ( !$subs->{TIME_DONE} && $subs->{IS_MOVE} eq 'n' && $subs->{SUBS_ITEM_OPEN} eq 'n' &&
	   $subs->{NODE_FILES} >= $subs->{EXIST_FILES} &&
           $subs->{NODE_BYTES} >= $subs->{EXIST_BYTES}) {
	  $subs_update->{TIME_DONE} = $now;
	  &logmsg("replication subscription is done for $subs_identifier");
	  $stats{'copy subs done'}++;
      }
      
      # Update newly uncomplete/undone replications
      if ( ($subs->{TIME_DONE} || $subs->{TIME_COMPLETE}) &&
	   $subs->{NODE_FILES} < $subs->{EXIST_FILES} &&
	   $subs->{NODE_BYTES} < $subs->{EXIST_BYTES} ) {
	  $subs_update->{TIME_COMPLETE} = undef;
	  $subs_update->{TIME_DONE} = undef;
	  &logmsg("subscription is no longer done, updating for $subs_identifier");
	  $stats{'subs marked incomplete'}++;
      }

      # Add to bulk update arrays if there are changes
      if (&hash_ne($subs_update, $subs)) {
	  my $n = 1;
	  push(@{$uargs{$n++}}, $subs_update->{TIME_COMPLETE});
	  push(@{$uargs{$n++}}, $subs_update->{TIME_DONE});
	  push(@{$uargs{$n++}}, $subs_update->{TIME_CLEAR});
	  push(@{$uargs{$n++}}, $subs_update->{IS_MOVE});
	  push(@{$uargs{$n++}}, $subs->{SUBS_DESTINATION});
	  push(@{$uargs{$n++}}, $subs->{SUBS_DATASET});
	  push(@{$uargs{$n++}}, $subs->{SUBS_BLOCK});
      }
  }

    # Bulk update
    my @rv = $self->execute_sql( qq{
	update t_dps_subscription
	   set time_complete = ?,
	       time_done = ?,
	       time_clear = ?,
               is_move = ?
         where destination = ?
	   and nvl(dataset, -1) = nvl(?, -1)
           and nvl(block, -1) = nvl(?, -1)
       }, %uargs) if %uargs;

    $stats{'subs updated'} = $rv[1] || 0;
    
    # Return statistics
    return map { [$_, $stats{$_}] } @stats_order;
}

# Deletes one subscription
sub delete_subscription
{
    my ($self, $subs) = @_;
    $self->execute_sql( qq{
	delete from t_dps_subscription
         where destination = :destination
           and nvl(dataset, -1) = nvl(:dataset, -1)
           and nvl(block, -1) = nvl(:block, -1) },
	    ':destination' => $subs->{SUBS_DESTINATION},
	    ':dataset' => $subs->{SUBS_DATASET},
	    ':block' => $subs->{SUBS_BLOCK});
}


# Phase II:  Block Destination creation/deletion
#   1.  Create block destinations that are subscribed
#   2.  Remove block destinations that are:
#         a.  not subscribed
#         b.  going to be cleared because of a move
#         c.  queued for deletion
sub allocate
{
    my ($self, $now) = @_;

    my %stats;
    my @stats_order = ('blocks allocated', 'blocks deallocated');
    $stats{$_} = 0 foreach @stats_order;

    my @add;
    my @rem;

    my $q_subsNoBlock = $self->execute_sql( qq{
	    select s.destination destination, n.name destination_name,
                   sb.id block, sb.name block_name,
	           sb.dataset, s.priority, 0 state, s.time_create time_subscription
              from t_dps_subscription s
	      join t_dps_block sb on sb.id = s.block or sb.dataset = s.dataset
	      join t_adm_node n on n.id = s.destination
	      where not exists (select 1 from t_dps_block_delete bdel
                                 where bdel.node = s.destination
                                   and bdel.block = sb.id
                                   and bdel.time_complete is null)
	        and not exists (select 1 from t_dps_block_dest bd
				 where bd.destination = s.destination
				   and bd.block = sb.id)
	  });
    while (my $block = $q_subsNoBlock->fetchrow_hashref()) {
	&logmsg("adding block destination for $block->{BLOCK_NAME} to $block->{DESTINATION_NAME}");
	$block->{TIME_CREATE} = $now;
	push @add, $block;
    }

    my $n_alloc = $self->allocateBlockDestinations(\@add);
    $stats{'blocks allocated'} = $n_alloc;

    my $q_blockNoSubs = $self->execute_sql( qq{
	    select bd.destination destination, n.name destination_name,
                   b.id block, b.name block_name,
		   case when subs.destination is null then 'no subscription'
			when bdel.time_complete is null then 'queued for deletion'
			else 'no reason!'
                    end reason
	      from t_dps_block_dest bd
              join t_dps_block b on b.id = bd.block
	      join t_adm_node n on n.id = bd.destination
	      left join (select s.destination, sb.id block, s.time_clear from t_dps_subscription s
			   join t_dps_block sb on sb.id = s.block or sb.dataset = s.dataset) subs
	        on subs.destination = bd.destination and subs.block = bd.block
              left join t_dps_block_delete bdel 
	        on bdel.node = bd.destination and bdel.block = bd.block
             where subs.destination is null
	        or (bdel.block is not null and bdel.time_complete is null)
	    });

    while (my $block = $q_blockNoSubs->fetchrow_hashref()) {
	&logmsg("removing block destination for $block->{BLOCK_NAME} to $block->{DESTINATION_NAME}: ",
		"$block->{REASON}");
	push @rem, $block;
    }

    my $n_dealloc = $self->deallocateBlockDestinations(\@rem);
    $stats{'blocks deallocated'} = $n_dealloc;

    # Return statistics
    return map { [$_, $stats{$_}] } @stats_order;
}

# Bulk insert of new block destinations
sub allocateBlockDestinations
{
    my ($self, $blocks) = @_;
    my $i = &dbprep($self->{DBH}, qq{
	insert into t_dps_block_dest
	(block, dataset, destination, priority, state, time_subscription, time_create)
        values (?, ?, ?, ?, ?, ?, ?) });

    my %iargs;
    foreach my $b (@$blocks) {
	my $n = 1;
	foreach my $key (qw(BLOCK DATASET DESTINATION PRIORITY STATE TIME_SUBSCRIPTION TIME_CREATE)) {
	    push(@{$iargs{$n++}}, $b->{$key});
	}	
    }

    my $rv = &dbbindexec($i, %iargs) if %iargs;
    return $rv || 0;
}

# Bulk delete of block destinations
sub deallocateBlockDestinations
{
    my ($self, $blocks) = @_;
    my $d = &dbprep($self->{DBH}, qq{
	delete from t_dps_block_dest
         where block = ?
	 and destination = ? });

    my %dargs;
    foreach my $b (@$blocks) {
	my $n = 1;
	foreach my $key (qw(BLOCK DESTINATION)) {
	    push(@{$dargs{$n++}}, $b->{$key});
	}	
    }

    my $rv = &dbbindexec($d, %dargs) if %dargs;
    return $rv || 0;
}


# Phase III:  Block destination state changes
#   1.  Propogate subscription state to block destinations
#   2.  Mark completed block destinations done
#   3.  Mark undone block destinations if incomplete
sub blockDestinations
{
    my ($self, $now) = @_;
    my %stats;
    my @stats_order = ('blockdest done', 'blockdest reactivated', 'blockdest priority changed',
		       'blockdest suspended', 'blockdest unsuspended', 'blockdest updated');
    $stats{$_} = 0 foreach @stats_order;


    # Query all subscriptions and block destinations, along with
    # replica and block delete information.  Aquire lock on block
    # destinations to ensure transactional consistency for the
    # updates to come.
    my $q_blockdest = &dbexec($self->{DBH}, qq{
	    select
              bd.destination, n.name destination_name,
              b.dataset dataset, b.id block, b.name block_name,
	      b.is_open,
	      s.priority subs_priority, s.is_move subs_move, s.is_transient subs_transient,
	      s.time_create subs_create, s.time_complete subs_complete,
	      s.time_clear subs_clear, s.time_done subs_done, s.time_suspend_until subs_suspend,
	      bd.priority bd_priority, bd.state bd_state,
              bd.time_subscription bd_subscrption, bd.time_create bd_create, bd.time_active bd_active,
	      bd.time_complete bd_complete, bd.time_suspend_until bd_suspend,
              nvl(br.node_files,0) node_files, nvl(br.src_files,0) src_files, b.files exist_files
	      from t_dps_block_dest bd
	      join t_adm_node n on n.id = bd.destination
	      join t_dps_block b on b.id = bd.block
	      join t_dps_subscription s on s.destination = bd.destination
	                               and (s.dataset = bd.dataset or s.block = bd.block)
	      left join t_dps_block_replica br on br.node = bd.destination and br.block = bd.block
	  });

    # Cache all data
    my @all_blocks;
    while (my $block = $q_blockdest->fetchrow_hashref()) {
	push @all_blocks, $block;
    }

    my %uargs;

  BLOCK: foreach my $block (@all_blocks) {
      my $bd_identifier = "$block->{BLOCK_NAME} at $block->{DESTINATION_NAME}";
      
      # Update parameters for block destination
      my $bd_update = { 
	  BD_STATE => $block->{BD_STATE},
	  BD_PRIORITY => $block->{BD_PRIORITY},
	  BD_SUSPEND => $block->{BD_SUSPEND},
	  BD_COMPLETE => $block->{BD_COMPLETE}
      };

      # Mark done the block destinations which are of closed blocks and have all files fully replicated.
      if ($block->{IS_OPEN} eq 'n' &&
	  $block->{NODE_FILES} >= $block->{EXIST_FILES} &&
	  $block->{BD_STATE} != 3) {
	  &logmsg("block destination done for $bd_identifier");
	  $bd_update->{BD_STATE} = 3;
	  $bd_update->{BD_COMPLETE} = $now;
	  $stats{'blockdest done'}++;
      }

      # Reactivate block destinations which do not have all files replicated (deleted data)
      if ($block->{NODE_FILES} < $block->{EXIST_FILES} &&
	  $block->{BD_STATE} == 3) {
	  &logmsg("reactivating incomplete block destination $bd_identifier");
	  $bd_update->{BD_STATE} = 0;
	  $bd_update->{BD_COMPLETE} = undef;
	  $stats{'blockdest reactivated'}++;
      }

      { no warnings qw(uninitialized);  # lots of undef variables expected here
	# Update priority and suspended status on existing requests
	if ($block->{BD_PRIORITY} != $block->{SUBS_PRIORITY}) {
	    &logmsg("updating priority of $bd_identifier");
	    $bd_update->{BD_PRIORITY} = $block->{SUBS_PRIORITY};
	    $stats{'blockdest priority changed'}++;
	}

	if ((POSIX::floor($block->{BD_SUSPEND}) || 0) != (POSIX::floor($block->{SUBS_SUSPEND}) || 0)) {
	    &logmsg("updating suspension status of $bd_identifier");
	    $bd_update->{BD_SUSPEND} = $block->{SUBS_SUSPEND};
	}
	      
	# Manage routing state changes for suspended blocks
	if ($bd_update->{BD_STATE} < 2 &&
	    defined $bd_update->{BD_SUSPEND} && 
	    $bd_update->{BD_SUSPEND} > $now) {
	    &logmsg("suspending block destination $bd_identifier");
	    $bd_update->{BD_STATE} = 2;
	    $stats{'blockdest suspended'}++;
	}

	if ($bd_update->{BD_STATE} == 2 &&
	    (!defined $bd_update->{BD_SUSPEND} || $bd_update->{BD_SUSPEND} <= $now)) {
	    &logmsg("unsuspending block destination $bd_identifier");
	    $bd_update->{BD_STATE} = 0;
	    $bd_update->{BD_SUSPEND} = undef;
	    $stats{'blockdest unsuspended'}++;
	}
    }

      if (&hash_ne($bd_update, $block)) {
	  my $n = 1;
	  push(@{$uargs{$n++}}, $bd_update->{BD_STATE});
	  push(@{$uargs{$n++}}, $bd_update->{BD_PRIORITY});
	  push(@{$uargs{$n++}}, $bd_update->{BD_SUSPEND});
	  push(@{$uargs{$n++}}, $bd_update->{BD_COMPLETE});
	  push(@{$uargs{$n++}}, $block->{BLOCK});
	  push(@{$uargs{$n++}}, $block->{DESTINATION});
      }
  }

    # Bulk update
    my @rv = &dbexec($self->{DBH}, qq{
	update t_dps_block_dest
	   set state = ?,
	       priority = ?,
	       time_suspend_until = ?,
               time_complete = ?
	 where block = ? and destination = ?
     }, %uargs) if %uargs;
    
    $stats{'blockdest updated'} = $rv[1] || 0;

    # Return statistics
    return map { [$_, $stats{$_}] } @stats_order;
}

# returns 1 if the contents of the second hash do not match the
# contents of the first
# TODO:  put in some general library?
sub hash_ne
{
    no warnings;
    my ($h1, $h2) = @_;
    foreach (keys %$h1) {
	return 1 if exists $h1->{$_} != exists $h2->{$_};
	return 1 if defined $h1->{$_} != defined $h2->{$_};
	return 1 if $h1->{$_} ne $h2->{$_};
    }
    return 0;
}

sub printStats
{
    my ($self, $title, @stats) = @_;
    &logmsg("$title:  ".join(', ', map { $_->[1] + 0 .' '.$_->[0] } @stats));
}


1;
