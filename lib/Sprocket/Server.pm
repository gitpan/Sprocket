package Sprocket::Server;

use strict;
use warnings;

use POE qw(
    Wheel::SocketFactory
    Filter::Stackable
    Filter::Stream
    Driver::SysRW
);
use Sprocket;
use base qw( Sprocket );
use Errno qw( EADDRINUSE );
use Socket;
use Scalar::Util qw( dualvar );

sub spawn {
    my $class = shift;
   
    my $self = $class->SUPER::spawn(
        $class->SUPER::new( @_, _type => 'local' ),
        qw(
            _startup
            _stop

            local_accept
            local_receive
            local_flushed
            local_wheel_error
            local_error
            local_timeout

            accept
        )
    );

    return $self;
}

sub as_string {
    __PACKAGE__;
}

sub _startup {
    my ( $kernel, $session, $self ) = @_[KERNEL, SESSION, OBJECT];

    $session->option( @{$self->{opts}->{server_session_options}} )
        if ( $self->{opts}->{server_session_options} );
    $kernel->alias_set( $self->{opts}->{server_alias} )
        if ( $self->{opts}->{server_alias} );

    $kernel->sig( INT => 'signals' );

    $self->{name} ||= "Server";

    # create a socket factory
    $self->{wheel} = POE::Wheel::SocketFactory->new(
        BindPort       => $self->{opts}->{listen_port},
        BindAddress    => $self->{opts}->{listen_address},
        Reuse          => 'yes',
        SuccessEvent   => 'local_accept',
        FailureEvent   => 'local_wheel_error',
        ListenQueue    => $self->{opts}->{listen_queue} || 10000,
    );

    $self->_log(v => 2, msg => "Listening to port $self->{opts}->{listen_port} on $self->{opts}->{listen_address}");
}

sub _stop {
    my $self = $_[ OBJECT ];
    $self->_log(v => 2, msg => $self->{name}." stopped.");
}

# Accept a new connection

sub local_accept {
    my ( $kernel, $self, $socket, $peer_ip, $peer_port ) =
        @_[ KERNEL, OBJECT, ARG0, ARG1, ARG2 ];

    $peer_ip = inet_ntoa( $peer_ip );
    my ( $port, $ip ) = ( sockaddr_in( getsockname( $socket ) ) );
    $ip = inet_ntoa( $ip );

    my $con = $self->new_connection(
        local_ip => $ip,
        local_port => $port,
        peer_ip => $peer_ip,
        # TODO resolve these?
        peer_hostname => $peer_ip,
        peer_port => $peer_port,
        peer_addr => "$peer_ip:$peer_port",
        socket => $socket,
    );

    $self->process_plugins( [ 'local_accept', $self, $con, $socket ] );
    
    return;
}

sub accept {
    my ( $self, $kernel, $con, $opts ) = @_[ OBJECT, KERNEL, HEAP, ARG0 ];
    
    my $socket = $con->socket;
    $con->socket( undef );
    
    $opts = {} unless ( $opts );

    $opts->{block_size} ||= 2048;
    $opts->{filter} ||= POE::Filter::Stackable->new(
        Filters => [
            POE::Filter::Stream->new(),
        ]
    );
    $opts->{time_out} ||= $self->{opts}->{time_out};

    $con->wheel_readwrite(
        Handle          => $socket,
        Driver          => POE::Driver::SysRW->new( BlockSize => $opts->{block_size} ),
        Filter          => $opts->{filter},
        InputEvent      => $con->event( 'local_receive' ),
        ErrorEvent      => $con->event( 'local_error' ),
        FlushedEvent    => $con->event( 'local_flushed' ),
    );

    $con->set_time_out( $opts->{time_out} )
        if ( $opts->{time_out} );
    
    $self->process_plugins( [ 'local_connected', $self, $con, $socket ] );

    # nothing took the connection
    unless ( $con->plugin ) {
        $self->_log(v => 2, msg => "No plugin took this connection, Dropping.");
        $con->close();
    }
    
    return;
}

sub local_receive {
    my ( $self, $kernel, $con ) = @_[ OBJECT, KERNEL, HEAP ];
    
    $self->process_plugins( [ 'local_receive', $self, $con, $_[ARG0] ] );
    
    return;
}

sub local_flushed {
    my ( $self, $con ) = @_[ OBJECT, HEAP ];

    $con->close()
        if ( $con->close_on_flush && not $con->get_driver_out_octets() );
    
    return;
}

sub local_wheel_error {
    my ( $self, $operation, $errnum, $errstr ) = 
        @_[ OBJECT, ARG0, ARG1, ARG2 ];
    
    $self->_log(v => 1, msg => $self->{name}." encountered $operation error $errnum: $errstr (Server socket wheel)");
    
    $self->shutdown_all() if ( $errnum == EADDRINUSE );

    # XXX
    
    return;
}

sub local_error {
    my ( $kernel, $self, $con, $operation, $errnum, $errstr ) = 
        @_[ KERNEL, OBJECT, HEAP, ARG0, ARG1, ARG2 ];
    
    $con->error( dualvar( $errnum, "$operation - $errstr" ) );
    
    # TODO use constant
    if ( $errnum != 0 ) {
        $self->_log(v => 3, msg => $self->{name}." encountered $operation error $errnum: $errstr");
    }
    
    $self->process_plugins( [ 'local_disconnected', $self, $con, 1, $operation, $errnum, $errstr ] );
 
    $con->close();
    
    return;
}

# XXX not used ATM
sub local_timeout {
    my ( $self, $con ) = @_[ OBJECT, HEAP ];

    $self->_log(v => 3, msg => "Timeout");
    
    $con->close();
    
    return;
}

1;

=head1 NAME

Sprocket::Server - the Sprocket Server Baseclass

=head1 SYNOPSIS

    use Sprocket qw( Server );
    
    Sprocket::Server->spawn(
        Name => 'Test Server',
        ListenAddress => '127.0.0.1', # Defaults to 0.0.0.0
        ListenPort => 9979,           # Defaults to random port
        Plugins => [
            {
                plugin => MyPlugin->new(),
                priority => 0, # default
            },
        ],
        LogLevel => 4,
        MaxConnections => 10000,
    );


=head1 DESCRIPTION

Sprocket::Server defines a TCP/IP Server, it binds to a Address and Port and
listens for incoming TCP/IP connections.

=head1 METHODS

=over

=item spawn( %options )

Create a new Sprocket::Server object. 

=head2 OPTIONS

=over 4

=item Name => (Str)

The Name for this server. Must be unique.

=item ListenPort => (Int)

The port this server listens on. 

=item ListenAddress => (Str)

The address this server listens on.

=item LogLevel => (Int)

The minimum level of logging, defaults to 4

=item MaxConnections => (Int)

The minimum number of connections this server will handle before refusing new ones.

=item Plugins => (ArrayRef)

Plugins that this server will hand off processing to. In an ArrayRef of HashRef's format as so:

    {
        plugin => MyPlugin->new(),
        priority => 0 # default
    }

=back

=item shutdown

Shutdown this server cleanly

=back

=head1 EVENTS

These events are handled by plugins.  See L<Sprocket::Plugin>.

=over 4

=item local_accept

=item local_connected

=item local_recieve 

=item local_disconnected

=back

=head1 SEE ALSO

L<POE>, L<Sprocket>, L<Sprocket::Connection>, L<Sprocket::Plugin>,
L<Sprocket::Client>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 RATING

Please rate this module.
L<http://cpanratings.perl.org/rate/?distribution=Sprocket>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2007 by David Davis

See L<Sprocket> for license information.

=cut

