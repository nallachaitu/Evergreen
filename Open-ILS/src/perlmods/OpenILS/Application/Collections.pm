package OpenILS::Application::Collections;
use strict; use warnings;
use OpenSRF::EX qw(:try);
use OpenILS::Application::AppUtils;
use OpenSRF::Utils::Logger qw(:logger);
use OpenSRF::Application;
use OpenILS::Utils::Fieldmapper;
use base 'OpenSRF::Application';
use OpenILS::Utils::CStoreEditor qw/:funcs/;
use OpenILS::Event;
use OpenILS::Const qw/:const/;
my $U = "OpenILS::Application::AppUtils";


# --------------------------------------------------------------
# Loads the config info
# --------------------------------------------------------------
sub initialize { return 1; }

__PACKAGE__->register_method(
	method => 'user_from_bc',
	api_name => 'open-ils.collections.user_id_from_barcode',
);

sub user_from_bc {
	my( $self, $conn, $auth, $bc ) = @_;
	my $e = new_editor(authtoken=>$auth);
	return $e->event unless $e->checkauth;
	return $e->event unless $e->allowed('VIEW_USER'); 
	my $card = $e->search_actor_card({barcode=>$bc})->[0]
		or return $e->event;
	my $user = $e->retrieve_actor_user($card->usr)
		or return $e->event;
	return $user->id;	
}


__PACKAGE__->register_method(
	method    => 'users_of_interest',
	api_name  => 'open-ils.collections.users_of_interest.retrieve',
	api_level => 1,
	argc      => 4,
    stream    => 1,
	signature => { 
		desc     => q/
			Returns an array of user information objects that the system 
			based on the search criteria provided.  If the total fines
			a user owes reaches or exceeds "fine_level" on or befre "age"
			and the fines were created at "location", the user will be 
			included in the return set/,
		            
		params   => [
			{	name => 'auth',
				desc => 'The authentication token',
				type => 'string' },

			{	name => 'age',
				desc => q/The date before or at which the user's fine level exceeded the fine_level param/,
				type => q/string (ISO 8601 timestamp.  E.g. 2006-06-24, 1994-11-05T08:15:30-05:00 /,
			},

			{	name => 'fine_level',
				desc => q/The fine threshold at which users will be included in the search results /,
				type => q/string (ISO 8601 timestamp.  E.g. 2006-06-24, 1994-11-05T08:15:30-05:00 /,
			},
			{	name => 'location',
				desc => q/The short-name of the orginization unit (library) at which the fines were created.  
							If a selected location has 'child' locations (e.g. a library region), the
							child locations will be included in the search/,
				type => q/string/,
			},
		],

	  	'return' => { 
			desc		=> q/An array of user information objects.  
						usr : Array of user information objects containing id, dob, profile, and groups
						threshold_amount : The total amount the patron owes that is at least as old
							as the fine "age" and whose transaction was created at the searched location
						last_pertinent_billing : The time of the last billing that relates to this query
						/,
			type		=> 'array',
			example	=> {
				usr	=> {
					id			=> 'id',
					dob		=> '1970-01-01',
					profile	=> 'Patron',
					groups	=> [ 'Patron', 'Staff' ],
				},
				threshold_amount => 99,
			}
		}
	}
);


sub users_of_interest {
	my( $self, $conn, $auth, $age, $fine_level, $location ) = @_;

	return OpenILS::Event->new('BAD_PARAMS') 
		unless ($auth and $age and $fine_level and $location);

	my $e = new_editor(authtoken => $auth);
	return $e->event unless $e->checkauth;

	my $org = $e->search_actor_org_unit({shortname => $location})
		or return $e->event; $org = $org->[0];

	# they need global perms to view users so no org is provided
	return $e->event unless $e->allowed('VIEW_USER'); 

   my $data = [];

   my $ses = OpenSRF::AppSession->create('open-ils.storage');
   my $req = $ses->request(
      'open-ils.storage.money.collections.users_of_interest', 
      $age, $fine_level, $location);

   # let the client know we're still here
   $conn->status( new OpenSRF::DomainObject::oilsContinueStatus );

   while( my $resp = $req->recv(timeout => 600) ) {
      return $req->failed if $req->failed;
      my $hash = $resp->content;
      next unless $hash;

      my $u = $e->retrieve_actor_user(
         [
	         $hash->{usr},
	         {
		         flesh				=> 1,
		         flesh_fields	=> {au => ["groups","profile", "card"]},
		         #select			=> {au => ["profile","id","dob", "card"]}
	         }
         ]
      ) or return $e->event;

      $hash->{usr} = {
         id			=> $u->id,
         dob		=> $u->dob,
         profile	=> $u->profile->name,
         barcode	=> $u->card->barcode,
         groups	=> [ map { $_->name } @{$u->groups} ],
      };
      
      $conn->respond($hash);
   }

   return undef;
}


__PACKAGE__->register_method(
	method    => 'users_with_activity',
	api_name  => 'open-ils.collections.users_with_activity.retrieve',
	api_level => 1,
	argc      => 4,
	signature => { 
		desc     => q/
			Returns an array of users that are already in collections 
			and had any type of billing or payment activity within
			the given time frame at the location (or child locations)
			provided/,
		            
		params   => [
			{	name => 'auth',
				desc => 'The authentication token',
				type => 'string' },

			{	name => 'start_date',
				desc => 'The start of the time interval to check',
				type => q/string (ISO 8601 timestamp.  E.g. 2006-06-24, 1994-11-05T08:15:30-05:00 /,
			},

			{	name => 'end_date',
				desc => q/Then end date of the time interval to check/,
				type => q/string (ISO 8601 timestamp.  E.g. 2006-06-24, 1994-11-05T08:15:30-05:00 /,
			},
			{	name => 'location',
				desc => q/The short-name of the orginization unit (library) at which the activity occurred.
							If a selected location has 'child' locations (e.g. a library region), the
							child locations will be included in the search/,
				type => q'string',
			},
		],

	  	'return' => { 
			desc		=> q/An array of user information objects/,
			type		=> 'array',
		}
	}
);

sub users_with_activity {
	my( $self, $conn, $auth, $start_date, $end_date, $location ) = @_;
	return OpenILS::Event->new('BAD_PARAMS') 
		unless ($auth and $start_date and $end_date and $location);

	my $e = new_editor(authtoken => $auth);
	return $e->event unless $e->checkauth;

	my $org = $e->search_actor_org_unit({shortname => $location})
		or return $e->event; $org = $org->[0];
	return $e->event unless $e->allowed('VIEW_USER', $org->id);

	return $U->storagereq(
		'open-ils.storage.money.collections.users_with_activity.atomic', 
		$start_date, $end_date, $location);
}



__PACKAGE__->register_method(
	method    => 'put_into_collections',
	api_name  => 'open-ils.collections.put_into_collections',
	api_level => 1,
	argc      => 3,
	signature => { 
		desc     => q/
			Marks a user as being "in collections" at a given location
			/,
		            
		params   => [
			{	name => 'auth',
				desc => 'The authentication token',
				type => 'string' },

			{	name => 'user_id',
				desc => 'The id of the user to plact into collections',
				type => 'number',
			},

			{	name => 'location',
				desc => q/The short-name of the orginization unit (library) 
					for which the user is being placed in collections/,
				type => q'string',
			},
			{	name => 'fee_amount',
				desc => q/
					The amount of money that a patron should be fined.  
					If this field is empty, no fine is created.
				/,
				type => 'string',
			},
			{	name => 'fee_note',
				desc => q/
					Custom note that is added to the the billing.  
					This field is not required.
					Note: fee_note is not the billing_type.  Billing_type type is
					decided by the system. (e.g. "fee for collections").  
					fee_note is purely used for any additional needed information
					and is only visible to staff.
				/,
				type => 'string',
			},
		],

	  	'return' => { 
			desc		=> q/A SUCCESS event on success, error event on failure/,
			type		=> 'object',
		}
	}
);
sub put_into_collections {
	my( $self, $conn, $auth, $user_id, $location, $fee_amount, $fee_note ) = @_;

	return OpenILS::Event->new('BAD_PARAMS') 
		unless ($auth and $user_id and $location);

	my $e = new_editor(authtoken => $auth, xact =>1);
	return $e->event unless $e->checkauth;

	my $org = $e->search_actor_org_unit({shortname => $location});
	return $e->event unless $org = $org->[0];
	return $e->event unless $e->allowed('money.collections_tracker.create', $org->id);

	my $existing = $e->search_money_collections_tracker(
		{
			location		=> $org->id,
			usr			=> $user_id,
			collector	=> $e->requestor->id
		},
		{idlist => 1}
	);

	return OpenILS::Event->new('MONEY_COLLECTIONS_TRACKER_EXISTS') if @$existing;

	$logger->info("collect: user ".$e->requestor->id. 
		" putting user $user_id into collections for $location");

	my $tracker = Fieldmapper::money::collections_tracker->new;

	$tracker->usr($user_id);
	$tracker->collector($e->requestor->id);
	$tracker->location($org->id);
	$tracker->enter_time('now');

	$e->create_money_collections_tracker($tracker) 
		or return $e->event;

	if( $fee_amount ) {
		my $evt = add_collections_fee($e, $user_id, $org, $fee_amount, $fee_note );
		return $evt if $evt;
	}

	$e->commit;
	return OpenILS::Event->new('SUCCESS');
}

sub add_collections_fee {
	my( $e, $patron_id, $org, $fee_amount, $fee_note ) = @_;

	$fee_note ||= "";

	$logger->info("collect: adding fee to user $patron_id : $fee_amount : $fee_note");

	my $xact = Fieldmapper::money::grocery->new;
	$xact->usr($patron_id);
	$xact->xact_start('now');
	$xact->billing_location($org->id);

	$xact = $e->create_money_grocery($xact) or return $e->event;

	my $bill = Fieldmapper::money::billing->new;
	$bill->note($fee_note);
	$bill->xact($xact->id);
	$bill->billing_type(OILS_BILLING_TYPE_COLLECTION_FEE);
	$bill->amount($fee_amount);

	$e->create_money_billing($bill) or return $e->event;
	return undef;
}




__PACKAGE__->register_method(
	method		=> 'remove_from_collections',
	api_name		=> 'open-ils.collections.remove_from_collections',
	signature	=> q/
		Returns the users that are currently in collections and
		had activity during the provided interval.  Dates are inclusive.
		@param start_date The beginning of the activity interval
		@param end_date The end of the activity interval
		@param location The location at which the fines were created
	/
);


__PACKAGE__->register_method(
	method    => 'remove_from_collections',
	api_name  => 'open-ils.collections.remove_from_collections',
	api_level => 1,
	argc      => 3,
	signature => { 
		desc     => q/
			Removes a user from the collections table for the given location
			/,
		            
		params   => [
			{	name => 'auth',
				desc => 'The authentication token',
				type => 'string' },

			{	name => 'user_id',
				desc => 'The id of the user to plact into collections',
				type => 'number',
			},

			{	name => 'location',
				desc => q/The short-name of the orginization unit (library) 
					for which the user is being removed from collections/,
				type => q'string',
			},
		],

	  	'return' => { 
			desc		=> q/A SUCCESS event on success, error event on failure/,
			type		=> 'object',
		}
	}
);

sub remove_from_collections {
	my( $self, $conn, $auth, $user_id, $location ) = @_;

	return OpenILS::Event->new('BAD_PARAMS') 
		unless ($auth and $user_id and $location);

	my $e = new_editor(authtoken => $auth, xact=>1);
	return $e->event unless $e->checkauth;

	my $org = $e->search_actor_org_unit({shortname => $location})
		or return $e->event; $org = $org->[0];
	return $e->event unless $e->allowed('money.collections_tracker.delete', $org->id);

	my $tracker = $e->search_money_collections_tracker(
		{ usr => $user_id, location => $org->id })
		or return $e->event;

	$e->delete_money_collections_tracker($tracker->[0])
		or return $e->event;

	$e->commit;
	return OpenILS::Event->new('SUCCESS');
}


#__PACKAGE__->register_method(
#	method		=> 'transaction_details',
#	api_name		=> 'open-ils.collections.user_transaction_details.retrieve',
#	signature	=> q/
#	/
#);


__PACKAGE__->register_method(
	method    => 'transaction_details',
	api_name  => 'open-ils.collections.user_transaction_details.retrieve',
	api_level => 1,
	argc      => 5,
	signature => { 
		desc     => q/
			Returns a list of fleshed user objects with transaction details
			/,
		            
		params   => [
			{	name => 'auth',
				desc => 'The authentication token',
				type => 'string' },

			{	name => 'start_date',
				desc => 'The start of the time interval to check',
				type => q/string (ISO 8601 timestamp.  E.g. 2006-06-24, 1994-11-05T08:15:30-05:00 /,
			},

			{	name => 'end_date',
				desc => q/Then end date of the time interval to check/,
				type => q/string (ISO 8601 timestamp.  E.g. 2006-06-24, 1994-11-05T08:15:30-05:00 /,
			},
			{	name => 'location',
				desc => q/The short-name of the orginization unit (library) at which the activity occurred.
							If a selected location has 'child' locations (e.g. a library region), the
							child locations will be included in the search/,
				type => q'string',
			},
			{
				name => 'user_list',
				desc => 'An array of user ids',
				type => 'array',
			},
		],

	  	'return' => { 
			desc		=> q/A list of objects.  Object keys include:
				usr :
				transactions : An object with keys :
					circulations : Fleshed circulation objects
					grocery : Fleshed 'grocery' transaction objects
				/,
			type		=> 'object'
		}
	}
);

sub transaction_details {
	my( $self, $conn, $auth, $start_date, $end_date, $location, $user_list ) = @_;

	return OpenILS::Event->new('BAD_PARAMS') 
		unless ($auth and $start_date and $end_date and $location and $user_list);

	my $e = new_editor(authtoken => $auth);
	return $e->event unless $e->checkauth;

	# they need global perms to view users so no org is provided
	return $e->event unless $e->allowed('VIEW_USER'); 

	my $org = $e->search_actor_org_unit({shortname => $location})
		or return $e->event; $org = $org->[0];

	# get a reference to the org inside of the tree
	$org = $U->find_org($U->fetch_org_tree(), $org->id);

	my @data;
	for my $uid (@$user_list) {
		my $blob = {};

		$blob->{usr} = $e->retrieve_actor_user(
			[
				$uid,
         	{
            	"flesh"        => 1,
            	"flesh_fields" =>  {
               	"au" => [
                  	"cards",
                  	"card",
                  	"standing_penalties",
                  	"addresses",
                  	"billing_address",
                  	"mailing_address",
                  	"stat_cat_entries"
               	]
            	}
         	}
			]
		);

		$blob->{transactions} = {
			circulations	=> 
				fetch_circ_xacts($e, $uid, $org, $start_date, $end_date),
			grocery			=> 
				fetch_grocery_xacts($e, $uid, $org, $start_date, $end_date)
		};

		# for each transaction, flesh the workstatoin on any attached payment
		# and make the payment object a real object (e.g. cash payment), 
		# not just a generic payment object
		for my $xact ( 
			@{$blob->{transactions}->{circulations}}, 
			@{$blob->{transactions}->{grocery}} ) {

			my $ps;
			if( $ps = $xact->payments and @$ps ) {
				my @fleshed; my $evt;
				for my $p (@$ps) {
					($p, $evt) = flesh_payment($e,$p);
					return $evt if $evt;
					push(@fleshed, $p);
				}
				$xact->payments(\@fleshed);
			}
		}

		push( @data, $blob );
	}

	return \@data;
}

sub flesh_payment {
	my $e = shift;
	my $p = shift;
	my $type = $p->payment_type;
	$logger->debug("collect: fleshing workstation on payment $type : ".$p->id);
	my $meth = "retrieve_money_$type";
	$p = $e->$meth($p->id) or return (undef, $e->event);
	try {
		$p->payment_type($type);
		$p->cash_drawer(
			$e->retrieve_actor_workstation(
				[
					$p->cash_drawer,
					{
						flesh => 1,
						flesh_fields => { aws => [ 'owning_lib' ] }
					}
				]
			)
		);
	} catch Error with {};
	return ($p);
}


# --------------------------------------------------------------
# Collect all open circs for the user 
# For each circ, see if any billings or payments were created
# during the given time period.  
# --------------------------------------------------------------
sub fetch_circ_xacts {
	my $e				= shift;
	my $uid			= shift;
	my $org			= shift;
	my $start_date = shift;
	my $end_date	= shift;

	my @circs;

	# at the specified org and each descendent org, 
	# fetch the open circs for this user
	$U->walk_org_tree( $org, 
		sub {
			my $n = shift;
			$logger->debug("collect: searching for open circs at " . $n->shortname);
			push( @circs, 
				@{
					$e->search_action_circulation(
						{
							usr			=> $uid, 
							circ_lib		=> $n->id,
						}, 
						{idlist => 1}
					)
				}
			);
		}
	);


	my @data;
	my $active_ids = fetch_active($e, \@circs, $start_date, $end_date);

	for my $cid (@$active_ids) {
		push( @data, 
			$e->retrieve_action_circulation(
				[
					$cid,
					{
						flesh => 1,
						flesh_fields => { 
							circ => [ "billings", "payments", "circ_lib", 'target_copy' ]
						}
					}
				]
			)
		);
	}

	return \@data;
}

sub set_copy_price {
	my( $e, $copy ) = @_;
	return if $copy->price and $copy->price > 0;
	my $vol = $e->retrieve_asset_call_number($copy->call_number);
	my $org = ($vol and $vol->id != OILS_PRECAT_CALL_NUMBER) 
		? $vol->owning_lib : $copy->circ_lib;
	my $setting = $e->retrieve_actor_org_unit_setting(
		{ org_unit => $org, name => OILS_SETTING_DEF_ITEM_PRICE } );
	$copy->price($setting->value);
}



sub fetch_grocery_xacts {
	my $e				= shift;
	my $uid			= shift;
	my $org			= shift;
	my $start_date = shift;
	my $end_date	= shift;

	my @xacts;
	$U->walk_org_tree( $org, 
		sub {
			my $n = shift;
			$logger->debug("collect: searching for open grocery xacts at " . $n->shortname);
			push( @xacts, 
				@{
					$e->search_money_grocery(
						{
							usr					=> $uid, 
							billing_location	=> $n->id,
						}, 
						{idlist => 1}
					)
				}
			);
		}
	);

	my @data;
	my $active_ids = fetch_active($e, \@xacts, $start_date, $end_date);

	for my $id (@$active_ids) {
		push( @data, 
			$e->retrieve_money_grocery(
				[
					$id,
					{
						flesh => 1,
						flesh_fields => { 
							mg => [ "billings", "payments", "billing_location" ] }
					}
				]
			)
		);
	}

	return \@data;
}



# --------------------------------------------------------------
# Given a list of xact id's, this returns a list of id's that
# had any activity within the given time span
# --------------------------------------------------------------
sub fetch_active {
	my( $e, $ids, $start_date, $end_date ) = @_;

	# use this..
	# { payment_ts => { between => [ $start, $end ] } } ' ;) 

	my @active;
	for my $id (@$ids) {

		# see if any billings were created in the given time range
		my $bills = $e->search_money_billing (
			{
				xact			=> $id,
				billing_ts	=> { between => [ $start_date, $end_date ] },
			},
			{idlist =>1}
		);

		my $payments = [];

		if( !@$bills ) {

			# see if any payments were created in the given range
			$payments = $e->search_money_payment (
				{
					xact			=> $id,
					payment_ts	=> { between => [ $start_date, $end_date ] },
				},
				{idlist =>1}
			);
		}


		push( @active, $id ) if @$bills or @$payments;
	}

	return \@active;
}


__PACKAGE__->register_method(
	method    => 'create_user_note',
	api_name  => 'open-ils.collections.patron_note.create',
	api_level => 1,
	argc      => 4,
	signature => { 
		desc     => q/ Adds a note to a patron's account /,
		params   => [
			{	name => 'auth',
				desc => 'The authentication token',
				type => 'string' },

			{	name => 'user_barcode',
				desc => q/The patron's barcode/,
				type => q/string/,
			},
			{	name => 'title',
				desc => q/The title of the note/,
				type => q/string/,
			},

			{	name => 'note',
				desc => q/The text of the note/,
				type => q/string/,
			},
		],

	  	'return' => { 
			desc		=> q/
				Returns SUCCESS event on success, error event otherwise.
				/,
			type		=> 'object'
		}
	}
);


sub create_user_note {
	my( $self, $conn, $auth, $user_barcode, $title, $note_txt ) = @_;

	my $e = new_editor(authtoken=>$auth, xact=>1);
	return $e->event unless $e->checkauth;
	return $e->event unless $e->allowed('UPDATE_USER'); # XXX Makre more specific perm for this

	return $e->event unless 
		my $card = $e->search_actor_card({barcode=>$user_barcode})->[0];

	my $note = Fieldmapper::actor::usr_note->new;
	$note->usr($card->usr);
	$note->title($title);
	$note->creator($e->requestor->id);
	$note->create_date('now');
	$note->pub('f');
	$note->value($note_txt);

	$e->create_actor_usr_note($note) or return $e->event;
	$e->commit;
	return OpenILS::Event->new('SUCCESS');
}



1;
