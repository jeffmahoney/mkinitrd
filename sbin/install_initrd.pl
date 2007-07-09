#!/usr/bin/perl
#
# Install initrd scripts
#

use strict 'refs';

my @scripts_boot = ();
my @scripts_setup = ();
my %level_boot = ();
my %level_setup = ();
my %depends_boot = ();
my %depends_setup = ();
my %providedby_boot = ();
my %providedby_setup = ();

sub resolve_dependency
{
    my $section = shift(@_);
    my $name = shift(@_);
    my $oldlevel;

    if ( $section eq "setup" ) {
	$level = \%level_setup;
	$depends = \%depends_setup;
	$providedby= \%providedby_setup;
    } else {
	$level = \%level_boot;
	$depends = \%depends_boot;
	$providedby= \%providedby_boot;
    }
    $oldlevel = $$level{$name};

    foreach $elem (split(' ',$$depends{$name})) {
	my $newlevel = -1;

	foreach $n (split(' ',$$providedby{$elem})) {
	    $newlevel = resolve_dependency($section, $n);
	    if ( $oldlevel <= $newlevel) {
		$oldlevel = $newlevel + 1;
	    }
	}

	if ($newlevel == -1) {
	    print "Unresolved dependency \"$elem\" ";
	}
    }
    print "$name ($oldlevel) ";
    $$level{$name} = $oldlevel;

    return $oldlevel;
}

sub scan_section
{
    my @scripts = @_;
    my @scrlist = ();
    my $depends;
    my $level;
    my $providedby;

    SCAN: foreach $_ (@scripts) {
	my $provides;

	if (/(.*)-(.*)\.sh$/) {
	    if (($1 ne "setup" ) && ($1 ne "boot")) {
		next SCAN;
	    }
	    $section = $1;
	    $scriptname = $2;
	} else {
	    next SCAN;
	}

	if ( $section eq "setup" ) {
	    $level = \%level_setup;
	    $depends = \%depends_setup;
	    $providedby= \%providedby_setup;
	    $scrlist = \@scripts_setup;
	} else {
	    $level = \%level_boot;
	    $depends = \%depends_boot;
	    $providedby= \%providedby_boot;
	    $scrlist = \@scripts_boot;
	}

	print "scanning script $_ (name $scriptname)\n";
	printf "\tsection: %s\n", $section;
	$provides = $scriptname;

	open(SCR, "$scriptdir/$_");

	while (<SCR>) {
	    chomp;
	    if ( /^\#%stage: (.*)/ ) {
		if (!defined ($stages{$1})) {
		    printf "%s: Invalid stage \"%s\"\n", $scriptname, $1;
		    close(SCR);
		    next SCAN;
		}
		if ($section eq "setup") {
		    $$level{$scriptname} = ($stages{$1} * 10) + 1;
		} else {
		    $$level{$scriptname} = 91 - ($stages{$1} * 10);
		}
		printf "\tstage %s: %d\n", $1, $$level{$scriptname};
	    }
	    if ( /^\#%depends: (.*)/ ) {
		printf "\tdepends on %s\n", $1;
		$$depends{$scriptname} = $1;
	    }
	    if ( /\#%provides: (.*)/ ) {
		$provides = join(' ',$provides,$1);
	    }

	}
	close SCR;

	@$scrlist = (@$scrlist,$scriptname);

	printf "\tprovides %s\n", $provides;
	foreach $elem (split(' ',$provides)) {
	    $$providedby{$elem} = join(' ', $$providedby{$elem},$scriptname);
	}
    }
}

$offset=1;
$installdir="lib/mkinitrd";
$scriptdir="scripts";

$stagefile = "$installdir/stages";
open(STAGE, $stagefile) or die "Can't open $stagefile";

# Generate levels
$level=0;
while(<STAGE>) {
    chomp;
    next if ( /\#.*/ );
    my ($name,$comment) = split / /;
    next if $name eq "";
    $stages{$name} = $level;
    printf "Found stage %s: %d\n", $name, $stages{$name} ;
    $level++;
}
close(STAGE);

opendir(DIR, $scriptdir);
@scripts = grep { /.*\.sh$/ && -f "$scriptdir/$_" } readdir(DIR);
closedir DIR;

# Scan scripts
scan_section(@scripts);

# Resolve dependencies
foreach $scr (@scripts_setup) {
    resolve_dependency("section", $scr);
    print "\n";
}

foreach $scr (@scripts_boot) {
    resolve_dependency("boot", $scr);
    print "\n";
}

# Print result
foreach $name (@scripts_setup) {
    my $level = \%level_setup;
    my $lvl = $$level{$name};

    printf "setup/%02d-$name.sh\n", $lvl, $name;
}

foreach $name (@scripts_boot) {
    my $level = \%level_boot;
    my $lvl = $$level{$name};

    printf "boot/%02d-$name.sh\n", $lvl, $name;
}

