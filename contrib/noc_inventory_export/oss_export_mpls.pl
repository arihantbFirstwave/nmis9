#!/usr/bin/perl
#
## $Id: export_nodes.pl,v 1.1 2012/08/13 05:09:17 keiths Exp $
#
#  Copyright (C) Opmantek Limited (www.opmantek.com)
#
#  ALL CODE MODIFICATIONS MUST BE SENT TO CODE@OPMANTEK.COM
#
#  This file is part of Network Management Information System ("NMIS").
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

use strict;
our $VERSION = "2.0.0";

use FindBin;
use lib "$FindBin::Bin/../lib";

use POSIX qw();
use File::Basename;
use File::Path;
use NMISNG::Util;
use Getopt::Long;
use Compat::NMIS;
use NMISNG::Sys;
use Compat::Timing;
use Data::Dumper;
use Excel::Writer::XLSX;
use Term::ReadKey;
use MIME::Entity;
use Cwd 'abs_path';

# this imports the LOCK_ *constants (eg. LOCK_UN, LOCK_EX), also the stat modes
use Fcntl qw(:DEFAULT :flock :mode);
use Errno qw(EAGAIN ESRCH EPERM);

my $PROGNAME    = basename($0);
my $debugsw     = 0;
my $helpsw      = 0;
my $interfacesw = 0;
my $usagesw     = 0;
my $versionsw   = 0;
my $defaultConf = "$FindBin::Bin/../../conf";
my $xlsFile     = "oss_export.xlsx";

$defaultConf = "$FindBin::Bin/../conf" if (! -d $defaultConf);
$defaultConf = abs_path($defaultConf);
print "Default Configuration directory is '$defaultConf'\n";

die unless (GetOptions('debug:i'    => \$debugsw,
                       'help'       => \$helpsw,
                       'interfaces' => \$interfacesw,
                       'usage'      => \$usagesw,
                       'version'    => \$versionsw));

# For the Version mode, just print it and exit.
if (${versionsw}) {
	print "$PROGNAME version=$NMISNG::VERSION\n";
	exit (0);
}
if ($helpsw) {
   help();
   exit(0);
}

my $arg = NMISNG::Util::get_args_multi(@ARGV);

if ($usagesw) {
   usage();
   exit(0);
}

# Set debugging level.
my $debug   = $debugsw;
$debug      = NMISNG::Util::getdebug_cli($arg->{debug}) if (exists($arg->{debug}));   # Backwards compatibility
print "Debug = '$debug'\n" if ($debug);

my $t = Compat::Timing->new();

# Variables for command line munging
my $arg = NMISNG::Util::get_args_multi(@ARGV);

# Set Directory level.
if ( not defined $arg->{dir} ) {
	print "ERROR: The directory argument is required!\n";
	help();
	exit 255;
}
my $dir = abs_path($arg->{dir});

# set a default value and if there is a CLI argument, then use it to set the option
my $email = 0;
if (defined $arg->{email}) {
	if ($arg->{email} =~ /\@/) {
		$email = $arg->{email};
	}
	else {
		print "FATAL: invalid email address '$arg->{email}'.\n";
		exit 255;
	}
}

if (! -d $dir) {
	if (-f $dir) {
		print "ERROR: The directory argument '$dir' points to a file, it must refer to a writable directory!\n";
		help();
		exit 255;
	}
	else {
		my ${key};
		my $IN;
		my $OUT;
		if ($^O =~ /Win32/i)
		{
			sysopen($IN,'CONIN$',O_RDWR);
			sysopen($OUT,'CONOUT$',O_RDWR);
		} else
		{
			open($IN,"</dev/tty");
			open($OUT,">/dev/tty");
		}
		print "Directory '$dir' does not exist!\n\n";
		print "Would you like me to create it? (y/n)  ";
		ReadMode 4, $IN;
		${key} = ReadKey 0, $IN;
		ReadMode 0, $IN;
		print("\r                                \r");
		if (${key} =~ /y/i)
		{
			eval {
				local $SIG{'__DIE__'};  # ignore user-defined die handlers
				mkpath($dir);
			};
			if ($@) {
			    print "FATAL: Error creating dir: $@\n";
				exit 255;
			}
			if (!-d $dir) {
				print "FATAL: Unable to create directory '$dir'.\n";
				exit 255;
			}
			if (-d $dir) {
				print "Directory '$dir' created successfully.\n";
			}
		}
		else {
			print "FATAL: Specify an existing directory with write permission.\n";
			exit 0;
		}
	}
}
if (! -w $dir) {
	print "FATAL: Unable to write to directory '$dir'.\n";
	exit 255;
}

print $t->elapTime(). " Begin\n";

# Set Directory level.
if ( defined $arg->{xls} ) {
	$xlsFile = $arg->{xls};
}
$xlsFile = "$dir/$xlsFile";

if (-f $xlsFile) {
	my ${key};
	my $IN;
	my $OUT;
	if ($^O =~ /Win32/i)
	{
		sysopen($IN,'CONIN$',O_RDWR);
		sysopen($OUT,'CONOUT$',O_RDWR);
	} else
	{
		open($IN,"</dev/tty");
		open($OUT,">/dev/tty");
	}
	print "The Excel file '$xlsFile' already exists!\n\n";
	print "Would you like me to overwrite it and all corresponding CSV files? (y/n) y\b";
	ReadMode 4, $IN;
	${key} = ReadKey 0, $IN;
	ReadMode 0, $IN;
	print("\r                                                                            \r");
	if ((${key} !~ /y/i) && (${key} !~ /\r/) && (${key} !~ /\n/))
	{
		print "FATAL: Not overwriting files.\n";
		exit 255;
	}
}

if ( not defined $arg->{conf}) {
	$arg->{conf} = $defaultConf;
}
else {
	$arg->{conf} = abs_path($arg->{conf});
}

print "Configuration Directory = '$arg->{conf}'\n" if ($debug);
# load configuration table
our $C = NMISNG::Util::loadConfTable(dir=>$arg->{conf}, debug=>$debug);
our $nmisng = Compat::NMIS::new_nmisng();

# Step 1: define your prefered seperator
my $sep = "\t";
if ( $arg->{separator} eq "tab" ) {
	$sep = "\t";
}
elsif ( $arg->{separator} eq "comma" ) {
	$sep = ",";
}
elsif (exists($arg->{separator})) {
	$sep = $arg->{separator};
}

# A cache of Card Indexes.
my $cardIndex;

# Step 2: Define the overall order of all the fields.


my @portHeaders = qw(portName portId portType portStatus parent duplex);

my %portAlias = (
	portName					=> 'Name of the port in the network',
	portId						=> 'Port ID',
	portType					=> 'Type of port',
	portStatus					=> 'Status',
	parent						=> 'parent ID /Card ID',
	duplex						=> 'Duplex full/half',
);

my @vlanHeaders = qw(node parent vtpVlanIndex vtpVlanName vtpVlanType location);

my %vlanAlias = (
	node						=> 'Node Name',
	parent						=> 'Parent',
	vtpVlanIndex				=> 'VLAN ID',
	vtpVlanName					=> 'VLAN Name',
	vtpVlanType					=> 'VLAN Type',
	location					=> 'Location',
);


my @vrfHeaders = qw(node parent vrfLrType mplsVpnVrfName location vrfRoleInVpn ifDescr vrfRefVpnName);

my %vrfAlias = (
	node						=> 'Node Name',
	parent						=> 'Node ID',
	vrfLrType					=> 'LR Type',
	mplsVpnVrfName				=> 'VRF Name',
	location					=> 'Location',
	vrfRoleInVpn				=> 'Role in VPN',
	#mplsVpnVrfDescription		=> 'VRF Description',
	ifDescr						=> 'Ref Assigned Interface',
	vrfRefVpnName				=> 'Ref VPN Name',
);


# Step 5: For loading only the local nodes on a Master or a Slave
my $NODES = Compat::NMIS::loadLocalNodeTable();

#What vendors are we going to process
my $goodVendors = qr/Cisco/;

#What models are we going to process
my $goodModels = qr/CiscoDSL/;

#What devices need to get Max message size updated
my $fixMaxMsgSize = qr/cat650.|ciscoWSC65..|cisco61|cisco62|cisco60|cisco76/;

# Step 6: Run the program!

# Step 7: Check the results

nodeCheck();

my $xls;
if ($xlsFile) {
	$xls = start_xlsx(file => $xlsFile);
}

exportVrf($xls,"$dir/oss-vrf.csv");
exportVlan($xls,"$dir/oss-vlan.csv");

exportInventory(xls => $xls, file => "$dir/oss-interfaces-data.csv", title => "Interfaces", section => "interface", model_section => "standard", model_section_top => "interface");
exportInventory(xls => $xls, file => "$dir/oss-mpls-l3-vpn-vrf-data.csv", title => "mplsL3VpnVrf", section => "mplsL3VpnVrf");
exportInventory(xls => $xls, file => "$dir/oss-mpls-l3-vpn-if-conf-data.csv", title => "mplsL3VpnIfConf", section => "mplsL3VpnIfConf");
exportInventory(xls => $xls, file => "$dir/oss-mpls-l3-vpn-vrf-rt-data.csv", title => "mplsL3VpnVrfRT", section => "mplsL3VpnVrfRT");
exportInventory(xls => $xls, file => "$dir/oss-mpls-ldp-entity-data.csv", title => "mplsLdpEntity", section => "mplsLdpEntity");
exportInventory(xls => $xls, file => "$dir/oss-cisco-pseudowire-vc-data.csv", title => "CiscoPseudowireVC", section => "CiscoPseudowireVC");

exportInventory(xls => $xls, file => "$dir/oss-cisco-cbqos-data.csv", title => "Cisco_CBQoS", section => "Cisco_CBQoS");
exportInventory(xls => $xls, file => "$dir/oss-mpls-vpn-vrf-data.csv", title => "mplsVpnVrf", section => "mplsVpnVrf");
exportInventory(xls => $xls, file => "$dir/oss-mpls-vpn-interface-data.csv", title => "mplsVpnInterface", section => "mplsVpnInterface");
exportInventory(xls => $xls, file => "$dir/oss-mpls-vpn-vrf-route-target-data.csv", title => "mplsVpnVrfRouteTarget", section => "mplsVpnVrfRouteTarget");
exportInventory(xls => $xls, file => "$dir/oss-mpls-vpn-ldp-cisco-data.csv", title => "mplsVpnLdpCisco", section => "mplsVpnLdpCisco");

end_xlsx(xls => $xls);
print "XLS saved to $xlsFile\n";

print $t->elapTime(). " End\n";

sub exportVrf {
	my $xls   = shift;
	my $file  = shift;
	my $title = "VRF";
	my $sheet;
	my $currow;
	my $csvData;
	my @colsize;

	print "Creating '$title' sheet\n";

	print "Creating '$file'\n";
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	# print a CSV header
	my @aliases;
	my $currcol=0;
	foreach my $header (@vrfHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($vrfAlias{$header}));
		my $alias = $header;
		$alias = $vrfAlias{$header} if $vrfAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}

	my $header = join($sep,@aliases);
	print CSV "$header\n";
	$csvData .= "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: Internal error, xls is no longer defined.\n";
	}

	foreach my $node (sort keys %{$NODES}) {
		print "DEBUG: '$NODES->{$node}{name}' Active Status is $NODES->{$node}{active}.\n" if ($debug > 1);
		if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			print "DEBUG: System Object: " . Dumper($S) . "\n\n\n" if ($debug > 8);
			print "DEBUG: '$NODES->{$node}{name}' Node Down Status is $catchall_data->{nodedown}.\n" if ($debug);

			my $nodestatus = $catchall_data->{nodestatus};
			$nodestatus = "unreachable" if $catchall_data->{nodedown} eq "true";

			print "DEBUG: '$NODES->{$node}{name}' vendor is '$catchall_data->{nodeVendor}'.\n" if ($debug > 1);

			# move on if this isn't a good one.
			if ($catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as vendor $catchall_data->{nodeVendor} does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %vrf = undef;

			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{mplsVpnInterface} and ref($MDL->{systemHealth}{sys}{mplsVpnInterface}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "mplsVpnInterface", filter => { historic => 0 });
					if (!$result->error)
					{
						%vrf = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no mplsVpnInterface MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $idx (sort keys %vrf) {
					if ( defined $vrf{$idx} ) {
						$vrf{$idx}{node}          = $node;
						$vrf{$idx}{parent}        = $NODES->{$node}{uuid};
						$vrf{$idx}{location}      = $NODES->{$node}{location};
						$vrf{$idx}{vrfLrType}     = "vrf";
						$vrf{$idx}{vrfRoleInVpn}  = "";
						$vrf{$idx}{vrfRefVpnName} = $vrf{$idx}{mplsVpnVrfName};

						my @columns;
						my $currcol=0;
						foreach my $header (@vrfHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($vrfAlias{$header}));
							my $data   = undef;
							if ( defined $vrf{$idx}{$header} ) {
								$data = $vrf{$idx}{$header};
							}
							else {
								$data = "TBD";
							}
							$colLen = ((length($data) > 253 || length($vrfAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
						}
						my $row = join($sep,@columns);
						print CSV "$row\n";
						$csvData .= "$row\n";

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
					}
				}
			}
		}
	}
	my $i=0;
	foreach my $header (@vrfHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
	my $content = "Report for '$title' attached.\n";
	notifyByEmail(email => $email, subject => $title, content => $content, csvName => "$file", csvData => $csvData) if ($email);
}

sub exportVlan {
	my $xls   = shift;
	my $file  = shift;
	my $title = "VLAN";
	my $sheet;
	my $currow;
	my $csvData;
	my @colsize;

	print "Creating '$title' sheet\n";

	print "Creating '$file'\n";
	open(CSV,">$file") or die "Error with CSV File $file: $!\n";

	# print a CSV header
	my @aliases;
	my $currcol=0;
	foreach my $header (@vlanHeaders) {
		my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($vlanAlias{$header}));
		my $alias = $header;
		$alias = $vlanAlias{$header} if $vlanAlias{$header};
		$colsize[$currcol] = $colLen;
		push(@aliases,$alias);
		$currcol++;
	}

	my $header = join($sep,@aliases);
	print CSV "$header\n";
	$csvData .= "$header\n";

	if ($xls) {
		$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
		$currow = 1;								# header is row 0
	}
	else {
		die "ERROR: Internal error, xls is no longer defined.\n";
	}

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			if ($catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as vendor $catchall_data->{nodeVendor} does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %vlan = undef;

			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{vtpVlan} and ref($MDL->{systemHealth}{sys}{vtpVlan}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "vtpVlan", filter => { historic => 0 });
					if (!$result->error)
					{
						%vlan = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no mplsVpnInterface MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}

				foreach my $idx (sort keys %vlan) {
					if ( defined $vlan{$idx} ) {
						$vlan{$idx}{node} = $node;
						$vlan{$idx}{parent} = $NODES->{$node}{uuid};
						$vlan{$idx}{location} = $NODES->{$node}{location};

						my @columns;
						my $currcol=0;
						foreach my $header (@vlanHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($vlanAlias{$header}));
							my $data   = undef;
							if ( defined $vlan{$idx}{$header} ) {
								$data = $vlan{$idx}{$header};
							}
							else {
								$data = "TBD";
							}
							$colLen = ((length($data) > 253 || length($vlanAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
						}
						my $row = join($sep,@columns);
						print CSV "$row\n";
						$csvData .= "$row\n";

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
					}
				}
			}
		}
	}
	my $i=0;
	foreach my $header (@vlanHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
	my $content = "Report for '$title' attached.\n";
	notifyByEmail(email => $email, subject => $title, content => $content, csvName => "$file", csvData => $csvData) if ($email);
}

sub exportInventory {
	my (%args)  = @_;
	my $xls     = $args{xls};
	my $file    = $args{file};
	my $title   = $args{section};
	my $section = $args{section};
	my $found   = 0;
	my $sheet;
	my $currow;
	my $csvData;
	my @colsize;

	$title = $args{title} if defined $args{title};

	die "I must know which section!" if not defined $args{section};

	my $model_section_top = "systemHealth";
	$model_section_top = $args{model_section_top} if defined $args{model_section_top};

	my $model_section = $section;
	$model_section = $args{model_section} if defined $args{model_section};

	print "Exporting model_section_top=$model_section_top model_section=$model_section section=$section\n";

	print "Creating '$title' sheet with section $section\n";


	# declare some vars for filling in later.
	my @invHeaders;
	my %invAlias;

	foreach my $node (sort keys %{$NODES}) {
	  if ( $NODES->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;
			my $MDL           = $S->mdl;

			# move on if this isn't a good one.
			if ($catchall_data->{nodeVendor} !~ /$goodVendors/) {
				print "DEBUG: Ignoring system '$NODES->{$node}{name}' as vendor $catchall_data->{nodeVendor} does not qualify.\n" if ($debug);
				next;
			}

			# handling for this is device/model specific.
			my %concept = undef;

			if ( $catchall_data->{nodeModel} =~ /$goodModels/ or $catchall_data->{nodeVendor} =~ /$goodVendors/ ) {
				if ( defined $MDL->{systemHealth}{sys}{$section} and ref($MDL->{systemHealth}{sys}{$section}) eq "HASH") {
					my $result = $S->nmisng_node->get_inventory_model( concept => "$section", filter => { historic => 0 });
					if (!$result->error)
					{
						%concept = map { ($_->{data}->{index} => $_->{data}) } (@{$result->data});
					}
				}
				else {
					print "ERROR: $node no $section MIB Data available, check the model contains it and run an update on the node.\n" if $debug > 1;
					next;
				}
				$found = 1;

				# we know the device supports this inventory section, so on the first run of a node, setup the headers based on the model.
				if ( not @invHeaders ) {
					# create the aliases from the model data, a few static items are primed
					#print "DEBUG: $model_section_top $model_section $MDL->{$model_section_top}{sys}{$model_section}{headers}\n";
					#print Dumper $MDL;
					@invHeaders = ('node','parent','location', split(",",$MDL->{$model_section_top}{sys}{$model_section}{headers}));

					# set the aliases for the static items
					%invAlias = (
						node			=> 'Node Name',
						parent			=> 'Parent',
						location		=> 'Location'
					);

					# fill in the aliases for each of the items from the model
					foreach my $heading (@invHeaders) {
						if ( defined $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title} ) {
							$invAlias{$heading} = $MDL->{$model_section_top}{sys}{$model_section}{snmp}{$heading}{title};
						}
						else {
							$invAlias{$heading} = $heading;
						}
					}

					# create a header
					my @aliases;
					my $currcol=0;
					foreach my $header (@invHeaders) {
						my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($invAlias{$header}));
						my $alias = $header;
						$alias = $invAlias{$header} if $invAlias{$header};
						$colsize[$currcol] = $colLen;
						push(@aliases,ucfirst($alias));
						$currcol++;
					}

					if ($file) {
						print "Creating $file\n";
						open(CSV,">$file") or die "Error with CSV File $file: $!\n";
						# print a CSV header
						my $header = join($sep,@aliases);
						print CSV "$header\n";
						$csvData .= "$header\n";
					}
					if ($xls) {
						$sheet = add_worksheet(xls => $xls, title => $title, columns => \@aliases);
						$currow = 1;								# header is row 0
					}
					else {
						die "ERROR: Internal error, xls is no longer defined.\n";
					}
				}


				foreach my $idx (sort keys %concept) {
					if ( defined $concept{$idx} ) {
						$concept{$idx}{node}     = $node;
						$concept{$idx}{parent}   = $NODES->{$node}{uuid};
						$concept{$idx}{location} = $NODES->{$node}{location};

						my @columns;
						my $currcol=0;
						foreach my $header (@invHeaders) {
							my $colLen = (($colsize[$currcol] ne '' ) ? $colsize[$currcol] : length($invAlias{$header}));
							my $data   = undef;
							if ( defined $concept{$idx}{$header} ) {
								$data = $concept{$idx}{$header};
							}
							else {
								$data = "TBD";
							}
							$data = "N/A" if $data eq "noSuchInstance";
							$colLen = ((length($data) > 253 || length($invAlias{$header}) > 253) ? 253 : ((length($data) > $colLen) ? length($data) : $colLen));
							$data   = changeCellSep($data);
							$colsize[$currcol] = $colLen;
							push(@columns,$data);
							$currcol++;
						}
						my $row = join($sep,@columns);
						print CSV "$row\n";
						$csvData .= "$row\n";

						if ($sheet) {
							$sheet->write($currow, 0, [ @columns[0..$#columns] ]);
							++$currow;
						}
					}
				}
			}
		}
	}
	my $i=0;
	foreach my $header (@invHeaders) {
		$sheet->set_column( $i, $i, $colsize[$i]+2);
		$i++;
	}

	close CSV;
	if ($found && $email) {
		my $content = "Report for '$title' attached.\n";
		notifyByEmail(email => $email, subject => $title, content => $content, csvName => "$file", csvData => $csvData);
	}
}

sub changeCellSep {
	my $string = shift;
	$string =~ s/$sep/;/g;
	$string =~ s/\r\n/\\n/g;
	$string =~ s/\n/\\n/g;
	return $string;
}

sub getStatus {
	# no definitions found?
	return "Installed";
}

sub getModel {
	my $sysObjectName = shift;

	$sysObjectName =~ s/cisco/Cisco /g;
	if ( $sysObjectName =~ /cat(\d+)/ ) {
		$sysObjectName = "Cisco Catalyst $1";
	}

	return $sysObjectName;
}

sub getType {
	my $sysObjectName = shift;
	my $nodeType = shift;
	my $type = "TBD";

	if ( $sysObjectName =~ /cisco61|cisco62|cisco60|asam/ ) {
		$type = "DSLAM";
	}
	elsif ( $nodeType =~ /router/ ) {
		$type = "Router";
	}
	elsif ( $nodeType =~ /switch/ ) {
		$type = "Switch";
	}

	return $type;
}

sub getPortDuplex {
	my $thing = shift;
	my $duplex = "TBD";

	if ( $thing =~ /SHDSL|ADSL/ ) {
		$duplex = "N/A";
	}

	return $duplex;
}

sub getCardName {
	my $model = shift;
	my $name;

	if ( $model =~ /^.TUC/ ) {
		$name = "xDSL Card";
	}
	elsif ( $model =~ /^NI\-|C6... Network/ ) {
		$name = "Network Intfc  (WRK)";
	}
	elsif ( $model ne "" ) {
		$name = $model;
	}

	return $name;
}

sub usage {
	print <<EO_TEXT;
Usage: $PROGNAME -d[=[0-9]] -h -u -v dir=<directory> [option=value...]

$PROGNAME will export nodes and ports from NMIS.

Arguments:
 conf=<Configuration file> (default: '$defaultConf');
 dir=<Drectory where files should be saved>
 email=<Email Address>
 separator=<Comma separated  value (CSV) separator character (default: tab)
 xls=<Excel filename> (default: '$xlsFile')

Enter $PROGNAME -h for compleate details.

eg: $PROGNAME dir=/data separator=(comma|tab)
\n
EO_TEXT
}


#Cisco IOS XR Software (Cisco CRS-8/S) Version 5.1.3[Default] Copyright (c) 2014 by Cisco Systems Inc.
sub getVersion {
	my $sysDescr = shift;
	my $version;

	if ( $sysDescr =~ /Version ([\d\.\[\]\w]+)/ ) {
		$version = $1;
	}

	return $version;
}

sub start_xlsx
{
	my (%args) = @_;

	my ($xls);
	if ($args{file})
	{
		$xls = Excel::Writer::XLSX->new($args{file});
		$xls->set_optimization();
		die "Cannot create XLSX file ".$args{file}.": $!\n" if (!$xls);
	}
	else {
		die "ERROR: need a file to work on.\n";
	}
	return ($xls);
}

sub add_worksheet
{
	my (%args) = @_;

	my $xls = $args{xls};

	my $sheet;
	if ($xls)
	{
		my $shorttitle = $args{title};
		$shorttitle =~ s/[^a-zA-Z0-9 _\.-]+//g; # remove forbidden characters
		$shorttitle = substr($shorttitle, 0, 31); # xlsx cannot do sheet titles > 31 chars
		$sheet = $xls->add_worksheet($shorttitle);

		if (ref($args{columns}) eq "ARRAY")
		{
			my $format = $xls->add_format();
			$format->set_bold(); $format->set_color('blue');

			for my $col (0..$#{$args{columns}})
			{
				$sheet->write(0, $col, $args{columns}->[$col], $format);
			}
		}
	}
	return ($xls, $sheet);
}

# closes the spreadsheet, returns 1 if ok.
sub end_xlsx
{
	my (%args) = @_;

	my $xls = $args{xls};

	if ($xls)
	{
		return $xls->close;
	}
	else {
		die "ERROR need an xls to work on.\n";
	}
	return 1;
}

sub nodeCheck {

	my $LNT = Compat::NMIS::loadLocalNodeTable();
	print "Running nodeCheck for nodes, model use, snmp max_msg_size and update\n";
	my %updateList;

	foreach my $node (sort keys %{$LNT}) {
		#print "Processing $node\n";
		if ( $LNT->{$node}{active} ) {
			my $S = NMISNG::Sys->new; # get system object
			$S->init(name=>$node,snmp=>'false'); # load node info and Model if name exists
			my $nodeobj       = $nmisng->node(name => $node);
			my $inv           = $S->inventory( concept => 'catchall' );
			my $catchall_data = $inv->data;

			if ( $catchall_data->{lastUpdatePoll} < time() - 86400 ) {
				$updateList{$node} = $catchall_data->{lastUpdatePoll};
			}


			if ( $LNT->{$node}{model} ne "automatic" ) {
				print "WARNING: $node model not automatic; $LNT->{$node}{model} $catchall_data->{sysDescr}\n";
			}

			#print "updateMaxSnmpMsgSize $node $catchall_data->{sysObjectName}\n";


			if ( $catchall_data->{sysObjectName} =~ /$fixMaxMsgSize/ and $LNT->{$node}{max_msg_size} != 2800) {
				print "$node Updating Max SNMP Message Size\n";
				$LNT->{$node}{max_msg_size} = 2800;
			}
		}
	}

	print "Nodes requiring update:\n";
	foreach my $node (sort keys %updateList) {
		print "$node ". NMISNG::Util::returnDateStamp($updateList{$node}) ."\n";
	}

	NMISNG::Util::writeTable(dir => 'conf', name => "Nodes", data => $LNT);
}

sub notifyByEmail {
	my %args = @_;

	my $email = $args{email};
	my $subject = $args{subject};
	my $content = $args{content};
	my $csvName = $args{csvName};
	my $csvData = $args{csvData};

	if ($content && $email) {

		print "Sending email with '$csvName' to '$email'\n" if $debug;

		my $entity = MIME::Entity->build(
			From=>$C->{mail_from}, 
			To=>$email,
			Subject=> $subject,
			Type=>"multipart/mixed"
		);

		# pad with a couple of blank lines
		$content .= "\n\n";

		$entity->attach(
			Data => $content,
			Disposition => "inline",
			Type  => "text/plain"
		);
										
		if ( $csvData ) {
			$entity->attach(
				Data => $csvData,
				Disposition => "attachment",
				Filename => $csvName,
				Type => "text/csv"
			);
		}

		my ($status, $code, $errmsg) = NMISNG::Notify::sendEmail(
			# params for connection and sending 
			sender => $C->{mail_from},
			recipients => [$email],
		
			mailserver => $C->{mail_server},
			serverport => $C->{mail_server_port},
			hello => $C->{mail_domain},
			usetls => $C->{mail_use_tls},
			ipproto =>  $C->{mail_server_ipproto},
								
			username => $C->{mail_user},
			password => $C->{mail_password},
		
			# and params for making the message on the go
			to => $email,
			from => $C->{mail_from},
		
			subject => $subject,
			mime => $entity,
			priority => "Normal",
		
			debug => $C->{debug}
		);
		
		if (!$status)
		{
			print "Error: Sending email to '$email' failed: $code $errmsg\n";
		}
		else
		{
			print "Email to '$email' sent successfully\n";
		}
	}
} 


###########################################################################
#  Help Function
###########################################################################
sub help
{
   my(${currRow}) = @_;
   my @{lines};
   my ${workLine};
   my ${line};
   my ${key};
   my ${cols};
   my ${rows};
   my ${pixW};
   my ${pixH};
   my ${i};
   my $IN;
   my $OUT;

   if ((-t STDERR) && (-t STDOUT)) {
      if (${currRow} == "")
      {
         ${currRow} = 0;
      }
      if ($^O =~ /Win32/i)
      {
         sysopen($IN,'CONIN$',O_RDWR);
         sysopen($OUT,'CONOUT$',O_RDWR);
      } else
      {
         open($IN,"</dev/tty");
         open($OUT,">/dev/tty");
      }
      ($cols, $rows, $pixW, $pixH) = Term::ReadKey::GetTerminalSize $OUT;
   }
   STDOUT->autoflush(1);
   STDERR->autoflush(1);

   push(@lines, "\n\033[1mNAME\033[0m\n");
   push(@lines, "       $PROGNAME -  Exports nodes and ports from NMIS into an Excel spredsheet.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mSYNOPSIS\033[0m\n");
   push(@lines, "       $PROGNAME [options...] dir=<directory> [option=value] ...\n");
   push(@lines, "\n");
   push(@lines, "\033[1mDESCRIPTION\033[0m\n");
   push(@lines, "       The $PROGNAME program Exports NMIS nodes into an Excel spreadsheet in\n");
   push(@lines, "       the specified directory with the required 'dir' parameter. The command\n" );
   push(@lines, "       also creates Comma Separated Value (CSV) files in the same directory.\n");
   push(@lines, "       If the '--interfaces' option is specified, Interfaces will be\n");
   push(@lines, "       exported as well.  They are not included by default because there may\n");
   push(@lines, "       thousands of them on some devices.\n");
   push(@lines, "\n");
   push(@lines, "\033[1mOPTIONS\033[0m\n");
   push(@lines, " --debug=[1-9]            - global option to print detailed messages\n");
   push(@lines, " --help                   - display command line usage\n");
   push(@lines, " --usage                  - display a brief overview of command syntax\n");
   push(@lines, " --version                - print a version message and exit\n");
   push(@lines, "\n");
   push(@lines, "\033[1mARGUMENTS\033[0m\n");
   push(@lines, "     dir=<directory>         - The directory where the files should be stored.\n");
   push(@lines, "                                Both the Excel spreadsheet and the CSV files\n");
   push(@lines, "                                will be stored in this directory. The\n");
   push(@lines, "                                directory should exist and be writable.\n");
   push(@lines, "     [conf=<filename>]       - The location of an alternate configuration file.\n");
   push(@lines, "                                (default: '$defaultConf')\n");
   push(@lines, "     [debug=<true|false|yes|no|info|warn|error|fatal|verbose|0-9>]\n");
   push(@lines, "                             - Set the debug level.\n");
   push(@lines, "     [email=<email_address>] - Send all generated CSV files to the specified.\n");
   push(@lines, "                                 email address.\n");
   push(@lines, "     [separator=<character>] - A character to be used as the separator in the\n");
   push(@lines, "                                 CSV files. The words 'comma' and 'tab' are\n");
   push(@lines, "                                 understood. Other characters will be taken\n");
   push(@lines, "                                 literally. (default: 'tab')\n");
   push(@lines, "     [xls=<filename>]        - The name of the XLS file to be created in the\n");
   push(@lines, "                                 directory specified using the 'dir' parameter'.\n");
   push(@lines, "                                 (default: '$xlsFile')\n");
   push(@lines, "\n");
   push(@lines, "\033[1mEXIT STATUS\033[0m\n");
   push(@lines, "     The following exit values are returned:\n");
   push(@lines, "     0 Success\n");
   push(@lines, "     215 Failure\n\n");
   push(@lines, "\033[1mEXAMPLE\033[0m\n");
   push(@lines, "   $PROGNAME dir=/tmp separator=comma\n");
   push(@lines, "\n");
   push(@lines, "\n");
   print(STDERR "                       $PROGNAME - ${VERSION}\n");
   print(STDERR "\n");
   ${currRow} += 2;
   foreach (@lines)
   {
      if ((-t STDERR) && (-t STDOUT)) {
         ${i} = tr/\n//;  # Count the newlines in this string
         ${currRow} += ${i};
         if (${currRow} >= ${rows})
         {
            print(STDERR "Press any key to continue.");
            ReadMode 4, $IN;
            ${key} = ReadKey 0, $IN;
            ReadMode 0, $IN;
            print(STDERR "\r                          \r");
            if (${key} =~ /q/i)
            {
               print(STDERR "Exiting per user request. \n");
               return;
            }
            if ((${key} =~ /\r/) || (${key} =~ /\n/))
            {
               ${currRow}--;
            } else
            {
               ${currRow} = 1;
            }
         }
      }
      print(STDERR "$_");
   }
}

