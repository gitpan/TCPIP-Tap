package TCPIP::Tap;

=head1 NAME

TCPIP::Tap - connects a client and a server via a 'tap', giving visibility of and control over messages passed.

=head1 VERSION

Version 0.01_01

=cut

our $VERSION = '0.01_01';

=head1 SYNOPSIS

TCPIP::Tap is designed to be inserted between a client and a server. It proxies all traffic through verbatum, and also copies that same data to a log file and/or a callback function, allowing a data session to be monitored, recorded and/or altered on the fly.

Tap acts as a 'man in the middle', sitting between the client and server.  To the client, Tap looks like the server.  To the server, Tap looks like the client.

There is an (as yet unreleased) sister module L<TCPIP::Replay> that allows a 'tapped' session to be replayed.

When started, Tap opens a socket and listens for connections. When that socket is connected to, Tap opens another connection to the server.  Messages from either client or server are passed to the other, and a copy of each message is, potentially, logged.  Alternately, callback methods may be used to add business logic, including potentially altering the messages being passed.

Tap cannot be used to covertly tap unsuspecting client/server sessions - it requires that you control either the client or the server.  If you control the client, you can tell it to connect via your tap.  If you control the server, you can move it to a different port, and put a tap in its place.  

Tap can also be used to allow two processes on machines that cannot 'see' each other to communicate via an intermediary machine that is visible to both.

=head3 Usage

Assume the following script is running on the local machine:

    use TCPIP::Tap;
    my $tap = TCPIP::Tap->new("cpan.org", 80, 10080);
    $tap->log_file("tap.log");
    $tap->go();

A browser connecting to L<http://localhost:10080> will be connected to cpan.org - and all communications back and forwards will be logged to tap.log.  

=head2 Modifying messages on the fly.

However you deploy Tap, it will be virtually identical to having the client and server talk directly.  The difference will be that either the client and/or server will be at an address other than the one its counterpart believes it to be at.  Most programs ignore this, but sometimes it matters.

For example, HTTP servers often return URLs containing the address of the server.  If the browser is told to navigate to the returned URL, it will from that point onwards connect directly to the server instead of communicating via Tap.

Further, HTTP browsers pass a number of parameters, one of which is the Host to which the browser believes it is connecting.  Often, this does not matter.  But sometimes, a single HTTP server will be serving content for more than one website.  Such a server generally relies on the Host parameter to know what it is to return.  

These two problems can be worked around by modifying the messages being passed.

For example, assume the following script is running on the local machine:

    use TCPIP::Tap;
    sub send_($) {$_[0] =~ s/Host: .*:\d+/Host: cpan.org/;}
    sub receive($) {$_[0] =~ s/cpan.org:\d+/localhost:10080/g;}
    my $tap = TCPIP::Tap->new("cpan.org", 80, 10080);
    $tap->send_callback(\&send);
    $tap->receive_callback(\&receive);
    $tap->log_file("http_tap.log");
    $tap->go();

The send callback tells the server that it is to serve cpan.org pages, instead of some other set of pages, while the receive callback tells the browser to access cpan.org URLs via the tap process, not directly.  Server will now respond properly, even though the browser has sent the wrong hostname, and the browser will now behave as desired and direct future requests through the tap.

A more difficult problem is security aware processes, such as those that use HTTPS based protocols. They are actively hostname aware.  Precisely to defend against a man-in-the-middle attack, they check their counterpart's reported hostname (but not normally the port) against the actual hostname.  Unless client, server and tap are all on the same host, either the client or the server will notice that the remote hostname is not what it should be, and will abort the connection.  
There is no good workaround for this, unless you can run an instance of tap on the server, and another on the client - but even if you do, you still have to deal with the communication being encrypted.

=head1 SUBROUTINES/METHODS

=cut

# #######
# Globals
# #######

use 5.002;
use warnings FATAL => 'all';
use Socket;
use FileHandle;
use Carp;
use strict;

my $protocol = getprotobyname('tcp'); # TODO: make dynamic?

=head2 new( remote_ip_address, local_port_num, remote_port_num )

Creates a new Tap

=head3 Parameters

=over

=item * remote_ip_address - the remote hostname/IP address of the server 

=item * remote_port_num   - the remote port number of the server

=item * local_port_num   - the port number to listen on

=back

=head3 Usage

To keep a record of all messages sent:

    use TCPIP::Tap;
    my $tap = TCPIP::Tap->new("www.cpan.org", 80, 10080);
    $tap->log_file("tap.log");
    $tap->go();

=cut 

#TODO rename go to mainloop or something

sub hhmmss();

sub new($$;$$$) {
  my $class=shift;
  my %this;
  $this{remote_ip_address} = shift or die "remote hostname/ip address missing";
  $this{remote_port_num} = shift or die "remote port number missing";
  $this{local_port_num} = shift || $this{remote_port_num};
  $this{verbose} = 1;
  $this{mydate} = \&hhmmss;
  return bless(\%this, $class);
}

=head2 go()

Listen on local_port, accept incoming connections, and forwards messages back and forth.

=head3 Parameters

=over

=item * --none--

=back

=head3 Usage

When a new connection on local_port is received a child process is spawned (unless this is disabled using parallel() and messages from the client are passed to the server and vice-versa. (If new_server() was used instead of new(), messages from client are instead passed to the server callback function.)

If any callback functions have been set, they will be called before each message is passed.
If logging is on, messages will be logged.

There is no way to send an unprompted message.

go() does not return. You may want to L<fork> before calling it.  There is no way to stop it from outside except using a signal to interrupt it.

=cut

# Convenience function - intentionally not exposed. If you really want to call it, you can of course. But if you are going to violate encapsulation, why not go directly to the variables?

sub _set($;$) {
  my $this=shift;
  my $key=shift;
  my $value=shift;
  if(defined $value){
    $this->{$key} = $value;
  }
  return $this->{$key};
}

=head2 verbose( [level] )

Turns on/off reporting to stdout. Default is on.

=head3 Parameters

=over

=item * level         - how verbose to be. 0=nothing, 1=normal, 2=debug

=item * Returns:      - the current or new setting

=back

=head3 Usage

=cut 

sub verbose(;$) {
  my $this=shift;
  my $verbose=shift;
  #warn "verbose->(",$verbose||"--undef--",")\n";
  return $this->_set("verbose", $verbose);
}

=head2 send_callback( send_callback )

set a callback function to monitor/modify each message sent to server

=head3 Parameters

=over

=item * send_callback - the method to be called for message sent to server

=item * Returns:      - the current or new setting

=back

=head3 Usage

If send_callback is set, it will be called with a copy of each message to the server before it is sent.  Whatever the callback returns will be sent.

If the callback is readonly, it should either return a copy of the original message, or undef. Be careful not to accidentally return something else - remember that perl methods implicitly returns the value of the last command executed.

For example, to write messages to a log:

    sub peek($) {my $_ = shift; print LOG; return $_;}
    my $tap = TCPIP::Tap->new("www.cpan.org", 80, 10080);
    $tap->send_callback(\&peek);
    $tap->receive_callback(\&peek);
    $tap->go();

For example, to modify messages:

    use TCPIP::Tap;
    sub send_($) {$_[0] =~ s/Host: .*:\d+/Host: cpan.org/;}
    sub receive($) {$_[0] =~ s/www.cpan.org(:\d+)?/localhost:10080/g;}
    my $tap = TCPIP::Tap->new("www.cpan.org", 80, 10080);
    $tap->send_callback(\&send);
    $tap->receive_callback(\&receive);
    $tap->go();

=cut 

sub send_callback(;$) {
  my $this=shift;
  my $send_callback=shift;
  return $this->_set("send_callback", $send_callback);
}

=head2 receive_callback( [receive_callback] )

set a callback function to monitor/modify each message recieved from server

=head3 Parameters

=over

=item * receive_callback - the method to be called for each inward message

=item * Returns:         - the current or new setting

=back

=head3 Usage

If receive_callback is set, it will be called with a copy of each message received from the server before it is sent to the client.  Whatever the callback returns will be sent.  

If the callback is readonly, it should either return a copy of the original message, or undef. Be careful not to accidentally return something else - remember that perl methods implicitly returns the value of the last command executed.

=cut 

sub receive_callback(;$) {
  my $this=shift;
  my $callback=shift;
  return $this->_set("receive_callback", $callback);
}

=head2 parallel( [level] )

Turns on/off running in parallel. Default is on.

=head3 Parameters

=over

=item * level         - 0=serial, 1=parallel

=item * Returns:      - the current or new setting

=back

=head3 Usage

If running in parallel, Tap support multiple concurrent connections by starting a new process for each new connection using L<fork>.

If running in serial, any additional clients must wait for the current client to finish.

Turning off parallel can be very helpful for debugging, as long as it doesn't matter if your client sessions have to wait for each other.

=cut 

sub parallel(;$) {
  my $this=shift;
  my $parallel=shift;
  return $this->_set($parallel); # FIXME
}

=head2 log_file( [log_file_name] ] )

log_file() sets, or clears, a log file.  

=head3 Parameters

=over

=item * log_file_name     - the name of the log file to be appended to. Passing "" disables logging. Passing nothing, or undef, returns the current log filename without change.

=item * Returns: log file name

=back

=head3 Usage 

The log file contains a record of connects and disconnects and messages as sent back and forwards.  Log entries are timestamped.  If the log file already exists, it is appended to.

=cut 

sub log_file(;$) {
  my $this=shift;
  my $new_log_file=shift;
  if(defined $new_log_file){
    if(!$new_log_file){
      if($this->{LOGFILE}){
        close($this->{LOGFILE});
        $this->{log_file}=$this->{LOGFILE}=undef;
        print "Logging turned off\n" if $this->{verbose};
      }
    }else{
      my $LOGFILE;
      if( open($LOGFILE, ">>$new_log_file") ) {
        binmode($LOGFILE);
        select($LOGFILE);$|=1;select(STDOUT);
        $this->{log_file}=$new_log_file;
        $this->{LOGFILE}=$LOGFILE;
      }
      else {
        print "Failed to open $new_log_file for logging: $!" if $this->{verbose}; 
      }
      print "Logging to $this->{log_file}\n" if $this->{verbose} && $this->{log_file};
    }
  }
  return $this->{log_file};
}

=head2 defrag_delay( [delay] )

Use a small delay to defragment messages

=head3 Parameters

=over

=item * Delay         - seconds to wait - fractions of a second are OK

=item * Returns: the current setting.

=back

=head3 Usage

Under TCPIP, there is always a risk that large messages will be fragmented in transit, and that messages sent close together may be concatenated.

Client/Server programs have to know how to turn a stream of bytes into the messages they care about, either by repeatedly reading until they see an end-of-message (defragmenting), or by splitting the bytes read into multiple messages (deconcatenating).

For our purposes, fragmentation and concatenation can make our logs harder to read.

Without knowning the protocol, it's not possible to tell for sure if a message has been fragmented or concatenated.

A small delay can be used as a way of defragmenting messages, although it increases the risk that separate messages may be concatenated.

Eg:
    $tap->defrag_delay( 0.1 );

=cut 

sub defrag_delay(;$) {
  my $this=shift;
  my $defrag_delay=shift;
  return $this->_set("defrag_delays",$defrag_delay);
}

=head1 SUPPORTING SUBROUTINES/METHODS

The remaining functions are supplimentary.  new_server and new_client provide a simple client and a simple server that may be useful in some limited circumstances, such as testing your own programs.  The other methods are only likely to be useful if you choose to bypass go() in order to, for example, have more control over messages being received and sent.

=head2 new_server( local_port_num, callback_function )

new_server returns a very simple server, adequate for simple tasks

=head3 Parameters

=over

=item * local_port_num    - the Port number to listen on

=item * callback_function - a function to be called when a message arrives - must return a response which will be returned to the client

=back

=head3 Usage

  sub do_something($){
    my $in = shift;
    my $out = ...
    return $out;
  }

  my $server = TCPIP::Tap::new_server(8080,\&do_something) || die;
  $server->go();
 
The server returned by new_server has a method, go(), which tells it to start receiving messages (arbitrary strings).  Each string is passed to the callback_function, which is expected to return a single string, being the response to be returned to caller.  If the callback returns undef, the original message will be echoed back to the client.   

go() does not return. You may want to L<fork> before calling it.

=cut 

sub new_server($%) {
  my $class=shift;
  my %this;
  $this{local_port_num} = shift or croak "no port number passed";
  $this{receive_callback} = shift or croak "no callback passed";
  $this{verbose} = 1;
  $this{mydate} = \&hhmmss;
  return bless \%this;
}


=head2 new_client( remote_host, local_port_num )

new client returns a very simple client, adequate for simple tasks

The server returned has a single method, send_and_receive(), which sends a message and receives a response. 

Alternately, sendToServer() may be used to send a message, and readFromServer() may be used to receive a message.

=head3 Parameters

=over

=item * remote_ip_address - the hostname/IP address of the server

=item * remote_port_num   - the Port number of the server


=back

=head3 Usage

  my $client = TCPIP::Tap::new_client("localhost", 8080) || die("failed to start test client: $!");
  $client->connectToServer();
  my $resp = $client->send_and_receive("hello");
  ...

=cut 

sub new_client($%) {
  my $class=shift;
  my %this;
  $this{remote_ip_address} = shift or croak "remote hostname/ip address missing";
  $this{remote_port_num} = shift or croak "remote port number missing";
  $this{verbose} = 1;
  $this{mydate} = \&hhmmss;
  return bless \%this;
}

=head2 log( string )

log is a convenience function that prefixes output with a timestamp and PID information then writes to log_file.

=head3 Parameters

=over

=item * string(s) - one or more strings to be logged

=back

=head3 Usage

log is a convenience function that prefixes output with a timestamp and PID information then writes to log_file.

log() does nothing unless log_file is set, which by default, it is not.

=cut 

sub log($@)
{
  my $this=shift;
  printf {$this->{LOGFILE}} "%u:%s %s\n", $$, $this->{mydate}(), "@_" if $this->{LOGFILE};
}

=head2 echo( string(s) )

echo prints to stdout, or not

=head3 Parameters

=over

=item * string(s) - one or more strings to be echoed (printed)

=back

=head3 Usage

echo() is a convenience function that prefixes output with a timestamp and PID information and prints it to standard out if verbose is set and, if log_file is set, logs it.

=cut 

sub echo($@) 
{
  my $this=shift;
  $this->log("@_");
  #warn "/// echo @_ /// verbose $this->{verbose}\n"; #TODO remove this line - debug only
  return if !$this->{verbose};
  if($_[0] =~ m/^[<>]{3}$/){
    my $prefix=shift;
    my $msg=join "", @_;
    printf("%u:%s %s %d bytes\n", $$, $this->{mydate}(), $prefix, length($msg));
  }else{
    printf("%u:%s\n", $$, join(" ", $this->{mydate}(), @_));
  }
}

=head2 sendToServer( string(s) )

sendToServer() sends a message to the server

=head3 Parameters

=over

=item * string(s) - one or more strings to be sent

=back

=head3 Usage

If a callback is set, it will be called before the message is sent.

=cut 

sub _doCallback($$)
{
    my $callback = shift;
    my $msg = shift;
    if($callback){
      my $new_msg = $callback->($msg);
      $msg = $new_msg unless !defined $new_msg;
    }
    return $msg;
}

sub _logmsg
{
  my $this = shift;
  my $direction = shift;
  my $msg = shift;
  if($this->{verbose}>1){
    $this->echo($direction,"(".length($msg)." bytes) {$msg}\n");
  }else{
    # don't print the whole message by default, in case it is either binary &/or long
    $this->echo($direction,"(".length($msg)." bytes)\n");
    $this->log($direction," {{{$msg}}}\n");
  }
}

sub sendToServer($@)
{
    my $this = shift;
    my $msg = shift;
    if(!$this->{SERVER}){
      $this->connectToServer();
    }
    $this->log("calling server callback ($msg)\n") if $this->{send_callback} && $this->{verbose}>1;
    $msg = _doCallback( $this->{send_callback}, $msg );
    $this->_logmsg(">>>",$msg);
    confess "SERVER being null was unexpected" if !$this->{SERVER};
    print({$this->{SERVER}} $msg) || die "Can't send to server: $?";
}

=head2 sendToClient( string(s) )

sendToClient() sends a message to the client

=head3 Parameters

=over

=item * string(s) - one or more strings to be sent

=item * Return: true if successful

=back

=head3 Usage

If a callback is set, it will be called before the message is sent.

=cut 

sub sendToClient($@)
{
    my $this = shift;
    my $msg = shift;
    $this->echo("calling client callback ($msg)\n") if $this->{receive_callback} && $this->{verbose}>1;
    $msg = _doCallback( $this->{receive_callback}, $msg );
    $this->_logmsg("<<<",$msg);
    return print({$this->{CLIENT}} $msg);
}

=head2 readFromServer()

readFromServer() reads a message from the server

=head3 Parameters

=over

=item * --none--

=item * Returns: the message read, or undef if the server disconnected.  

=back

=head3 Usage

Blocks until a message is received.

=cut 

sub readFromServer()
{
  my $this=shift;
  my $msg;
  sysread($this->{SERVER},$msg,100000);
  if(length($msg) == 0)
  {
    $this->echo("Server disconnected\n");
    return undef;
  }
  return $msg;
}

=head2 send_and_receive()

send_and_receive() sends a message to the server and receives a response

=head3 Parameters

=over

=item * the message(s) to be sent

=item * Returns: message read, or undef if the server disconnected. 

=back

=head3 Usage

Blocks until a message is received.

=cut 

sub send_and_receive($)
{
  my $this=shift;
  $this->sendToServer(@_);
  return $this->readFromServer(@_);
}

=head2 connectToServer()

Connects to the server

=head3 Parameters

=over

=item * --none--


=back

=head3 Usage

This method is called by go(). It only needs to be called directly if go() is being bypassed for some reason. 

=cut

sub connectToServer()
{
  my $this=shift;
  socket($this->{SERVER}, PF_INET, SOCK_STREAM, $protocol)
    or die "Can't create socket: $!";
  my $remote_ip_aton = inet_aton( $this->{remote_ip_address} ) or croak "Fatal: Cannot resolve internet address: '$this->{remote_ip_address}'\n";
  my $remote_port_address = sockaddr_in($this->{remote_port_num}, $remote_ip_aton )
    or die "Fatal: Can't get port address: $!"; # FIXME Is die the way to go here? Not sure it isn't. Not sure it is.
  $this->echo("Connecting to $this->{remote_ip_address}\:$this->{remote_port_num} [verbose=$this->{verbose}]\n");
  connect($this->{SERVER}, $remote_port_address)
    or die "Fatal: Can't connect to $this->{remote_ip_address}:$this->{remote_port_num}. $!"; # FIXME Is die the way to go here? Not sure it isn't. Not sure it is.
  select($this->{SERVER});$|=1;select(STDOUT);
  binmode($this->{SERVER});
}

=head2 disconnectFromServer()

Disconnects from the server

=head3 Parameters

=over

=item * --none--


=back

=head3 Usage

Disconnection is normally triggered by the other party disconnecting, not by us. disconnectFromServer() is potentially useful with new_client, but is not otherwise supported.

=cut

sub disconnectFromServer()
{
  my $this=shift;
  $this->log("initiating disconnect");
  $this->_destroy();
}

=head2 sendAndReceiveLoop()

Passes messages between client and server.

=head3 Parameters

=over

=item * --none--


=back

=head3 Usage

This method is called by go(). It only needs to be called directly if go() is being bypassed for some reason. 

It does not return until either client or server disconnects.

=cut

sub sendAndReceiveLoop(@)
{
  my $this=shift;
  my $client_paddr = shift;
  my ($client_port, $client_iaddr) = sockaddr_in( $client_paddr );
  $this->log("Connection accepted from", inet_ntoa($client_iaddr).":$client_port\n"); 
  $this->connectToServer() if($this->{remote_port_num});
  $this->echo("Connection made\n");
  # Build file descriptor list for select call 
  my $rin = "";
  vec($rin, fileno($this->{CLIENT}), 1) = 1;
  vec($rin, fileno($this->{SERVER}), 1) = 1 if $this->{SERVER};
  while( 1 )
  {
    #$retval = select ( undef, undef, undef, .1 );
    my $rout = $rin;
    select( $rout, "", "", undef ); # TODO This shouldn't have to be a blocking read - maybe add an option for a timeout and another option for an extra hook here?
    #print( $retval,",",unpack("b32",$rin),"\n" );
    if( vec($rout,fileno($this->{CLIENT}),1) ) {
      # Message from CLIENT to SERVER
      sleep($this->{defrag_delay}) if $this->{defrag_delay};
      # TODO maybe better to implement defrag through: read, wait, check select again - would be up to the user to not set defrag too high. Would need to handle far end sending a message then immediately closing the socket.
      my $msg;
      sysread($this->{CLIENT},$msg,10000);
      # (0 length message means connection closed)
      if(length($msg) == 0) { 
          $this->echo("Client disconnected\n");
          last ;
      }
      # Send message to server, if any. Else 'send' to callback function and return result to client.
      if($this->{SERVER}){
        $this->sendToServer($msg);
      }else{
        $this->sendToClient( $this->{receive_callback}($msg) );
      }
    }

    if( $this->{SERVER} && vec($rout,fileno($this->{SERVER}),1) ) {
      # can sleep first, to avoid splitting messages
      sleep($this->{defrag_delay}) if $this->{defrag_delay};
      # Read from SERVER and copy to CLIENT
      my $msg = $this->readFromServer();
      last if !defined $msg;
      $this->sendToClient($msg);
    }
  }
  $this->echo("Disconnected\n\n");
  close $this->{CLIENT};
  close $this->{SERVER} if $this->{SERVER};
}

=head2 hhmmss()

The default timestamp function - returns locatime in hh:mm:ss format

=head3 Parameters

=over

=item * --none--


=back

=head3 Usage

This function is, by default, called when a message is written to the log file.

It may be overridden by calling mydate().

=cut

sub hhmmss()
{
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
  return sprintf "%02d:%02d:%02d",$hour,$min,$sec;
}

=head2 mydate()

Override the standard hh:mm:ss datestamp

=head3 Parameters

=over

=item * datestamp_callback - a function that returns a datestamp


=back

=head3 Usage

For example:

  sub ymdhms {
    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
    return sprintf "%02d/%02d/%02d %02d:%02d:%02d", 
      $year+1900,$mon+1,$mday,$hour,$min,$sec;
  }
  mydate(\&ymdhms);

=cut

sub mydate(;$)
{
  my $this=shift;
  my $mydate=shift||undef;
  if(defined $mydate){
    $this->{mydate} = $mydate;
  }
  return $this->{mydate};
}

=head2 listen()

Listen on local_port and prepare to accept incoming connections

=head3 Parameters

=over

=item * --none--

=back

=head3 Usage

This method is called by go(). It only needs to be called directly if go() is being bypassed for some reason.

=cut

sub listen()
{
  my $this=shift;
  # open tcp/ip socket - see blue camel book pg 349
  socket($this->{LISTEN}, PF_INET, SOCK_STREAM, $protocol) or die "Fatal: Can't create socket: $!";
  bind($this->{LISTEN}, sockaddr_in($this->{local_port_num}, INADDR_ANY)) or die "Fatal: Can't bind socket $this->{local_port_num}: $!";
  listen($this->{LISTEN},1) or die "Fatal: Can't listen to socket: $!";
  $this->echo("Waiting on port $this->{local_port_num}\n");
}

sub go()
{
  my $this=shift;
  $this->listen();
  # Main Loop
  my $connections;
  while(1)
  {
    # Accept a new connection 
    my $client_paddr = accept($this->{CLIENT}, $this->{LISTEN}); 
    select($this->{CLIENT});$|=1;select(STDOUT);
    binmode($this->{CLIENT});
    # hand-off the connection
    $this->echo("starting connection:",++$connections);
    if($this->{parallel}){
      $SIG{CLD} = "IGNORE";
      my $pid = fork();
      if(!defined $pid){
        # Error
        $this->echo("Cannot fork!: $!\nNo more connections will be accepted until this one finishes\n");
        $this->sendAndReceiveLoop($client_paddr);
      }elsif(!$pid){
        # Child
        $this->sendAndReceiveLoop($client_paddr);
        exit;
      }else{
        # Parent
        close $this->{CLIENT};
      }
    }
    else{
      $this->sendAndReceiveLoop($client_paddr);
    }
  }
}

sub _destroy()
{
  my $this=shift;
  close $this->{SERVER} if($this->{SERVER});
  close $this->{CLIENT} if($this->{CLIENT});
  $this->{SERVER}=$this->{CLIENT}=undef;
}

sub DESTROY()
{
  my $this=shift;
  return $this->_destroy();
}

=head1 AUTHOR

Ben AVELING, C<< <bena.aveling at optusnet.com.au> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-tcpip-tap at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=TCPIP-Tap>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc TCPIP::Tap

You can also look for information at:

=over

=item * RT: CPAN's request tracker (report bugs here)

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=TCPIP-Tap>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/TCPIP-Tap>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/TCPIP-Tap>

=item * Search CPAN

L<http://search.cpan.org/dist/TCPIP-Tap/>

=back

=head1 ACKNOWLEDGEMENTS

I'd like to acknowledge W. Richard Steven's and his fantastic introduction to TCPIP: "TCP/IP Illustrated, Volume 1: The Protocols", Addison-Wesley, 1994. (L<http://www.kohala.com/start/tcpipiv1.html>). 

It got me started. Recommend. RIP.
  
The Blue Camel Book is pretty useful too.

Langworth & chromatic's "Perl Testing, A Developer's Notebook" also has its place.

=head1 ALTERNATIVES

If what you want is a pure proxy, especially if you want an ssh proxy or support for firewalls, you might want to evaluate Philippe "BooK" Bruhat's L<Net::Proxy>.

If you want a full "portable multitasking and networking framework for any event loop", you may be looking for L<POE>.

=head1 LICENSE AND COPYRIGHT

Copyleft 2013 Ben AVELING.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, have, hold and cherish,
use, offer to use, sell, offer to sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. SO THERE.

=cut

1; # End of TCPIP::Tap
