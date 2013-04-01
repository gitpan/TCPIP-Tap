use Test::More;
use strict;
use TCPIP::Tap;

plan tests => 13;

# create an echo server
sub echoback($){
  print "alarm reset $$: ",alarm(60),"\n";
  return $_[0];
}
# TODO parameterise port number when test run, or something
my $next_port=8000;
my $echo_port=$next_port++;

sub pause($)
{
  select(undef,undef,undef,shift);
}

# set an alarm to kill ourselves if everything isn't done in - say - 60 seconds after fork happens.
# FIXME this isn't quite clean - it but leaves connections to timeout. running test twice in quick succession fails.

sub abort()
{
  BAIL_OUT "Timed out $$.\n";
}
$SIG{ALRM}=\&abort;

sub spawn(&)
{
  my $block=shift;
  my $pid=fork();
  print "alarm reset $$: ",alarm(60),"\n";
  if(!defined $pid){
    #error
    BAIL_OUT("cannot fork: $!");
  }elsif($pid==0){
    #child
    print "spawning child...\n";
    $block->();
    BAIL_OUT("child unexpectedly exited: $!");
    #exit(); # should be OK to exit - we are just the child
  }else{
    #parent
    return $pid;
  }
}

sub new_server() {
  print "spawning $echo_port...\n";
  my $echo_server = TCPIP::Tap->new_server($echo_port,\&echoback) || BAIL_OUT("failed to start test server: $!");
  $echo_server->log_file("echo.log");
  print "go...\n";
  $echo_server->go();
  BAIL_OUT("server->go() should not have returned");
  return "this should not have happened";
}

my $server_pid=spawn(\&new_server);

#parent
pause(1); # let child start - shouldn't take more than a fraction of a second

# TODO move new_client into its own module?
# TODO make the test port configurable? choose at random? with a retry?

{
  my $test="direct to server";
  for (1..10){
    my $client = TCPIP::Tap->new_client("localhost",$echo_port);
    my $response = $client->send_and_receive("1234.$_");
    is($response, "1234.$_", "$test: send and receive a string ($_/100)");
    $client->disconnectFromServer();
  }
}

{
  my $test="tap with no callbacks";
  my $port2=$next_port++;
  my $tap_pid = spawn(
    sub{
      my $tap = TCPIP::Tap->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start tap: $!");
      $tap->go();
      BAIL_OUT("tap->go() should not have returned");
    }
  );
  pause(1); # should only need a fraction of a second
  my $client = TCPIP::Tap->new_client("localhost",$port2);
  my $response = $client->send_and_receive("232");
  is($response,"232","$test: send and receive a string");
  $client->disconnectFromServer();
  pause(1); # should only need a fraction of a second
  kill 'TERM', $tap_pid;
}

# note - log1 and log2 are called in the child process, not in the parent - cannot be used to return a value to parent when running in parallel

my @log1=">";
sub log1($)
{
  print "++ log1 called (@_) ++\n";
  unshift @log1, @_, "!"; 
}

my @log2;
sub log2($)
{
  print "++ log2 called (@_) ++\n";
  unshift @log2, @_, "!";
}

if(0) # Test not currently adding value - skip it.
{
  my $test="tap with readonly callbacks";
  my $port2=$next_port++;
  my $tap_pid = spawn(
    sub{
      my $tap = TCPIP::Tap->new('localhost',$echo_port,$port2,\&log1,\&log2) || BAIL_OUT("failed to start tap: $!");
      $tap->go();
      BAIL_OUT("tap->go() should not have returned");
    }
  );
  pause(1); # should only need a fraction of a second
  my $client = TCPIP::Tap->new_client("localhost",$port2);
  #@log1=@log2=();
  my $response = $client->send_and_receive("234");
  is($response,"234","$test: send and receive a string");
  #FIXME - to test this, need to run not in parallel, then exit - not currently supported. Maybe make parallel() smarter? Or could run the client in a seperate thread? Add another callback in the go loop?  A backchannel, such as another socket connection or even a write to filehandle, initiated by callbacks? Backchannel feels odd - the test code would be doing far more than what it is testing, but perhaps that's not really so unusual. All that said, we can know the callbacks work because we see the effect in the responses we receive.
  #is_deeply(\@log1,["234"],"$test: log request");
  #is_deeply(\@log2,["235"],"$test: lot response");
  $client->disconnectFromServer();
  pause(1); # should only need a fraction of a second
  kill 'TERM', $tap_pid;
}

sub manipulate1($)
{
  my $_ = shift;
  s/a/A/;
  return $_;
}

sub manipulate2($)
{
  my $_ = shift;
  s/e/E/;
  return $_;
}

{
  my $test="tap with readwrite callbacks";
  my $port2=$next_port++;
  my $tap_pid = spawn(
    sub{
      my $tap = TCPIP::Tap->new('localhost',$echo_port,$port2) || BAIL_OUT("failed to start tap: $!");;
      $tap->send_callback(\&manipulate1);
      $tap->receive_callback(\&manipulate2);
      $tap->go();
      BAIL_OUT("tap->go() should not have returned");
    }
  );
  pause(1); # should only need a fraction of a second
  my $client = TCPIP::Tap->new_client("localhost",$port2);
  my $response = $client->send_and_receive("abc");
  is($response,"Abc","$test: request manipulation");
  $response = $client->send_and_receive("def");
  is($response,"dEf","$test: response manipulation");
  $client->disconnectFromServer();
  pause(1); # should only need a fraction of a second
  kill 'TERM', $tap_pid;
}

if(0) # TODO Not working yet
{
  my $test="defrag_delay";
  my $port2=$next_port++;
  sub mark_fragments($){return qq{[$_[0]]}};
  my $tap_pid = spawn(
    sub{
      my $tap = TCPIP::Tap->new('localhost',$echo_port,$port2);
      $tap->send_callback(\&mark_fragments);
      $tap->receive_callback(\&mark_fragments);
      $tap->defrag_delay(0);
      $tap->log_file("defrag.log");
      $tap->go();
    }
  );
  pause(1); # should only need a fraction of a second # FIXME - can listen from new() instead of go() and then this delay can be removed - except that leaves the listen port open in parent - so need to close it - even uglier because it impacts end user. Another option would be to call Listen from here - means it needs to be reentrant - not perfect, but might be the compromise # TODO
  my $client = TCPIP::Tap->new_client("localhost",$port2);
  my $delay=0.1; # guess
  for("a".."j"){ # FIXME - only works up to about 10 message, or maybe that is all that makes sense?
    pause($delay);
    $client->sendToServer($_);
  }
  my $response1 = $client->readFromServer(); 
  isnt($response1,"[[abcdefghij]]","$test: test the test case - ensure some fragmentation is occurring so we can prove our 'prevention' is doing something");
  $client->disconnectFromServer();
  pause(1);
  kill 'TERM', $tap_pid;
  $port2=$next_port++;
  $tap_pid = spawn(
    sub{
      my $tap = TCPIP::Tap->new('localhost',$echo_port,$port2);
      $tap->send_callback(\&mark_fragments);
      $tap->receive_callback(\&mark_fragments);
      $tap->defrag_delay(3);
      $tap->log_file("defrag2.log");
      $tap->verbose(1);
      $tap->go();
    }
  );
  pause(1); # should only need a fraction of a second # FIXME - can listen from new() instead of go() and then this delay can be removed - except that leaves the listen port open in parent - so need to close it - even uglier because it impacts end user. Another option would be to call Listen from here - means it needs to be reentrant - not perfect, but might be the compromise # TODO
  $client = TCPIP::Tap->new_client("localhost",$port2);
  for("a".."j"){
    pause($delay);
    $client->sendToServer($_);
  }
  my $response2 = $client->readFromServer(); # TODO add a timeout :-(
  is($response2,"[[abcdefghij]]","$test: our messages, sent so close together, should have been defragmented into a single message");
  $client->disconnectFromServer();
  pause(1); # should only need a fraction of a second
  kill 'TERM', $tap_pid;
}

# clean up 
pause(1); # let children exit - should already have been signalled
print "killing pid: $server_pid\n";
kill('TERM',$server_pid);
pause(1); # let echo server exit - shouldn't take long
print "done\n";

done_testing();
