#!/usr/bin/perl -w

# This file is part of Product Opener.
#
# Product Opener
# Copyright (C) 2011-2024 Association Open Food Facts
# Contact: contact@openfoodfacts.org
# Address: 21 rue des Iles, 94100 Saint-Maur des Fossés, France
#
# Product Opener is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

# This script is meant to be called through process_new_image_off.sh, itself run through an icrontab

use ProductOpener::PerlStandards

binmode(STDOUT, ":encoding(UTF-8)");

use ProductOpener::Config qw/:all/;
use ProductOpener::Redis qw/:all/;

use Log::Any qw($log);
use Log::Log4perl;
Log::Log4perl->init("$conf_root/log.conf");    # Init log4perl from a config file.
use Log::Any::Adapter;
Log::Any::Adapter->set('Log4perl');    # Send all logs to Log::Log4perl

use AnyEvent;
use EV;

sub run ($cv) {
	subscribe_to_redis_streams($cv);

	# call event loop
	EV::run();
	return;
}

sub main() {
	print STDOUT "Starting listen_to_redis_stream.pl\n";

	my $cv = AE::cv;

	# signal handler for TERM, KILL, QUIT
	foreach my $sig (qw/TERM KILL QUIT/) {
		EV::signal $sig, sub {
			print "Exiting after receiving $sig\n";
			$cv->send;
			exit(0);
		};
	}

	run($cv);
	$cv->recv; # Wait for the event loop to finish
	return;
}

main();
