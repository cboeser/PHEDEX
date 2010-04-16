----------------------------------------------------------------------
-- Create sequences

create sequence seq_dps_dbs;
create sequence seq_dps_dataset;
create sequence seq_dps_block;

----------------------------------------------------------------------
-- Create tables

create table t_dps_dbs
  (id			integer		not null,
   name			varchar (1000)	not null,
   dls			varchar (1000)	not null,
   time_create		float		not null,
   --
   constraint pk_dps_dbs
     primary key (id),
   --
   constraint uq_dps_dbs_name
     unique (name));


create table t_dps_dataset
  (id			integer		not null,
   dbs			integer		not null,
   name			varchar (1000)	not null,
   is_open		char (1)	not null,
   is_transient		char (1)	not null,
   time_create		float		not null,
   time_update		float,
   --
   constraint pk_dps_dataset
     primary key (id),
   --
   constraint uq_dps_dataset_key
     unique (dbs, name),
   --
   constraint fk_dps_dataset_dbs
     foreign key (dbs) references t_dps_dbs (id),
   --
   constraint ck_dps_dataset_open
     check (is_open in ('y', 'n')),
   --
   constraint ck_dps_dataset_transient
     check (is_transient in ('y', 'n')));


create table t_dps_block
  (id			integer		not null,
   dataset		integer		not null,
   name			varchar (1000)	not null,
   files		integer		not null,
   bytes		integer		not null,
   is_open		char (1)	not null,
   time_create		float		not null,
   time_update		float,
   --
   constraint pk_dps_block
     primary key (id),
   --
   constraint uq_dps_block_name
     unique (dataset, name),
   --
   constraint fk_dps_block_dataset
     foreign key (dataset) references t_dps_dataset (id),
   --
   constraint ck_dps_block_open
     check (is_open in ('y', 'n')),
   --
   constraint ck_dps_block_files
     check (files >= 0),
   --
   constraint ck_dps_block_bytes
     check (bytes >= 0));

create global temporary table t_tmp_br_active
  (block      		integer		not null
) on commit delete rows;

create global temporary table t_tmp_br_src
  (block      		integer		not null,
   node			integer		not null,
   files		integer		not null,
   bytes		integer		not null,
   time_update		integer		not null
) on commit delete rows;

create global temporary table t_tmp_br_dest
  (block      		integer		not null,
   node			integer		not null,
   files		integer		not null,
   bytes		integer		not null,
   time_update		integer		not null
) on commit delete rows;

create global temporary table t_tmp_br_node
  (block      		integer		not null,
   node			integer		not null,
   files		integer		not null,
   bytes		integer		not null,
   time_update		integer		not null
) on commit delete rows;

create global temporary table t_tmp_br_xfer
  (block      		integer		not null,
   node			integer		not null,
   files		integer		not null,
   bytes		integer		not null,
   time_update		integer		not null
) on commit delete rows;

create global temporary table t_tmp_br_flag
  (block      		integer		not null,
   node			integer		not null,
   is_custodial		char(1)		not null,
   user_group		integer		,
   time_update		integer		not null
) on commit delete rows;

create table t_dps_block_replica
  (block		integer		not null,
   node			integer		not null,
   is_active		char (1)	not null,
   src_files		integer		not null,
   src_bytes		integer		not null,
   dest_files		integer		not null,
   dest_bytes		integer		not null,
   node_files		integer		not null,
   node_bytes		integer		not null,
   xfer_files		integer		not null,
   xfer_bytes		integer		not null,
   is_custodial		char (1)	not null, -- applies to dest_files, node_files
   user_group		integer			, -- applies to dest_files, node_files
   time_create		float		not null,
   time_update		float		not null,
   --
   constraint pk_dps_block_replica
     primary key (block, node),
   --
   constraint fk_dps_block_replica_block
     foreign key (block) references t_dps_block (id)
     on delete cascade,
   --
   constraint fk_dps_block_replica_node
     foreign key (node) references t_adm_node (id)
     on delete cascade,
   --
   constraint ck_dps_block_replica_cust
     check (is_custodial in ('y', 'n')),
   --
   constraint fk_dps_block_replica_group
     foreign key (user_group) references t_adm_group (id)
     on delete set null,
   --
   constraint ck_dps_block_replica_active
     check (is_active in ('y', 'n')));


/* t_dps_block_dest.state states:
     0: Assigned but not yet active (= waiting for router to activate
        into t_xfer_request).
     1: Active (= routed has activated into t_xfer_request).
     2: Subscription suspended by user.
     3: Block completed and not to be considered further, but the
        entire subscription not yet completed and marked done.
     4: Suspended by the FileRouter due to bad behavior
*/
create table t_dps_block_dest
  (block		integer		not null,
   dataset		integer		not null,
   destination		integer		not null,
   priority		integer		not null,
   is_custodial		char (1)	not null,
   state		integer		not null,
   time_subscription	float		not null,
   time_create		float		not null,
   time_active		float,
   time_complete	float,
   time_suspend_until	float,
   --
   constraint pk_dps_block_dest
     primary key (block, destination),
   --
   constraint fk_dps_block_dest_dataset
     foreign key (dataset) references t_dps_dataset (id)
     on delete cascade,
   --
   constraint fk_dps_block_dest_block
     foreign key (block) references t_dps_block (id)
     on delete cascade,
   --
   constraint fk_dps_block_dest_node
     foreign key (destination) references t_adm_node (id)
     on delete cascade,
   --
   constraint ck_dps_block_dest_custodial
     check (is_custodial in ('y', 'n')));


create table t_dps_block_activate
  (block		integer		not null,
   time_request		float		not null,
   time_until		float,
   --
   constraint fk_dps_block_activate_block
     foreign key (block) references t_dps_block (id)
     on delete cascade);


----------------------------------------------------------------------
-- Create indices

-- t_dps_block_dataset
create index ix_dps_block_dataset
  on t_dps_block (dataset);

create index ix_dps_block_name
  on t_dps_block (name);
-- t_dps_block_replica
create index ix_dps_block_replica_node
  on t_dps_block_replica (node);

create index ix_dps_block_replica_group
  on t_dps_block_replica (user_group);
-- t_dps_block_dest
create index ix_dps_block_dest_dataset
  on t_dps_block_dest (dataset);

create index ix_dps_block_dest_dest
  on t_dps_block_dest (destination);
-- t_dps_block_activate
create index ix_dps_block_activate_b
  on t_dps_block_activate (block);
