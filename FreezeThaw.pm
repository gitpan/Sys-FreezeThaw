=head1 NAME

Sys::FreezeThaw - stop and start all user processes on a machine

=head1 SYNOPSIS

  use Sys::FreezeThaw;

  Sys::FreezeThaw::freezethaw {
     # run code while system is frozen
  };

  my $token = Sys::FreezeThaw::freeze;
  ... do something ...
  Sys::FreezeThaw::thaw $token;
  
=head1 DESCRIPTION

Operating Systems current supported: Linux-2.6.

This module implements a very specific feature: stopping(freezing and
thawing/continuing all user processes on the machine. It works by sending
SIGSTOP to all processes, parent-process first, so that the wait syscall
will not trigger on stopped children. Restarting is done in reverse order.

Using the combined function Sys::FreezeThaw::freezethaw is recommended as
it will catch runtime errors, but stopping and restarting can be dine via
seperate function calls.

=over 4

=cut

package Sys::FreezeThaw;

use Carp;

$VERSION = '0.01';

=item Sys::FreezeThaw::freezethaw { BLOCK }

First tries to stop all processes. If successful, runs the given codeblock
(or code reference), then restarts all processes again. As the system is
basically frozen during the codeblock execution, it should be as fast as
possible.

Runtime errors will be caught with C<eval>. If an exception occurs it will
be re-thrown after processes are restarted. If processes cannot be frozen
or restarted, this function will throw an exception.

Signal handlers for SIGPIPE, SIGHUP, SIGALRM, SIGUSR1 and SIGUSR2 will
temporarily be installed, so if you want to catch these, you have to do so
yourself within the executed codeblock.

Try to do as few things as possible. For example, outputting text might
cause a deadlock, as the terminal emulator on the other side of STDOUT
might be stopped, etc.

The return value of the codeblock is ignored right now, and the function
doesn't yet return anything sensible.

=item $token = Sys::FreezeThaw::freeze;

Send SIGSTOP to all processes, and return a token that allows them to be
thawed again.

If an error occurs, an exception will be thrown and all stopped processes
will automatically be thawed.

=item Sys::FreezeThaw::thaw $token

Take a token returned by Sys::FreezeThaw::freeze and send all processes
a CONT signal, in the order required for them not to receive child STOP
notifications.

=cut

# this is laughably broken, but...
sub yield {
   select undef, undef, undef, 1/1000;
}

# the maximum number of iterations per stop/cont etc. loop
# used to shield against catastrophic events (or bugs :)
# usually only one or two iterations are required per loop
sub MAX_WAIT() { 100 }

# return a list o fall pid's in the system,
# topologically sorted parent-first
# skips, keys %$exclude_pid, zombies and stopped processes
sub enum_pids($) {
   my ($exclude_pid) = @_;

   opendir my $proc, "/proc"
      or die "/proc: $!";
   my @pid = sort { $b <=> $a }
                grep /^\d+/,
                   readdir $proc;
   closedir $proc;

   my %ppid;
   for (@pid) {
      next if exists $exclude_pid->{$_};

      open my $stat, "<", "/proc/$_/stat"
         or next;
      my ($state, $ppid, $vsize, $rss) = (split /\s+/, scalar <$stat>)[2,3,22,23];

      next if $state =~ /^[TZX]/i; # stopped, zombies, dead
      next unless $vsize || $rss; # skip kernel threads or other nasties

      $ppid{$_} = $ppid;
   }

   # now topologically sort by parent-id
   my @res;
   while (scalar %ppid) {
      my @pass;

      for my $pid (keys %ppid) {
         if (!exists $ppid{$ppid{$pid}}) {
            push @pass, $pid;
         }
      }

      delete $ppid{$_} for @pass;

      push @res, \@pass;
   }

   \@res
}

sub process_stopped($) {
   open my $stat, "</proc/$_[0]/stat"
      or return 1;

   return +(split /\s+/, <$stat>)[2] =~ /^[TZX]/i;
}

sub thaw($) {
   local $@;

   my $token = shift;

   for (reverse @$token) {
      my @pids = @$_;
      kill CONT => @pids;

      # now wait till processes actually run again before the next round
      for (1..MAX_WAIT) {
         @pids = grep process_stopped $_, @pids;
         last unless @pids;

         yield;
      }
   }
}

sub freeze() {
   local $@;

   my @procs;

   eval {
      for (1..MAX_WAIT) {
         my $passes = enum_pids { 1 => 1, $$ => 1 };
         last unless @$passes;

         for (@$passes) {
            my @pids = @$_;
            push @procs, $_;
            kill STOP => @pids;

            for (1..MAX_WAIT) {
               @pids = grep !process_stopped $_, @pids;
               last unless @pids;

               # wait till processes are really stopped
               yield;
            }

            die "unable to stop processes <@pids>" if @pids;
         }
      }
   };

   if ($@) {
      thaw \@procs;
      die $@;
   }

   \@procs
}

sub freezethaw(&) {
   my ($code) = @_;

   my $token = freeze;

   eval {
      local $SIG{HUP}  = sub { die "ERROR: caught SIGHUP while system frozen" };
      local $SIG{PIPE} = sub { die "ERROR: caught SIGPIPE while system frozen" };
      local $SIG{ALRM} = sub { die "ERROR: caught SIGALRM while system frozen" };
      local $SIG{USR1} = sub { die "ERROR: caught SIGUSR1 while system frozen" };
      local $SIG{USR2} = sub { die "ERROR: caught SIGUSR2 while system frozen" };

      $code->();
   };

   thaw $token;

   die $@ if $@;

   ()
}

1;

=back

=head1 BUGS

SIGCONT is not unnoticed by processes. Some programs (such as irssi-text)
respond by flickering (IMHO a bug in irssi-text). Other programs might
have other problems, but actual problems should be rare. However, one
shouldn't overuse this module.

=head1 AUTHOR

   Marc Lehmann <schmorp@schmorp.de>
   http://home.schmorp.de/

=cut

