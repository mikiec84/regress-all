#!/usr/bin/perl
# recompile parts of machine for performance comparison

# Copyright (c) 2018 Alexander Bluhm <bluhm@genua.de>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

use strict;
use warnings;
use Cwd;
use File::Basename;
use Getopt::Std;
use POSIX;

use lib dirname($0);
use Logcmd;
use Machine;
use Buildquirks;

my $scriptname = "$0 @ARGV";

my %opts;
getopts('d:D:h:v', \%opts) or do {
    print STDERR <<"EOF";
usage: $0 [-v] [-d date] [-D cvsdate] -h host
    -d date	set date string and change to sub directory
    -D cvsdate	update sources from cvs to this date
    -h host	root\@openbsd-test-machine, login per ssh
    -v		verbose
EOF
    exit(2);
};
$opts{h} or die "No -h specified";
my $date = $opts{d};
my $cvsdate = $opts{D};

my $performdir = dirname($0). "/..";
chdir($performdir)
    or die "Chdir to '$performdir' failed: $!";
$performdir = getcwd();
my $resultdir = "$performdir/results";
$resultdir .= "/$date" if $date;
$resultdir .= "/$cvsdate" if $cvsdate;
chdir($resultdir)
    or die "Chdir to '$resultdir' failed: $!";

my ($user, $host) = split('@', $opts{h}, 2);
($user, $host) = ("root", $user) unless $host;

createlog(file => "cvsbuild-$host.log", verbose => $opts{v});
$date = strftime("%FT%TZ", gmtime);
logmsg("script '$scriptname' started at $date\n");

createhost($user, $host);

my %sysctl = get_version();
my $before;
if ($sysctl{'kern.version'} =~
    /#cvs : D(\d{4}).(\d\d).(\d\d).(\d\d).(\d\d).(\d\d):/) {
    $before = "$1-$2-${3}T$4:$5:${6}Z";
} elsif ($sysctl{'kern.version'} =~
    /: (\w{3} \w{3} \d?\d \d\d:\d\d:\d\d \w+ \d{4})\n/) {
    $before = $1;
}
if ($before) {
    my @comments = quirk_comments($before, $cvsdate);
    if (@comments) {
	open(my $fh, '>', "quirks-$host.txt")
	    or die "Open 'quirks-$host.txt' for writing failed: $!";
	print $fh map { "$_\n" } @comments;
    }
    foreach my $cmd (quirk_commands($before, $cvsdate, \%sysctl)) {
	logcmd('ssh', "$user\@$host", $cmd);
    }
}

update_cvs(undef, $cvsdate, "sys");
make_kernel();
reboot();
get_version();

# finish build log

$date = strftime("%FT%TZ", gmtime);
logmsg("script '$scriptname' finished at $date\n");
