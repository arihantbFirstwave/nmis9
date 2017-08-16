#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System (“NMIS”).
#
#  NMIS is free software: you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  NMIS is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
#  You should have received a copy of the GNU General Public License
#  along with NMIS (most likely in a file named LICENSE).
#  If not, see <http://www.gnu.org/licenses/>
#
#  For further information on NMIS or for a license other than GPL please see
#  www.opmantek.com or email contact@opmantek.com
#
#  User group details:
#  http://support.opmantek.com/users/
#
# *****************************************************************************

# Inventory Class
# Base class which specific Inventory implementions should inherit from
# Provides basic structure and saving

package NMISNG::Inventory;
use strict;

our $VERSION = "1.0.0";

use Clone;              # for copying data and other r/o sections
use Module::Load;       # for getting subclasses in instantiate
use Scalar::Util;       # for weaken
use Data::Dumper;
use Time::HiRes;
use Time::Moment;								# for ttl indices
use DateTime;										# ditto
use List::MoreUtils;    # for uniq
use Carp;

use NMISNG::DB;

###########
# Class/Package methods:
###########

# based on the concept, decide which class to create - or return the fallback/default class
# args: concept
# returns: class name
sub get_inventory_class
{
	my ($concept) = @_;
	my %knownclasses = (
		'default'   => 'DefaultInventory',     # the fallback, must be present
		'service'   => "ServiceInventory",
		'interface' => 'InterfaceInventory',
			# ...
	);

	my $class = "NMISNG::Inventory::" . ( $knownclasses{$concept} // $knownclasses{default} );
	return $class;
}

# small helper that massages a modeldata object's members into instantiated inventory objects
# note: this is a generic class function, not object method!
# args: nmisng, modeldata (must be modeldata object and members will be modified!), both required
# returns: error message or undef
#
# please note that this requires the modeldata members to be fully populated,
# i.e. they must not be filtered with fields_hash or the object instantiation will make a mess or fail.
sub instantiate
{
	my (%args) = @_;
	my ( $nmisng, $modeldata ) = @args{"nmisng", "modeldata"};
	return "invalid input, nmnisng  argument missing!" if ( ref($nmisng) ne "NMISNG" );
	return "invalid input, not modeldata object!"      if ( ref($modeldata) ne "NMISNG::ModelData" );

	my @objects;
	for my $entry ( @{$modeldata->data} )
	{
		# what kind of object is that supposed to be?
		my $class = get_inventory_class( $entry->{concept} );
		Module::Load::load($class);

		# and now instantiate the object from whatever we were given
		my $object = $class->new( nmisng => $nmisng, %{$entry} );
		return "failed to instantiate object!" if ( !$object );
		push @objects, $object;
	}
	$modeldata->data( \@objects );
	return undef;
}

# compute path from data and selection args.
# note: this is a generic class function, not object method!
#
# take data and a set of keys (path_keys, which index the provided data) and create
# a path out of them. This is a generic function that can work with any class;
# you just need to provide the params, this is why it exists here.
#
# DefaultInventory relies on this implementation to work, if your subclass does not need to do anything
# fancy (like morph/tranlate data in keys) then it should probably use this implementation
# args: cluster_id, node_uuid, concept, data, path_keys (all required), partial (optional, default: 0)
# returns error message or path arrayref if ok
sub make_path_from_keys
{
	my (%args) = @_;

	my $keys = $args{"path_keys"};
	return "make_path_from_keys cannot work without path_keys!"
		if ( ref($keys) ne "ARRAY" );
	return "make_path_from_keys has invalid data argument: " . ref( $args{data} )
		if ( exists( $args{data} ) && ref( $args{data} ) ne "HASH" );

	my @path;

	# to make the path globally unique
	for my $prefixelem ( "cluster_id", "node_uuid", "concept" )
	{
		if ( !$args{partial} && !defined( $args{$prefixelem} ) )
		{
			return "make_path_from_keys is missing $prefixelem argument!";
		}
		push @path, $args{$prefixelem};
	}

	# now go through the given path_keys
	foreach my $pathelem (@$keys)
	{
		if ( !$args{partial} && !defined( $args{data}->{$pathelem} ) )
		{
			return ("make_path_from_keys is missing $pathelem data!");
		}
		push @path, $args{data}->{$pathelem};
	}
	return \@path;
}

# (re)compute path from instance data - BUT also create path WITHOUT instance!
# note: MUST NOT be instance method, but a class function, ie. NO SELF!
# this is so that paths can be calculated without a whole object being created (which is handy for searching,
# used from Node.pm)
#
# subclasses MUST implement this.
#
# args: cluster_id, node_uuid, concept, data, (all required),
# path_keys (required for a simple class using make_path_from_keys); partial (optional)
#
# it should fill out the path value (arrayref),
# it MUST construct the path with cluster_id, node_uuid and concept as the first three elements,
# it should return an error message if it does not have enough data to create the path
# if partial is 1 then part of a path will be returned, which could be handy for searching (maybe?)
#
# returns error message or path array ref
sub make_path
{
	# make up for object deref invocation being passed in as first argument
	# expecting a hash which has even # of inputs
	shift if ( !( $#_ % 2 ) );

	die( __PACKAGE__ . "::make_path must be implemented by subclass!" );
}

# take data structure that create_update_rrd and convert it into
# values that time_data can use.
# args:
#  rrd_data - data sent to create_update_rrd, hashref, each entry holding a hash keys @{value,option}
#  target - where to put the parsed data
#  previous_pit - previous entry for this thing, note: could be looked up if we want, not done right now
#   expects the full pit, with data in subconcept hashes
#  subconcept - data stored in timed under subconcept hash so this is needed for the return value to
#    give the correct structure back for datasets, target is left alone, add_timed_data will put the
#    data where it should go
#    the uses this value to find the data previous data from the correct sub-hash
# NOTE: does not handle counter wrapping at this time
# returns hashref with keys defined for datasets that have values
sub parse_rrd_update_data
{
	my ( $rrd_data, $target, $previous_pit, $subconcept ) = @_;
	die "subconcept required" if( !$subconcept );

	my %key_meta;
	foreach my $key ( keys %$rrd_data )
	{
		my $key_raw = $key . "_raw";
		my $entry   = $rrd_data->{$key};
		if ( $entry->{option} eq 'nosave' ) { }
		elsif ( $entry->{option} =~ /^counter/ )
		{
			$target->{$key_raw} = $entry->{value};

			# autovivifies but no problem
			my $prev_value
				= ( $previous_pit->{success} && exists( $previous_pit->{data}{$subconcept}->{$key_raw} ) )
				? $previous_pit->{data}{$subconcept}->{$key_raw}
				: undef;
			$target->{$key} = ($prev_value) ? ( $entry->{value} - $prev_value ) : 0;
			# TODO: handle counter wrapping!!!
			# $target->{$key} = ???!?!?
			# NMISNG::Util::logMsg( "ERROR: wrapped counter for $key $target->{$key} < $prev_value ") if( $target->{$key} && ($target->{$key} < $prev_value) );

			# try and force to a number
			$target->{$key} += 0.0;

			# keep track of dataset
			$key_meta{$key} = 1;
		}
		else
		{
			# try and force to a number
			$target->{$key} = $entry->{value} + 0.0;
			$key_meta{$key} = 1;
		}
	}
	# all changes are done in place
	return { $subconcept => \%key_meta };
}

# used to turn 'headers' section in a model into the keys and descriptions
# for displaying the subconcept in a table (for instance)
# headers lists the data keys to be displayed but does not describe the column
# headers, which can be re-defined in the model section
# args - model_section - place in the model this is coming from, proto - snmp/wmi
#  where to look in the model for the data/descriptions
sub parse_model_subconcept_headers
{
	my ($model_section,$proto) = @_;
	my $retval = [];
	my $headers = [ split(/\s*,\s*/, $model_section->{headers}) ];
	foreach my $key (@$headers)
	{
		my $title = $key;
		if( defined($model_section->{$proto}{$key}) &&
			 defined($model_section->{$proto}{$key}{title}) )
		{
			$title = $model_section->{$proto}{$key}{title};
		}
		push @$retval, { $key => $title };
	}
	return $retval;
}

###########
# Public:
###########

# create a new inventory manager object
# note: the object is always strictly associated with a node_uuid and a cluster_id
# this method is expected to be subclassed!
#
# params: concept (=class name, type of inventory),
#  nmisng (parent object), node_uuid, cluster_id,
#  data - all required
# optional: id  (alias _id, the db _id of this thing if it's not new),
#  path (used if provided, not required, normally can be calculated on save),
#  enabled (1/0, "nmis does something with this inventory item"),
#  historic (not present or 0, or anything else),
#  storage (hash of subconcept name -> path to the rrd file for this thing, relative to database_root),
#  path_key (must be arrayref if present - used for simplest path computation, ie. with listed keys from data),
#  description (optional, if not given a descriptive text is synthesized)
sub new
{
	my ( $class, %args ) = @_;

	my $nmisng = $args{nmisng};
	return undef if ( !$nmisng );    # check this early so we can use it to log

	for my $musthave (qw(concept cluster_id node_uuid))
	{
		if ( !defined $args{$musthave} )
		{
			$nmisng->log->fatal("Inventory object cannot be created without $musthave!");
			return undef;
		}
	}

	my $data = $args{data};
	if ( ref($data) ne "HASH" )
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid data argument!");
		return undef;
	}
	if ( defined( $args{storage} ) && ref( $args{storage} ) ne "HASH" )
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid storage argument!");
		return undef;
	}
	if ( defined( $args{path_keys} ) && ref( $args{path_keys} ne "ARRAY" ) )
	{
		$nmisng->log->fatal("Inventory object cannot be created with invalid path_keys argument!");
		return undef;
	}

	# compat issue, we *may* get _id
	$args{id} //= $args{_id};

	# description? we don't want any logic to abuse that, but having some human-friendly bits are desirable
	if ( !defined $args{description} )
	{
		my $nodenames = $nmisng->get_node_names( uuid => $args{node_uuid} );
		my $thisnodename = $nodenames->[0] // "UNKNOWN";    # can that happen?
		$args{description} = "concept $args{concept} on node $thisnodename and server $args{cluster_id}";
		$args{description} .= " with index " . $data->{index} if ( defined( $data->{index} ) && $data->{index} );
	}

	# set default properties, then update with args
	my $self = bless(
		{   _enabled  => 1,
			_historic => 0,
			(   map { ( "_$_" => $args{$_} ) } (
					qw(concept node_uuid cluster_id data id nmisng
						path path_keys storage subconcepts description
            lastupdate)
				)
			)
		},
		$class
	);

	# enabled and historic: override defaults only if explicitely given
	for my $onlyifgiven (qw(enabled historic))
	{
		$self->{"_$onlyifgiven"} = ( $args{$onlyifgiven} ? 1 : 0 ) if ( exists $args{$onlyifgiven} );
	}

	# in the object datasets are stored optimally for adding/checking (hash of hashes)
	# in the db they are stored optimally for querying/aggregating (array of arrays)
	my $dataset_info = $args{dataset_info} // [];
	die "dataset_info must be an array" . Carp::longmess() if ( ref($dataset_info) ne 'ARRAY' );
	$self->{_datasets} = {};
	foreach my $entry (@$dataset_info)
	{
		my $subconcept          = $entry->{subconcept};
		my $subconcept_datasets = $entry->{datasets};

		# turn arrays into hashes here, we store as array in db because we can't do much with keys in mongo
		my %dataset_map = map { $_ => 1 } (@$subconcept_datasets);
		$self->dataset_info( subconcept => $subconcept, datasets => \%dataset_map );
	}

	my $data_info = $args{data_info} // [];
	die "data_info must be an array" . Carp::longmess() if ( ref($data_info) ne 'ARRAY' );
	$self->{_data_info} = {};
	foreach my $entry (@$data_info)
	{
		$self->data_info( %$entry );
	}

	# in addition to these, there's also on-demand _deleted
	Scalar::Util::weaken $self->{_nmisng} if ( !Scalar::Util::isweak( $self->{_nmisng} ) );
	return $self;
}

# a simple setter/getter for the object,
# usable by subclasses
# expects: name => fieldname, optional value => newvalue
# returns the old value for updates, current value for reads
sub _generic_getset
{
		my ($self,%args) = @_;

		die "cannot read option without name!\n" if (!exists $args{name});
		my $fieldname = $args{name};

		my $curval = $self->data()->{$fieldname};
		if (exists $args{value})
		{
				my $newvalue = $args{value};
				$self->data()->{$fieldname} = $newvalue;
		}
		return $curval;
}

# this function adds one point-in-time data record for this concept instance
#
# PIT data can consist of two types of information, a 'derived_data' hash (might be deep, currently isn't),
# and a 'data' hash which MAY be deep if the caller controls datasets directly, or lets add_timed_data
# handle depth/structure via subconcept argument.
#
# note that the dataset info _in the inventory object_ is updated/extended from args given to this function.
#
# args: self (must have been saved, ie. have _id), data (hashref), derived_data (hashref),
# time (optional, defaults to now), delay_insert (optional, default no),
# subconcept OR datasets (exactly one is required)
# flush, internal only, used for saving delayed, does not allow modifying anything
#
# delay_insert - delay inserting until save is called - if it's never called it's not saved!
#   if data has already been queued for the time/concept/subconcept then new data provided will overwrite existing,
#   derived_data and data are treated separately, so data can be set one call and derived_data in another,
#   and per-subconcept data can be accumulated across calls as well.
#   delay/non-delay add's do not mix, if a delay call is followed by a non-delay, the non-delay will ignore
#   all existence of the delay'd data.
#
# subconcept/datasets - exactly one of these must be given!
#
# subconcept: must be string, SHOULD match one of the known subconcepts for this inventory;
#   if subconcept given, then data MUST be flat and add_timed_data arranges the
#   deep storage of data under this subconcept.
#   all keys in that data are automatically added to the inventory's dataset info.
#
# datasets: must be hash that represents ALL of the desired dataset info for this inventory,
#   ie. key subconceptA => { dsnameA => 1, dsnameB => 1 }, subconceptB => ....
#   in this case, data may be a deep hash. if you repeat calls with delay_save in that situation, the last
#   data/derived data wins. the inventory's datasets info is amended/extended from that dataset info.
#
#
# returns: undef or error message
#
# NOTE: inventory->save will call this function to saved "delayed_insert", the insert code below actually
#   calls inventory->save again, this seems like a possible bad thing. the reason it's working right now is
#   the second call to this function (from save) should not alter the datasets which is what triggers the save to be called
#  so it will never happen
# NOTE2: the data/derived data is not stored as is, it gets morphed from hash of hashes to array of hashes
#   data goes from subconcepts->{$} => { data=>{},derived_data=>{}}
#   to subconcepts => [{ subconcept=>$,data=>{},derived_data =>{}}]
sub add_timed_data
{
	my ( $self, %args ) = @_;



	return "cannot add timed data, invalid data argument!"
		if ( ref( $args{data} ) ne "HASH" );    # empty hash is acceptable
	return "cannot add timed data, invalid derived_data argument!"
		if ( ref( $args{derived_data} ) ne "HASH" );    # empty hash is acceptable
	my ( $data, $derived_data, $time, $delay_insert, $flush ) = @args{'data', 'derived_data', 'time', 'delay_insert','flush'};

	# automatically take care of datasets
	# one of these two must be defined
	my ( $subconcept, $datasets ) = @args{'subconcept', 'datasets'};
	return "subconcept is required stack:" . Carp::longmess() if ( !$subconcept && !$flush);
	return "datasets must be hash if defined" . Carp::longmess()
			if ( $datasets && ref($datasets) ne 'HASH' && !$flush );
	# ttl: record time plus purge_timeddata_after seconds (default 7 days)
	$time ||= Time::HiRes::time;
	my $expire_at = $time + ($self->nmisng->config->{purge_timeddata_after} || 7*86400);

	# to make the db ttl expiration work this must be
	# an acceptable date type for the driver version
	$expire_at = $NMISNG::DB::new_driver?
			Time::Moment->from_epoch($expire_at)
			: DateTime->from_epoch(epoch => $expire_at, time_zone => "UTC");

	# if the request is to delay, append to the existing queue (or make an empty hash), otherwise make a new record
	my $timedrecord = { time => $time, expire_at => $expire_at };
	$timedrecord = $self->{_queued_pit} if( defined($self->{_queued_pit}) );

	# if datasets was not given (and not flushing) try and figure out what the datasets are
	if (!$datasets && !$flush)
	{
		# todo: verify that structure is not deep, if it is this 'auto' getting datasets breaks down
		$datasets->{$subconcept} = {map { $_ => 1 } ( keys %$data )};
	}

	my $datasets_modfied = 0;
	if( !$flush )
	{
		# loop through all provided datasets and make sure they merged into
		# the existing, keeping track if any modifications are actually made
		# if this is a flush there is no need to do this, should already be done
		foreach my $subc ( keys %$datasets )
		{
			my $new_datasets = $datasets->{$subc};
			my $existing_datasets = $self->dataset_info( subconcept => $subc );
			foreach my $key ( keys %$new_datasets )
			{
				if ( !defined( $existing_datasets->{$key} ) )
				{
					$existing_datasets->{$key} = 1;
					$datasets_modfied++;
				}
			}
			$self->dataset_info( subconcept => $subc, datasets => $existing_datasets )
				if ($datasets_modfied);
		}
		# now store the data per subconcept, appending to data, replacing subconcept if it existed
		# if flush is given we already have this, flush
		$timedrecord->{data}{$subconcept} = $data;
		$timedrecord->{derived_data}{$subconcept} = $derived_data;
	}

	if ( !$delay_insert || $flush )
	{
		return "cannot add timed data to unsaved inventory instance!"
			if ( $self->is_new );

		$timedrecord->{inventory_id} = $self->id;

		# re-arrange the data for better searching/mongo work, turn it into array entry for each subconcept that
		# holds the subconcept name along with it's data/derived_data
		my @subconcepts = ();
		foreach my $subconcept (keys %{$timedrecord->{data}})
		{
			push @subconcepts, {
				subconcept => $subconcept,
				data => $timedrecord->{data}{$subconcept},
				derived_data => $timedrecord->{derived_data}{$subconcept}
			};
		}
		$timedrecord->{subconcepts} = \@subconcepts;
		delete $timedrecord->{data};
		delete $timedrecord->{derived_data};

		my $dbres = NMISNG::DB::insert(
			collection => $self->nmisng->timed_concept_collection( concept => $self->concept() ),
			record     => $timedrecord
		);
		return "failed to insert record: $dbres->{error}" if ( !$dbres->{success} );

		$dbres = NMISNG::DB::update(
			collection => $self->nmisng->latest_data_collection(),
			query => { inventory_id => $self->id },
			record => $timedrecord,
			upsert => 1
		);
		return "failed to upsert data record: $dbres->{error}" if ( !$dbres->{success} );

		# if the datasets were modified they need to be saved, only if we're not flushing
		# which should only come from save (so don't start a recursive loop)
		$self->save() if (!$flush && $datasets_modfied);
	}
	else
	{
		# only queue a single record
		$self->{_queued_pit} = $timedrecord;
	}
	return undef;
}

# retrieve the one most recent timed data for this instance, this will come from the latest_data
#  unless specifically told to get "from_timed"
#(note: raw _id and inventory_id are not returned: not useful)
# args: from_timed - set 1 if you must have the data from the timed_* collection
# returns: hashref of success, error, time, data.
sub get_newest_timed_data
{
	my ($self,%args) = @_;
	my $from_timed = $args{from_timed} // 0;

	# inventory not saved certainly means no pit data, but  that's no error
	return {success => 1} if ( $self->is_new );

	my $cursor;
	if( $from_timed )
	{
		$cursor = NMISNG::DB::find(
			collection => $self->nmisng->timed_concept_collection( concept => $self->concept() ),
			query => NMISNG::DB::get_query( and_part => {inventory_id => $self->id} ),
			limit => 1,
			sort        => {time => -1},
			fields_hash => {time => 1, subconcepts => 1}
		);
	}
	else
	{
		$cursor = NMISNG::DB::find(
			collection => $self->nmisng->latest_data_collection,
			query => NMISNG::DB::get_query( and_part => {inventory_id => $self->id} ),
			fields_hash => {time => 1, subconcepts => 1}
		);
	}
	return {success => 0, error => NMISNG::DB::get_error_string} if ( !$cursor );
	return {success => 1} if ( !$cursor->count );

	my $reading = $cursor->next;

	# data/derived data are stored for optimal searching (arrays of hashes),
	# turn them back into hashes (which are much handier for use in perl)
	# data goes from subconcepts => [{ subconcept=>$,data=>{},derived_data =>{}}]
	# to  data=>{$subconcept}{...},derived_data=>{$subconcept}{...}}
	foreach my $entry (@{$reading->{subconcepts}})
	{
		$reading->{data}{$entry->{subconcept}} = $entry->{data};
		$reading->{derived_data}{$entry->{subconcept}} = $entry->{derived_data};
	}

	return {success => 1, data => $reading->{data}, derived_data => $reading->{derived_data}, time => $reading->{time}};
}

# RO, returns cluster_id of this Inventory
sub cluster_id
{
	my ($self) = @_;
	return $self->{_cluster_id};
}

# RO, returns concept of this Inventory
sub concept
{
	my ($self) = @_;
	return $self->{_concept};
}

# returns the current description, optionally sets a new one
# args: newdescription
# returns: description
sub description
{
	my ( $self, $newdescription ) = @_;
	if ( @_ == 2 )    # new value undef is ok, description is deletable
	{
		$self->{_description} = $newdescription;
	}
	return $self->{_description};
}

# enabled/disabled are set when an inventory is found on a device
# but the system or user has decided not to use/collect/manage it
# returns the enabled status, optionally sets a new status
# args: newstatus (will be forced to 0/1)
sub enabled
{
	my ( $self, $newstatus ) = @_;
	if ( @_ == 2 )    # set new value even if input is undef
	{
		$self->{_enabled} = $newstatus ? 1 : 0;
	}
	return $self->{_enabled};
}

# historic is/should be set when an inventory was once found on a device
# but is no longer found on that device (but is still in the db!)
# returns the historic status (0/1)
#  optionally sets a new status
# args: newstatus (will be forced to 0/1)
sub historic
{
	my ( $self, $newstatus ) = @_;
	if ( @_ == 2 )    # set new value even if input is undef
	{
		$self->{_historic} = $newstatus ? 1 : 0;
	}
	return $self->{_historic};
}

# RO, returns nmisng object that this inventory object is using
sub nmisng
{
	my ($self) = @_;
	return $self->{_nmisng};
}

# RO, returns node_uuid of the owning node
sub node_uuid
{
	my ($self) = @_;
	return $self->{_node_uuid};
}

# returns the storage structure, optionally replaces it (all of it)
# to modify: call first to get, modify the copy, then call with the updated copy to set
# args: optional new storage NMISNG::Util::info (hashref)
# returns: clone of storage info, logs on error
sub storage
{
	my ( $self, $newstorage ) = @_;
	if ( @_ == 2 )    # ie. even if undef
	{
		if ( defined($newstorage) && ref($newstorage) ne "HASH" )
		{
			$self->nmisng->log->error( "storage accessor called with invalid argument, type " . ref($newstorage) );
		}
		else
		{
			$self->{_storage} = Clone::clone($newstorage);

			# and update the subconcepts list
			$self->{_subconcepts} = [List::MoreUtils::uniq( keys %{$self->{_storage}} )];
		}
	}
	return Clone::clone( $self->{_storage} );
}

# small r/o accessor to the list of unique subconcepts, as declared by the storage structure
# args: none
# returns: array ref (cloned, might be empty)
sub subconcepts
{
	my ($self) = @_;
	return defined( $self->{_subconcepts} ) ? Clone::clone( $self->{_subconcepts} ) : [];
}

# small accessor that looks up a storage subconcept
# and returns the requested storage type info for it
#
# args: subconcept (required), type (optional, default rrd)
# returns: undef or rhs of the type record (for rrd that's normally a path)
sub find_subconcept_type_storage
{
	my ( $self, %args ) = @_;
	my $type = $args{type} || 'rrd';
	my $subconcept = $args{subconcept};
	return undef
		if (
		   !$subconcept
		or ref( $self->{_storage} ) ne "HASH"
		or ref( $self->{_storage}->{$subconcept} ) ne "HASH"    # better than pure existence check
		or !exists( $self->{_storage}->{$subconcept}->{$type} )
		);

	return $self->{_storage}->{$subconcept}->{$type};           # no cloning needed until this becomes a deep structure
}

# small helper to update a storage subconcept
# note: this does update the inventory's storage object!
#
# args: subconcept (=name), type (optional, default rrd), data (= new value, undef to delete, anything else to update)
# returns: nothing
sub set_subconcept_type_storage
{
	my ( $self, %args ) = @_;
	my ( $subconcept, $type, $data ) = @args{"subconcept", "type", "data"};
	$type //= "rrd";

	# already empty, no-op.
	return if ( !defined( $self->{_storage} ) && !defined($data) );
	$self->{_storage} //= {};

	if ( defined $data )
	{
		$self->{_storage}->{$subconcept}->{$type} = $data;
	}
	else
	{
		delete $self->{_storage}->{$subconcept}->{$type};
		delete $self->{_storage}->{$subconcept}
			if ( !keys %{$self->{_storage}->{$subconcept}} );    # if nothing else left
	}

	# and update the subconcepts list
	$self->{_subconcepts} = [List::MoreUtils::uniq( keys %{$self->{_storage}} )];

	return;
}

# returns the path keys list, optionally replaces it
# args: new path_keys (arrayref)
# returns: clone of path_keys
# note: not possible to delete path_keys.
sub path_keys
{
	my ( $self, $newvalue ) = @_;
	if ( defined($newvalue) && ref($newvalue) eq 'ARRAY' )
	{
		$self->{_path_keys} = Clone::clone($newvalue);
	}
	return Clone::clone( $self->{_path_keys} );
}

# returns a copy of the data component of this inventory object, optionally replaces data (all of it)
# (i.e. the parts possibly specific to this instance class)
#
# to change data: call first to get, modify the copy, then call with the updated copy to set
# args: optional data (hashref),
# returns: clone of data, logs on error
sub data
{
	my ( $self, $newvalue ) = @_;

	if ( $self->{_live} )
	{
		# in some instances this makes sense or all places will need to learn to check live, that might make sense
		# not sure right now so this has been added
		return $self->data_live();
	}

	if ( defined($newvalue) )
	{

		if ( $self->{_live} )
		{
			$self->nmisng->log->fatal( "Accessing/saving data to this inventory, concept:"
					. $self->concept
					. " is not allowed because it's live\n"
					. Carp::longmess() );
		}
		else
		{
			if ( ref($newvalue) ne "HASH" )
			{
				$self->nmisng->log->error( "data accessor called with invalid argument " . ref($newvalue) );
			}
			else
			{
				$self->{_data} = Clone::clone($newvalue);
			}
		}
	}
	return Clone::clone( $self->{_data} );
}

# returns a ref to the data, after doing this the object cannot be accessed via normal data function
# returns: clone of data, logs on error
sub data_live
{
	my ($self) = @_;

	$self->{_live} = 1;

	return $self->{_data};
}

# set columns available for data by subconcept, enable/disable the visiblity of the subconcept
sub data_info
{
	my ( $self, %args ) = @_;
	my ( $subconcept, $enabled, $display_keys ) = @args{'subconcept', 'enabled', 'display_keys'};
	return "cannot get or set data_info, invalid subconcept argument:$subconcept!"
		if ( !$subconcept );    # must be something

	if( defined($enabled) || defined($display_keys) )
	{
		$self->{_data_info}{$subconcept} = {
			enabled => $enabled,
			display_keys => $display_keys // []
		};
	}
	return $self->{_data_info}{$subconcept} // undef;
}

# returns hashref of datasets defined for the specified subconcept or empty hash
# arguments: subconcept - string, [newvalue] - new dataset hashref for given subconcept
# right now dataset subconcepts are not hooked up to subconcept list
sub dataset_info
{
	my ( $self, %args ) = @_;
	my ( $subconcept, $datasets ) = @args{'subconcept', 'datasets'};

	return "cannot get or set dataset_info, invalid subconcept argument:$subconcept!"
		if ( !$subconcept );    # must be something

	if ( defined($datasets) )
	{
		return "cannot set datasets, invalid newvalue argument!"
			if ( ref($datasets) ne "HASH" );    # empty hash is acceptable
		$self->{_datasets}{$subconcept} = $datasets;

		# print "set datasets for $subconcept to ".Dumper($self->{_datasets}{$subconcept});
	}
	return $self->{_datasets}{$subconcept} // {};
}

# remove this inventory entry from the db
# can't delete if its new, or if it's already been deleted or if it doesn't have an id
#  (which is_new checks but not a bad idea to double check)
sub delete
{
	my ($self) = @_;

	if ( !$self->is_new && !$self->{_deleted} && $self->id() )
	{
		my $result = NMISNG::DB::remove(
			collection => $self->nmisng->inventory_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $self->id()} ),
			just_one   => 1
		);
		$self->{_deleted} = 1 if ( $result->{success} );
		return ( $result->{success}, $result->{error} );
	}
	else
	{
		return ( undef, "Inventory did not meet criteria for deleting" );
	}
}

# get the id (_id), readonly
# save adjusts this so is_new returns properly
# may be undef if is_new
sub id
{
	my ($self) = @_;
	return $self->{_id};
}

# has this inventory object been deleted from the db
sub is_deleted
{
	my ($self) = @_;
	return ( $self->{_deleted} == 1 );
}

# returns 0/1 if the object is new or not.
# new means it is not yet in the aabase
sub is_new
{
	my ($self) = @_;

	my $has_id = $self->id();
	return ($has_id) ? 0 : 1;
}

sub lastupdate
{
	my ($self) = @_;
	return $self->{_lastupdate} if ( !$self->is_new );
	return;
}

# reload this object from db, handy for testing to make sure update has been successful
# args: none, just needs self's id
# returns: undef or error message
sub reload
{
	my ($self) = @_;

	if ( !$self->is_new )
	{
		my $modeldata = $self->nmisng->get_inventory_model( _id => $self->id );
		return "no inventory object with id " . $self->id . " in database!" if ( !$modeldata->count );
		my $newme = $modeldata->data()->[0];

		# some things are ro/no settergetter, path MUST be set directly, its accessor gets confused by id/is_new!
		for my $copyable (qw(cluster_id node_uuid concept path lastupdate))
		{
			$self->{"_$copyable"} = $newme->{$copyable};
		}

		# others are supposed to be settable via accessor
		for my $settable (qw(data storage historic enabled path_keys description))
		{
			$self->$settable( $newme->{$settable} );
		}
	}
	else
	{
		return "cannot reload unsaved inventory object!";
	}
	return undef;
}

# (re)make or get the path and return it
# args: recalculate - [0/1], optional (default 0)
# returns: arrayref
#
# new objects will recalculate their path on each call, specifiying recalculate makes no difference
# objects which are not new should already have a path and that value will be returned
# unless recalculate is specified.
# path is made by Class method corresponding to the this objects concept
# NOTE: the use of path keys below breaks convention,
sub path
{
	my ( $self, %args ) = @_;

	my $path;
	if ( !$self->is_new() && !$self->{_path} && !$args{recalculate} )
	{
		$self->nmisng->log->error("Saved inventory should already have a path!");
	}
	elsif ( !$self->is_new() && $self->{_path} && !$args{recalculate} )
	{
		$path = $self->{_path};
	}
	else
	{
		# make_path itself will ignore the first arg here, but finding the right subclass's
		# make_path does require it.
		$path = $self->make_path(
			cluster_id => $self->cluster_id,
			node_uuid  => $self->node_uuid,
			concept    => $self->concept,
			path_keys  => $self->path_keys,    # possibly nonex, up to subclass to worry about
			data       => $self->data
		);

		# always store the path, it may be re-calculated next time but that's fine
		# if we don't store here recalculate/save won't work
		$self->{_path} = $path;
	}
	$self->nmisng->log->error("Path must be an array!") if ( ref($path) ne "ARRAY" );

	return $path;
}

# save the inventory obj in the database
# args: lastupdate, optional, defaults to now
#
# note: lastupdate and expire_at currently not added to object but stored in db only
# the object's _id and _path are refreshed
# returns ($op,$error), op is 1 for insert, 2 for save, error is string if there was an error
sub save
{
	my ( $self, %args ) = @_;
	my $lastupdate = $args{lastupdate} // time;

	my ( $valid, $validation_error ) = $self->validate();
	return ( $valid, $validation_error ) if ( !$valid );

	my ( $result, $op );

	my $record = {
		cluster_id => $self->cluster_id,
		node_uuid  => $self->node_uuid,
		concept    => $self->concept(),
		path       => $self->path(),         # path is calculated but must be stored so it can be queried
		path_keys  => $self->path_keys(),    # could be empty, kept in db for selfcontainment and convenience

		description => $self->description(),
		data        => $self->data(),
		storage     => $self->storage(),
		subconcepts => $self->subconcepts(),

		enabled  => $self->enabled(),
		historic => $self->historic(),

		lastupdate => $lastupdate,
	};

	# if not historic: extend expire_at ttl off the current lastupdate
	if (!$self->historic)
	{
		# to make the db ttl expiration work this must be
		# an acceptable date type for the driver version
		my $pleasegoaway = $lastupdate + ($self->nmisng->config->{purge_inventory_after} || 14*86400);
		$pleasegoaway = $NMISNG::DB::new_driver?
				Time::Moment->from_epoch($pleasegoaway)
				: DateTime->from_epoch(epoch => $pleasegoaway, time_zone => "UTC");

		$record->{expire_at} = $pleasegoaway;
	}

	# numify anything in path
	my $path = $record->{path};

	for ( my $i = 0; $i < @$path; $i++ )
	{
		$path->[$i] = NMISNG::Util::numify( $path->[$i] );
	}

	# right now dataset subconcepts are not hooked up to subconcept list
	$record->{dataset_info} = [];
	foreach my $subconcept ( keys %{$self->{_datasets}} )
	{
		my @datasets = keys %{$self->dataset_info( subconcept => $subconcept )};
		push @{$record->{dataset_info}}, {subconcept => $subconcept, datasets => \@datasets};
	}

	# data_info gets changed like dataset_info for easier mongo work, store as array with
	# predictable keys
	$record->{data_info} = [];
	foreach my $subconcept ( keys %{$self->{_data_info}} )
	{
		my $subconcept_info = $self->data_info( subconcept => $subconcept );
		push( @{$record->{data_info}}, { %$subconcept_info, subconcept => $subconcept });
	}

	if ( $self->is_new() )
	{
		# could maybe be upsert?
		$result = NMISNG::DB::insert(
			collection => $self->nmisng->inventory_collection,
			record     => $record,
		);
		$op = 1;

		# _id is set on insert, grab it so we know we're not new
		$self->{_id} = $result->{id} if ( $result->{success} );
	}
	else
	{
		$record->{_id} = $self->id();
		$result = NMISNG::DB::update(
			collection => $self->nmisng->inventory_collection,
			query      => NMISNG::DB::get_query( and_part => {_id => $record->{_id}} ),
			record     => $record
		);
		$op = 2;
	}

	# reset path to what was saved, probably the same but safe
	$self->{_path} = $record->{path} if ( $result->{success} );

	# save any queued time/pit data, not expecting many here so not very optimised
	if ( $result->{success} && defined($self->{_queued_pit}) )
	{
		my $pit_record = $self->{_queued_pit};
		# using ourself means id will be added (so new inventories will work, no save first required)
		# telling it to flush should bypass any special handling, allowing the data straight through
		my $error = $self->add_timed_data(flush => 1, %$pit_record);
		if ($error)
		{
			$result->{success} = 0;
			$result->{error} .= "Error saving time data: $error";
		}
		else
		{
			# clean up successful saves
			delete $self->{_queued_pit};
		}
	}

	$self->{_lastupdate} = $lastupdate if ( $result->{success} );
	return ( $result->{success} ) ? ( $op, undef ) : ( undef, $result->{error} );
}

# returns 0/1 if the node is valid
sub validate
{
	my ($self)  = @_;
	my $path    = $self->path();
	my $storage = $self->storage;

	# must have, alphabetical for now, make cheapest first later?
	return ( -1, "invalid cluster_id" )        if ( !$self->cluster_id );
	return ( -2, "invalid concept" )           if ( !$self->concept );
	return ( -3, "invalid data" )              if ( ref( $self->data() ) ne 'HASH' );
	return ( -4, "invalid path" )              if ( !$path || @$path < 1 );
	return ( -5, "invalid node_uuid" )         if ( !$self->node_uuid );
	return ( -6, "invalid storage structure" ) if ( defined($storage) && ref($storage) ne "HASH" );

	foreach my $entry (@$path)
	{
		return ( 6, "invalid, empty path entries not allowed" ) if ( !$entry );
	}

	return 1;
}

1;
