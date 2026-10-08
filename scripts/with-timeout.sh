#!/bin/zsh
# Runs a command with a timeout, killing its whole process group (swift test spawns helpers that
# outlive a plain kill).   scripts/with-timeout.sh <seconds> <command> [args...]
exec perl -e '
  my $secs = shift @ARGV;
  my $pid = fork;
  if (!$pid) { setpgrp(0, 0); exec @ARGV or die "exec: $!" }
  $SIG{ALRM} = sub { kill "KILL", -$pid; print STDERR "timed out after ${secs}s\n"; exit 124 };
  alarm $secs;
  waitpid($pid, 0);
  exit($? >> 8);
' "$@"
