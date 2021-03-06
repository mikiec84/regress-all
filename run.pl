#!/usr/bin/perl

# Copyright (c) 2016-2018 Alexander Bluhm <bluhm@genua.de>
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
use Hostctl;

my $scriptname = "$0 @ARGV";

my %opts;
getopts('h:v', \%opts) or do {
    print STDERR <<"EOF";
usage: $0 [-v] -h host mode ...
    -h host	user and host for make regress, user defaults to root
    -v		verbose
    build	build system from source /usr/src
    cvs		cvs update /usr/src and make obj
    install	install from snapshot
    keep	keep installed host as is, skip setup
    kernel	build kernel from source /usr/src/sys
    upgrade	upgrade with snapshot
EOF
    exit(2);
};
$opts{h} or die "No -h specified";

my %allmodes;
@allmodes{qw(build cvs install keep kernel upgrade)} = ();
@ARGV or die "No mode specified";
my %mode = map {
    die "Unknown mode: $_" unless exists $allmodes{$_};
    $_ => 1;
} @ARGV;
foreach (qw(install keep upgrade)) {
    die "Mode must be used solely: $_" if $mode{$_} && keys %mode != 1;
}

# better get an errno than random kill by SIGPIPE
$SIG{PIPE} = 'IGNORE';

# create directory for this test run with timestamp 2016-07-13T12:30:42Z
my $date = strftime("%FT%TZ", gmtime);

my $regressdir = dirname($0). "/..";
chdir($regressdir)
    or die "Chdir to '$regressdir' failed: $!";
$regressdir = getcwd();
my $resultdir = "$regressdir/results/$date";
mkdir $resultdir
    or die "Make directory '$resultdir' failed: $!";
unlink("results/current");
symlink($date, "results/current")
    or die "Make symlink 'results/current' failed: $!";
chdir($resultdir)
    or die "Chdir to '$resultdir' failed: $!";

createlog(file => "run.log", verbose => $opts{v});
logmsg("script '$scriptname' started at $date\n");

# setup remote machines

usehosts(bindir => "$regressdir/bin", date => $date,
    host => $opts{h}, verbose => $opts{v});

setup_hosts(mode => \%mode) unless $mode{keep};
collect_version();
runcmd("$regressdir/bin/setup-html.pl");

# run regression tests remotely

chdir($resultdir)
    or die "Chdir to '$regressdir' failed: $!";

(my $host = $opts{h}) =~ s/.*\@//;
my @sshcmd = ('ssh', $opts{h}, 'perl', '/root/regress/regress.pl',
    '-e', "/root/regress/env-$host.sh", '-v');
logcmd(@sshcmd);

# get result and logs

my @scpcmd = ('scp');
push @scpcmd, '-q' unless $opts{v};
push @scpcmd, ("$opts{h}:/root/regress/test.*", $resultdir);
runcmd(@scpcmd);

open(my $tr, '<', "test.result")
    or die "Open 'test.result' for reading failed: $!";
my $logdir = "$resultdir/logs";
mkdir $logdir
    or die "Make directory '$logdir' failed: $!";
chdir($logdir)
    or die "Chdir to '$logdir' failed: $!";
my @paxcmd = ('pax', '-rzf', "../test.log.tgz");
open(my $pax, '|-', @paxcmd)
    or die "Open pipe to '@paxcmd' failed: $!";
while (<$tr>) {
    my ($status, $test, $message) = split(" ", $_, 3);
    print $pax "$test/make.log" unless $test =~ m,[^\w/],;
}
close($pax) or die $! ?
    "Close pipe to '@paxcmd' failed: $!" :
    "Command '@paxcmd' failed: $?";
close($tr)
    or die "Close 'test.result' after reading failed: $!";

chdir($resultdir)
    or die "Chdir to '$regressdir' failed: $!";

collect_dmesg();

# create html output

chdir($regressdir)
    or die "Chdir to '$regressdir' failed: $!";

runcmd("bin/setup-html.pl");
runcmd("bin/regress-html.pl", "-h", $host);
runcmd("bin/regress-html.pl");

unlink("results/latest-$host");
symlink($date, "results/latest-$host")
    or die "Make symlink 'results/latest-$host' failed: $!";
unlink("results/latest");
symlink($date, "results/latest")
    or die "Make symlink 'results/latest' failed: $!";
runcmd("bin/regress-html.pl", "-l", "-h", $host);
runcmd("bin/regress-html.pl", "-l");

$date = strftime("%FT%TZ", gmtime);
logmsg("script '$scriptname' finished at $date\n");
