#!/usr/bin/perl

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
use File::Path qw(remove_tree);
use Getopt::Std;
use POSIX;
use Time::HiRes;

my %opts;
getopts('e:t:v', \%opts) or do {
    print STDERR "usage: $0 [-v] [-e environment] [-t timeout]\n";
    exit(2);
};
my $timeout = $opts{t} || 60*60;
environment($opts{e}) if $opts{e};

my $dir = dirname($0);
chdir($dir)
    or die "Chdir to '$dir' failed: $!";
my $performdir = getcwd();

# write summary of results into result file
open(my $tr, '>', "test.result")
    or die "Open 'test.result' for writing failed: $!";
$tr->autoflush();
$| = 1;

my $logdir = "$performdir/logs";
remove_tree($logdir);
mkdir $logdir
    or die "Make directory '$logdir' failed: $!";
chdir($logdir)
    or die "Chdir to '$logdir' failed: $!";

sub bad($$$;$) {
    my ($test, $reason, $message) = @_;
    print "\n$reason\t$test\t$message\n\n" if $opts{v};
    print $tr "$reason\t$test\t$message\n";
    $tr->sync();
    die "XXX";
}

sub good($$;$) {
    my ($test, $diff) = @_;
    my $duration = sprintf("%dm%02d.%02ds", $diff/60, $diff%60, 100*$diff%100);
    print "\nPASS\t$test\tDuration $duration\n\n" if $opts{v};
    print $tr "PASS\t$test\tDuration $duration\n";
    $tr->sync();
}

my $remote_addr = $ENV{REMOTE_ADDR}
    or die "Environemnt REMOTE_ADDR not set";
my $remote_ssh = $ENV{REMOTE_SSH}
    or die "Environemnt REMOTE_SSH not set";

my $test = "iperf3";
my $begin = Time::HiRes::time();
my $date = strftime("%FT%TZ", gmtime($begin));
print "\nSTART\t$test\t$date\n\n" if $opts{v};

$dir = $test;
-d $dir || mkdir $dir
    or die "Make directory '$dir' failed: $!";
chdir($dir)
    or die "Chdir to '$dir' failed: $!";

my @sshcmd = ('ssh', $remote_ssh, 'pkill', 'iperf3');
system(@sshcmd);
@sshcmd = ('ssh', $remote_ssh, 'iperf3', '-s', '-D');
system(@sshcmd)
    and die "Start iperf3 server with '@sshcmd' failed: $?";

my @runcmd = ('iperf3', "-c$remote_addr", '-w1m');
my $logfile = join("", @runcmd);
push @runcmd, '--logfile', $logfile;

defined(my $pid = open(my $out, '-|'))
    or bad $test, 'NORUN', "Open pipe from '@runcmd' failed: $!";
if ($pid == 0) {
    close($out);
    open(STDIN, '<', "/dev/null")
	or warn "Redirect stdin to /dev/null failed: $!";
    open(STDERR, '>&', \*STDOUT)
	or warn "Redirect stderr to stdout failed: $!";
    setsid()
	or warn "Setsid $$ failed: $!";
    exec(@runcmd);
    warn "Exec '@runcmd' failed: $!";
    _exit(126);
}
eval {
    local $SIG{ALRM} = sub { die "Test running too long, aborted\n" };
    alarm($timeout);
    while (<$out>) {
	s/[^\s[:print:]]/_/g;
	print if $opts{v};
    }
    alarm(0);
};
kill 'KILL', -$pid;
if ($@) {
    chomp($@);
    bad $test, 'NOTERM', $@
}
close($out)
    or bad $test, 'NOEXIT', $! ?
    "Close pipe from '@runcmd' failed: $!" :
    "Command '@runcmd' failed: $?";

my $end = Time::HiRes::time();
good $test, $end - $begin;

chdir($performdir)
    or die "Chdir to '$performdir' failed: $!";

# create a tgz file with all log files
my @paxcmd = ('pax', '-x', 'cpio', '-wzf', "$performdir/test.log.tgz");
push @paxcmd, '-v' if $opts{v};
push @paxcmd, ("-s,^$logdir,,", $logdir);
system(@paxcmd)
    and die "Command '@paxcmd' failed: $?";

close($tr)
    or die "Close 'test.result' after writing failed: $!";

exit;

# parse shell script that is setting environment for some tests
# FOO=bar
# FOO="bar"
# export FOO=bar
# export FOO BAR
sub environment {
    my $file = shift;

    open(my $fh, '<', $file)
	or die "Open '$file' for reading failed: $!";
    while (<$fh>) {
	chomp;
	s/#.*$//;
	s/\s+$//;
	s/^export\s+(?=\w+=)//;
	s/^export\s+\w+.*//;
	next if /^$/;
	if (/^(\w+)=(\S+)$/ or /^(\w+)="([^"]*)"/ or /^(\w+)='([^']*)'/) {
	    $ENV{$1}=$2;
	} else {
	    die "Unknown environment line in '$file': $_";
	}
    }
}