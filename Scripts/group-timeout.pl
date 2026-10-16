#!/usr/bin/perl
# Scripts/group-timeout.pl: perl group-timeout.pl <seconds> <command...>
# Runs the command in a process group of its own. After <seconds>, it stops the whole group (SIGTERM, then SIGKILL
# 5 seconds later), so programs the command started stop too, not just the command. Exits with the command's status
# (128 + the signal if it was killed), or 124 when the time ran out.
# The group is not the terminal's foreground group, so Ctrl-C, a closed terminal or a kill reaches only this guard.
# It stops the whole group the same way on SIGINT, SIGTERM and SIGHUP, then exits with 128 + that signal.
use strict;
use warnings;
use POSIX qw(WNOHANG SIG_BLOCK SIG_SETMASK SIGINT SIGTERM SIGHUP SIGALRM);

my $seconds = shift @ARGV;
die "usage: group-timeout.pl <seconds> <command...>\n" unless defined $seconds && $seconds =~ /^\d+$/ && @ARGV;
my $grace = $ENV{GROUP_TIMEOUT_GRACE} // 5;

# Hold the stop signals until the group exists and the handlers are in place, so none can slip past.
my $held = POSIX::SigSet->new(SIGINT, SIGTERM, SIGHUP, SIGALRM);
my $before = POSIX::SigSet->new;
POSIX::sigprocmask(SIG_BLOCK, $held, $before) or die "sigprocmask: $!\n";

my $pid = fork() // die "fork: $!\n";
if ($pid == 0) {
    setpgrp(0, 0);
    POSIX::sigprocmask(SIG_SETMASK, $before);
    exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n";
}
# Set from both sides, so the group exists before any stop can reach it.
setpgrp($pid, $pid);

my $stopping = 0;

# Stops the whole group: SIGTERM, up to $grace seconds to finish, then SIGKILL. Reaps the command and exits $code.
sub stop_group {
    my ($why, $code) = @_;
    return if $stopping++;
    alarm 0;
    print STDERR "$why, with everything it started.\n";
    kill 'TERM', -$pid;
    my $reaped = 0;
    for (1 .. $grace * 10) {
        $reaped ||= waitpid($pid, WNOHANG) == $pid;
        last unless kill 0, -$pid;
        select(undef, undef, undef, 0.1);
    }
    kill 'KILL', -$pid;
    waitpid($pid, 0) unless $reaped;
    exit $code;
}

$SIG{ALRM} = sub { stop_group("Stopped after $seconds seconds", 124) };
my %numbers = (INT => SIGINT, TERM => SIGTERM, HUP => SIGHUP);
for my $name (keys %numbers) {
    $SIG{$name} = sub { stop_group("Stopped by SIG$name", 128 + $numbers{$name}) };
}
alarm $seconds;
POSIX::sigprocmask(SIG_SETMASK, $before) or die "sigprocmask: $!\n";

waitpid($pid, 0);
my $status = $?;
alarm 0;
exit($status & 127 ? 128 + ($status & 127) : $status >> 8);
