# -*- perl -*-
#
#  Net::Server::PreFork - Net::Server personality
#  
#  $Id$
#  
#  Copyright (C) 2001, Paul T Seamons
#                      paul@seamons.com
#                      http://seamons.com/
#  
#  This package may be distributed under the terms of either the
#  GNU General Public License 
#    or the
#  Perl Artistic License
#
#  All rights reserved.
#  
################################################################

package Net::Server::PreFork;

use strict;
use vars qw($VERSION @ISA $LOCK_EX $LOCK_UN);
use POSIX ();
use Fcntl ();
use Net::Server;

$VERSION = $Net::Server::VERSION; # done until separated

### fall back to parent methods
@ISA = qw(Net::Server);


### override-able options for this package
sub options {
  my $self = shift;
  my $prop = $self->{server};
  my $ref  = shift;

  $self->SUPER::options($ref);

  foreach ( qw(min_servers max_servers spare_servers max_requests max_dequeue
               check_for_dead check_for_waiting check_for_dequeue
               lock_file serialize) ){
    $prop->{$_} = undef unless exists $prop->{$_};
    $ref->{$_} = \$prop->{$_};
  }

}

### make sure some defaults are set
sub post_configure {
  my $self = shift;
  my $prop = $self->{server};

  ### let the parent do the rest
  ### must do this first so that ppid reflects backgrounded process
  $self->SUPER::post_configure;

  ### some default values to check for
  my $d = {min_servers   => 5,      # min num of servers to always have running
           max_servers   => 10,     # max num of servers to run
           spare_servers => 1,      # num of extra servers to have lying around
           max_requests  => 1000,   # num of requests for each child to handle
           check_for_dead    => 30, # how often to see if children are alive
           check_for_waiting => 20, # how often to see if extra children exist
           };
  foreach (keys %$d){
    $prop->{$_} = $d->{$_}
    unless defined($prop->{$_}) && $prop->{$_} =~ /^\d+$/;
  }

  ### I need to know who is the parent
  $prop->{ppid} = $$;

}


### now that we are bound prepare serialization
sub post_bind {
  my $self = shift;
  my $prop = $self->{server};

  ### do the parents
  $self->SUPER::post_bind;

  ### set up serialization
  if( defined($prop->{multi_port}) 
      || defined($prop->{serialize})
      || $^O =~ /solaris/i ){

    ### clean up method to use for serialization
    if( !defined($prop->{serialize}) 
        || $prop->{serialize} !~ /^(flock|semaphore|pipe)$/ ){
      $prop->{serialize} = 'flock';
    }

    ### set up lock file
    if( $prop->{serialize} eq 'flock' ){
      $self->log(3,"Setting up serialization via flock");
      if( defined($prop->{lock_file}) ){
        $prop->{lock_file_unlink} = undef;
      }else{
        $prop->{lock_file} = POSIX::tmpnam();
        $prop->{lock_file_unlink} = 1;
      }

    ### set up semaphore
    }elsif( $prop->{serialize} eq 'semaphore' ){
      $self->log(3,"Setting up serialization via semaphore");
      require "IPC/SysV.pm";
      require "IPC/Semaphore.pm";
      my $s = IPC::Semaphore->new(IPC::SysV::IPC_PRIVATE(),
                                  1,
                                  IPC::SysV::S_IRWXU() | IPC::SysV::IPC_CREAT(),
                                  ) || $self->fatal("Semaphore error [$!]");
      $s->setall(1) || $self->fatal("Semaphore create error [$!]");
      $prop->{sem} = $s;

    ### set up pipe
    }elsif( $prop->{serialize} eq 'pipe' ){
      pipe( _WAITING, _READY );
      _READY->autoflush(1);
      _WAITING->autoflush(1);
      $prop->{_READY}   = *_READY;
      $prop->{_WAITING} = *_WAITING;
      print _READY "First\n";

    }else{
      $self->fatal("Unknown serialization type \"$prop->{serialize}\"");
    }

  }else{
    $prop->{serialize} = '';
  }

}

### prepare for connections
sub loop {
  my $self = shift;
  my $prop = $self->{server};

  ### get ready for child->parent communication
  pipe(_READ,_WRITE);
  $prop->{_READ}  = *_READ;
  $prop->{_WRITE} = *_WRITE;

  ### get ready for children
  $prop->{children} = {};

  $self->log(3,"Beginning prefork ($prop->{min_servers} processes)\n");

  ### start up the children
  $self->run_n_children( $prop->{min_servers} );

  ### finish the parent routines
  $self->run_parent;
  
}

### subroutine to start up a specified number of children
sub run_n_children {
  my $self  = shift;
  my $prop  = $self->{server};
  my $n     = shift;
  my $total = scalar keys %{ $prop->{children} };
  
  ### don't start more than we're allowed
  if( $n > $prop->{max_servers} - $total ){
    $n = $prop->{max_servers} - $total;
  }

  for( 1..$n ){
    my $pid = fork;

    ### trouble
    if( not defined $pid ){
      $self->fatal("Bad fork [$!]");

    ### parent
    }elsif( $pid ){
      $prop->{children}->{$pid} = 'waiting';

    ### child
    }else{
      $self->run_child;

    }
  }
}


### child process which will accept on the port
sub run_child {
  my $self = shift;
  my $prop = $self->{server};

  ### restore sigs (turn off warnings during)
  $SIG{INT} = $SIG{TERM} = $SIG{QUIT} = 'DEFAULT';

  $self->log(4,"Child Preforked ($$)\n");
  delete $prop->{children};

  $self->child_init_hook;

  ### tell the parent that we are waiting
  *_WRITE = $prop->{_WRITE};
  _WRITE->autoflush(1);
  print _WRITE "$$ waiting\n";

  ### let the parent shut me down
  $prop->{connected} = 0;
  $prop->{SigHUPed}  = 0;
  $SIG{HUP} = sub {
    unless( $prop->{connected} ){
      print _WRITE "$$ exiting\n";
      exit;
    }
    $prop->{SigHUPed} = 1;
  };

  ### accept connections
  while( $self->accept() ){
    
    $prop->{connected} = 1;
    print _WRITE "$$ processing\n";

    $self->run_client_connection;

    last if $self->done;

    $prop->{connected} = 0;
    print _WRITE "$$ waiting\n";

  }
  
  $self->child_finish_hook;

  print _WRITE "$$ exiting\n";
  exit;

}


### hooks at the beginning and end of forked child processes
sub child_init_hook {}
sub child_finish_hook {}


### We can only let one process do the selecting at a time
### this override makes sure that nobody else can do it
### while we are.  We do this either by opening a lock file
### and getting an exclusive lock (this will block all others
### until we release it) or by using semaphores to block
sub accept {
  my $self = shift;
  my $prop = $self->{server};

  local *LOCK;

  ### serialize the child accepts
  if( $prop->{serialize} eq 'flock' ){
    open(LOCK,">$prop->{lock_file}")
      || $self->fatal("Couldn't open lock file \"$prop->{lock_file}\" [$!]");
    flock(LOCK,Fcntl::LOCK_EX())
      || $self->fatal("Couldn't get lock on file \"$prop->{lock_file}\" [$!]");

  }elsif( $prop->{serialize} eq 'semaphore' ){
    $prop->{sem}->op( 0, -1, IPC::SysV::SEM_UNDO() )
      || $self->fatal("Semaphore Error [$!]");

  }elsif( $prop->{serialize} eq 'pipe' ){
    scalar <_WAITING>; # read one line - kernel says who gets it
  }


  ### now do the accept method
  my $accept_val = $self->SUPER::accept();


  ### unblock serialization
  if( $prop->{serialize} eq 'flock' ){
    flock(LOCK,Fcntl::LOCK_UN());

  }elsif( $prop->{serialize} eq 'semaphore' ){
    $prop->{sem}->op( 0, 1, IPC::SysV::SEM_UNDO() )
      || $self->fatal("Semaphore Error [$!]");

  }elsif( $prop->{serialize} eq 'pipe' ){
    print _READY "Next!\n";
  }

  ### return our success
  return $accept_val;

}


### is the looping done (non zero value says its done)
sub done {
  my $self = shift;
  my $prop = $self->{server};
  return 1 if $prop->{requests} >= $prop->{max_requests};
  return 1 if $prop->{SigHUPed};
  if( ! kill(0,$prop->{ppid}) ){
    $self->log(3,"Parent process gone away. Shutting down");
    return 1;
  }
}


### now the parent will wait for the kids
sub run_parent {
  my $self=shift;
  my $prop = $self->{server};

  $self->log(4,"Parent ready for children\n");

  ### prepare to read from children
  local *_READ = $prop->{_READ};
  _READ->autoflush(1);

  ### allow for writing to _READ
  local *_WRITE = $prop->{_WRITE};
  _WRITE->autoflush(1);

  ### set some waypoints
  $prop->{last_checked_for_dead}
  = $prop->{last_checked_for_waiting}
  = $prop->{last_checked_for_dequeue}
  = time();

  ### find the lowest positive time interval
  my $alarm = (sort {$a <=> $b}
               grep {defined($_) && $_>0} 
               ($prop->{check_for_dead},
                $prop->{check_for_waiting},
                $prop->{check_for_dequeue},
                ))[0];
  
  ### catch an alarm or a restart signal
  ### do as little as possible here, work is done below
  $SIG{ALRM} = sub{ $self->{sig} ||= 'alrm'; print _WRITE "$$ alrm\n"; };
  $SIG{HUP}  = sub{ $self->{sig}   =  'hup'; print _WRITE "$$ hup\n";  };

  ### loop on reading info from the children
  alarm($alarm);
  while( <_READ> ){
    alarm(0);
    
    next if not defined $_;

    ### optional test by user hook
    last if $self->parent_read_hook($_);

    ### child should say "$pid waiting\n"
    next unless /^(\d+)\ +(.+)$/;
    my ($pid,$status) = ($1,$2);

    ### allow for parent to get a word in edgewise
    if( $pid == $$ || defined $self->{sig} ){
      my $sig = delete($self->{sig}) || '';
      if( $status eq 'alrm' ){
        $self->coordinate_children();
        alarm($alarm);
        next;
      }
      if( $status eq 'hup' || $sig eq 'hup' ){
        $self->sig_hup();
        _READ->close();
        last;
      }
    }

    ### record the status
    if( $status eq 'exiting' ){
      delete($prop->{children}->{$pid});
    }else{
      $prop->{children}->{$pid} = $status;
    }
    
    ### check up on the children
    if( $status eq 'processing' || $status eq 'exiting' ){
      $self->coordinate_children();
    }

    alarm($alarm);
  }

  ### allow fall back to main run method
}


### allow for other process to tie in to the parent read
sub parent_read_hook {}

### routine to determine if more children need to be started or stopped
sub coordinate_children {
  my $self = shift;
  my $prop = $self->{server};
  my $time = time();

  ### periodically make sure children are alive
  if( $time - $prop->{last_checked_for_dead} > $prop->{check_for_dead} ){
    $prop->{last_checked_for_dead} = $time;
    foreach (keys %{ $prop->{children} }){
      ### see if the child can be killed
      kill(0,$_) or delete $prop->{children}->{$_};
    }
  }

  ### tally the possible types
  my %num = (waiting=>0, processing=>0, dequeue=>0);
  $num{$_} ++ foreach (values %{ $prop->{children} });
  my $total = $num{waiting} + $num{processing};
  
  ### periodically check to see if we should clear the queue
  if( defined $prop->{check_for_dequeue} ){
    if( $time - $prop->{last_checked_for_dequeue} > $prop->{check_for_dequeue} ){
      $prop->{last_checked_for_dequeue} = $time;
      if( defined($prop->{max_dequeue})
          && $num{dequeue} < $prop->{max_dequeue} ){
        $self->run_dequeue();
      }
    }
  }

  ### need more min_servers
  if( $total < $prop->{min_servers} ){
    $self->run_n_children( $prop->{min_servers} - $total );
    
  ### need more spare_servers
  }elsif( $num{waiting} < $prop->{spare_servers} 
          && $total < $prop->{max_servers} ){
    $self->run_n_children( $prop->{spare_servers} - $num{waiting} );
    
  ### need to remove some extra waiting servers
  }elsif( $num{waiting} > $prop->{spare_servers} 
          && $num{waiting} + $num{processing} > $prop->{min_servers} ){
    if( $time - $prop->{last_checked_for_waiting} > $prop->{check_for_waiting} ){
      $prop->{last_checked_for_waiting} = $time;
      my $n = $num{waiting} + $num{processing} - $prop->{min_servers};
      if( $n > $num{waiting} - $prop->{spare_servers} ){
        $n = $num{waiting} - $prop->{spare_servers};
      }
      foreach (keys %{ $prop->{children} }){
        next unless $prop->{children}->{$_} eq 'waiting';
        last unless $n--;
        kill(1,$_);
      }
    }
    
  }
}


### routine to shut down the server (and all forked children)
sub server_close {
  my $self = shift;
  my $prop = $self->{server};

  ### if a parent, fork off cleanup sub and close
  if( ! defined $prop->{ppid} || $prop->{ppid} == $$ ){

    $self->SUPER::server_close();

  ### if a child, signal the parent and close
  ### normally the child shouldn't, but if they do...
  }else{

    kill(2,$prop->{ppid});

  }
  
  exit;
}

1;

__END__

=head1 NAME

Net::Server::PreFork - Net::Server personality

=head1 SYNOPSIS

  use Net::Server::PreFork;
  @ISA = qw(Net::Server::PreFork);

  sub process_request {
     #...code...
  }

  Net::Server::PreFork->run();

=head1 DESCRIPTION

Please read the pod on Net::Server first.  This module
is a personality, or extension, or sub class, of the
Net::Server module.

This personality binds to one or more ports and then forks
C<min_servers> child process.  The server will make sure
that at any given time there are C<spare_servers> available
to receive a client request, up to C<max_servers>.  Each of
these children will process up to C<max_requests> client
connections.  This type is good for a heavily hit site, and
should scale well for most applications.  (Multi port accept
is accomplished using flock to serialize the children).

=head1 SAMPLE CODE

Please see the sample listed in Net::Server.

=head1 COMMAND LINE ARGUMENTS

In addition to the command line arguments of the Net::Server
base class, Net::Server::PreFork contains several other 
configurable parameters.

  Key               Value                   Default
  min_servers       \d+                     5
  spare_servers     \d+                     1
  max_servers       \d+                     10
  max_requests      \d+                     1000

  serialize         (flock|semaphore|pipe)  undef
  # serialize defaults to flock on multi_port or on Solaris
  lock_file         "filename"              POSIX::tmpnam
                                            
  check_for_dead    \d+                     30
  check_for_waiting \d+                     20

  max_dequeue       \d+                     undef
  check_for_dequeue \d+                     undef

=over 4

=item min_servers

The minimum number of servers to keep running.

=item spare_servers

The minimum number of servers to have waiting for requests.

=item max_servers

The maximum number of child servers to start.

=item max_requests

The number of client connections to receive before a
child terminates.

=item serialize

Determines whether the server serializes child connections.
Options are undef, flock, semaphore, or pipe.  Default is undef.
On multi_port servers or on servers running on Solaris, the
default is flock.  The flock option uses blocking exclusive
flock on the file specified in I<lock_file> (see below).
The semaphore option uses IPC::Semaphore (thanks to Bennett
Todd) for giving some sample code.  The pipe option reads on a 
pipe to choose the next.  the flock option should be the
most bulletproof while the pipe option should be the most
portable.  (Flock is able to reliquish the block if the
process dies between accept on the socket and reading
of the client connection - semaphore and pipe do not)

=item lock_file

Filename to use in flock serialized accept in order to
serialize the accept sequece between the children.  This
will default to a generated temporary filename.  If default
value is used the lock_file will be removed when the server
closes.

=item check_for_dead

Seconds to wait before checking to see if a child died
without letting the parent know.

=item check_for_waiting

Seconds to wait before checking to see if there are too
many waiting child processes.  Extra processes are killed.
A time period is used rather than min_spare_servers and
max_spare_server parameters to avoid constant forking and 
killing when client requests are coming in close to the 
spare server thresholds.

=item max_dequeue

The maximum number of dequeue processes to start.  If a
value of zero or undef is given, no dequeue processes will
be started.  The number of running dequeue processes will
be checked by the check_for_dead variable.

=item check_for_dequeue

Seconds to wait before forking off a dequeue process.  It
is intended to use the dequeue process to take care of 
items such as mail queues.  If a value of undef is given,
no dequeue processes will be started.

=back

=head1 CONFIGURATION FILE

C<Net::Server::PreFork> allows for the use of a
configuration file to read in server parameters.  The format
of this conf file is simple key value pairs.  Comments and
white space are ignored.

  #-------------- file test.conf --------------

  ### server information
  min_servers   20
  max_servers   80
  spare_servers 10

  max_requests  1000

  ### user and group to become
  user        somebody
  group       everybody

  ### logging ?
  log_file    /var/log/server.log
  log_level   3
  pid_file    /tmp/server.pid

  ### access control
  allow       .+\.(net|com)
  allow       domain\.com
  deny        a.+

  ### background the process?
  background  1

  ### ports to bind
  host        127.0.0.1
  port        localhost:20204
  port        20205

  ### reverse lookups ?
  # reverse_lookups on
 
  #-------------- file test.conf --------------

=head1 PROCESS FLOW

Process flow follows Net::Server until the loop phase.  At
this point C<min_servers> are forked and wait for
connections.  When a child accepts a connection, finishs
processing a client, or exits, it relays that information to
the parent, which keeps track and makes sure there are
enough children to fulfill C<min_servers>, C<spare_servers>,
and C<max_servers>.

=head1 HOOKS

There are three additional hooks in the PreFork server.

=over 4

=item C<$self-E<gt>child_init_hook()>

This hook takes place immeditately after the child process
forks from the parent and before the child begins
accepting connections.  It is intended for any addiotional
chrooting or other security measures.  It is suggested
that all perl modules be used by this point, so that
the most shared memory possible is used.

=item C<$self-E<gt>child_finish_hook()>

This hook takes place immediately before the child tells
the parent that it is exiting.  It is intended for 
saving out logged information or other general cleanup.

=item C<$self-E<gt>parent_read_hook()>

This hook occurs any time that the parent reads information
from the child.  The line from the child is sent as an
argument.

=back

=head1 TO DO

See L<Net::Server>

=head1 FILES

  The following files are installed as part of this
  distribution.

  Net/Server.pm
  Net/Server/Fork.pm
  Net/Server/INET.pm
  Net/Server/MultiType.pm
  Net/Server/PreFork.pm
  Net/Server/Single.pm

=head1 AUTHOR

Paul T. Seamons paul@seamons.com

=head1 THANKS

See L<Net::Server>

=head1 SEE ALSO

Please see also
L<Net::Server::Fork>,
L<Net::Server::INET>,
L<Net::Server::PreFork>,
L<Net::Server::MultiType>,
L<Net::Server::Single>

=cut
