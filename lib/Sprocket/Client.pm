package Sprocket::Client;

use strict;
use warnings;

use POE qw(
    Filter::Stackable
    Filter::Stream
    Driver::SysRW
    Component::Client::DNS
);
use Sprocket;
use base qw( Sprocket );
use Scalar::Util qw( dualvar );

sub spawn {
    my $class = shift;
    
    my $self = $class->SUPER::spawn(
        $class->SUPER::new( @_, _type => 'remote' ),
        qw(
            _startup
            _stop

            connect
            reconnect
            remote_connect_success
            remote_connect_timeout
            remote_connect_error
            remote_error
            remote_receive
            remote_flushed

            resolved_address

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

    $session->option( @{$self->{opts}->{client_session_options}} )
        if ( $self->{opts}->{client_session_options} ); 
    $kernel->alias_set( $self->{opts}->{client_alias} )
        if ( $self->{opts}->{client_alias} );
    
    $self->{name} ||= "Client";

    $kernel->sig( INT => 'signals' );
    
    # connect to our client list
    if ( $self->{opts}->{client_list} ) {
        if ( ref( $self->{opts}->{client_list} ) eq 'ARRAY' ) {
            foreach ( @{$self->{opts}->{client_list}} ) {
                ( ref( $_ ) eq 'ARRAY' ) ? $self->connect( @$_ ) : $self->connect( $_ );
            }
        } else {
            warn "client list must be an array if defined at all";
        }
    }

#    $kernel->refcount_increment( $self->{session_id} => "$self" );
}

sub _stop {
    my $self = $_[OBJECT];
    $self->_log(v => 2, msg => $self->{name}." stopped.");
}

sub remote_connect_success {
    my ( $kernel, $self, $con, $socket ) = @_[KERNEL, OBJECT, HEAP, ARG0];
    
    $con->peer_addr( $con->peer_ip.':'.$con->peer_port );
    
    $self->_log(v => 3, msg => $self->{name}." connected");

    if ( my $tid = $con->time_out_id ) {
        $kernel->alarm_remove( $tid );
        $con->time_out_id( undef );
    }

    # keep this for accept
    $con->socket( $socket );
    
    $self->process_plugins( [ 'remote_accept', $self, $con, $socket ] );

    return;
}

sub accept {
    my ( $self, $kernel, $con, $opts ) = @_[ OBJECT, KERNEL, HEAP, ARG0 ];
    
    my $socket = $con->socket;
    $con->socket( undef );
    
    $opts = {} unless ( $opts );

    $opts->{block_size} ||= 2048;
    # XXX don't document this yet, we need to be able to set
    # the input and output filters seperately
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
        InputEvent      => $con->event( 'remote_receive' ),
        ErrorEvent      => $con->event( 'remote_error' ),
        FlushedEvent    => $con->event( 'remote_flushed' ),
    );
    
    $self->process_plugins( [ 'remote_connected', $self, $con, $socket ] );

    # nothing took the connection
    $con->close() unless ( $con->plugin );
    
    return;
}

sub remote_connect_error {
    my ( $kernel, $self, $con ) = @_[KERNEL, OBJECT, HEAP];

    $self->_log(v => 2, msg => $self->{name}." : Error connecting to ".$con->peer_addr." : $_[ARG0] error $_[ARG1] ($_[ARG2])");

    if ( my $tid = $con->time_out_id ) {
        $kernel->alarm_remove( $tid );
        $con->time_out_id( undef );
    }

    $self->process_plugins( [ 'remote_connect_error', $self, $con, @_[ ARG0 .. ARG2 ] ] );
    
    return;
}

sub remote_connect_timeout {
    my ( $kernel, $self, $con ) = @_[KERNEL, OBJECT, HEAP];
    
    $self->_log(v => 2, msg => $self->{name}." : timeout while connecting");

    $self->process_plugins( [ 'remote_connect_timeout', $self, $con ] );

    return;
}

sub remote_receive {
    my $self = $_[OBJECT];
    
    $self->process_plugins( [ 'remote_receive', $self, @_[ HEAP, ARG0 ] ] );
    
    return;
}

sub remote_error {
    my ( $kernel, $self, $con, $operation, $errnum, $errstr ) = 
        @_[ KERNEL, OBJECT, HEAP, ARG0, ARG1, ARG2 ];
    
    $con->error( dualvar( $errnum, "$operation - $errstr" ) );
    
    if ( $errnum != 0 ) {
        $self->_log(v => 3, msg => $self->{name}." encountered $operation error $errnum: $errstr");
    }
    
    $self->process_plugins( [ 'remote_disconnected', $self, $con, 1, $operation, $errnum, $errstr ] );
    
    return;
}

sub remote_flushed {
    my ( $self, $con ) = @_[ OBJECT, HEAP ];

    # we'll get called again if there are octets out
    $con->close()
        if ( $con->close_on_flush && not $con->get_driver_out_octets() );
    
    return;
}

sub connect {
    # must call in this in our session's context
    unless ( $_[KERNEL] && ref $_[KERNEL] ) {
        return $poe_kernel->call( shift->{session_id} => connect => @_ );
    }
    
    my ( $self, $kernel, $address, $port ) = @_[ OBJECT, KERNEL, ARG0, ARG1 ];
    
    unless( defined $port ) {
       ( $address, $port ) = ( $address =~ /^([^:]+):(\d+)$/ );
    }
    
    my $con;

    # PoCo DNS
    # XXX ipv6?!
    if ( $address !~ m/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/ ) {
        my $named_ses = $kernel->alias_resolve( 'named' );

        # no DNS resolver found, load one instead
        unless ( $named_ses ) {
            # could use the object here, but I don't want
            # duplicated code, so just use the session reference
            POE::Component::Client::DNS->spawn( Alias => 'named' );
            $named_ses = $kernel->alias_resolve( 'named' );
            # release ownership of this session
            #$kernel->detach_child( $named_ses );
        }

        # a new unconnected connection
        $con = $self->new_connection(
            peer_port => $port,
            peer_hostname => $address,
            peer_addr => "$address:$port", # temp until resolved
        );

        $kernel->call( $named_ses => 'resolve' => {
            host => $address,
            context => 1,
            event => $con->event( 'resolved_address' ),
        });

        # we will connect after resolving the address
        return $con;
    } else {
        $con = $self->new_connection(
            peer_ip => $address,
            peer_port => $port,
            peer_addr => "$address:$port",
        );
    }

    return $self->reconnect( $con );
}

sub resolved_address {
    my ( $self, $con, $response ) = @_[ OBJECT, HEAP, ARG0 ];
    
    my ( $response_obj, $response_err ) = @{$response}{qw( response error )};

    unless ( defined $response_obj ) {
        $self->_log( v => 4, msg => 'resolution of '.$con->peer_hostname.' failed: '.$response_err  );
        $self->process_plugins( [ 'remote_resolve_failed', $self, $con, $response_err, $response_obj ] );
        return;
    }

    my @addr = map { $_->rdatastr } ( $response_obj->answer );

    # pick a random ip
    my $peer_ip = $addr[ int rand( @addr ) ];
    $self->_log( v => 4, msg => 'resolved '.$con->peer_hostname.' to '.join(',',@addr).' using: '.$peer_ip );

    $con->peer_ips( \@addr );

    $con->peer_ip( $peer_ip );
    $con->peer_addr( $peer_ip.':'.$con->peer_port );

    $self->reconnect( $con );

    return;
}

sub reconnect {
    unless ( $_[KERNEL] && ref $_[KERNEL] ) {
        my ( $self, $con ) = @_;
        return $poe_kernel->call( $self->{session_id} => $con->event( 'reconnect' ) => @_ );
    }
    
    my ( $self, $con ) = @_[ OBJECT, HEAP ];

    # XXX include backoff?

    $con->connected( 0 );
    $con->close( 1 );
    
#    $con->sf( undef );
#    $con->wheel( undef );

    if ( $self->{opts}->{connect_time_out} ) {
        $con->time_out_id(
            $poe_kernel->alarm_set(
                $con->event( 'remote_connect_timeout' ),
                time() + $self->{opts}->{connect_time_out}
            )
        );
    }

    $con->socket_factory(
        RemoteAddress => $con->peer_ip,
        RemotePort    => $con->peer_port,
        SuccessEvent  => $con->event( 'remote_connect_success' ),
        FailureEvent  => $con->event( 'remote_connect_error' ),
    );

    return $con;
}

1;

__END__

=head1 NAME

Sprocket::Client - The Sprocket Client

=head1 SYNOPSIS

    use Sprocket qw( Client );
    
    Sprocket::Client->spawn(
        Name => 'My Client',
        ClientList => [
            '127.0.0.1:9979',
        ],
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

Sprocket::Client defines a TCP/IP Client, initiates a TCP/IP connection with
a server on a given IP and Port

=head1 METHODS

=over 4

=item spawn( %options )

Create a new Sprocket::Client object. 

=over 4 

=item Name => (Str)

The Name for this server. Must be unique.

=item ClientList => (ArrayRef)

A list of servers to connect to.

=item LogLevel => (Int)

The minimum level of logging, defaults to 4

=item Plugins => (ArrayRef)

Plugins that this client will hand off processing to. In an ArrayRef of
HashRefs format as so:

    {
        plugin => MyPlugin->new(),
        priority => 0 # default
    }

=back

=item shutdown()

Shutdown this server cleanly

=back

=head1 EVENTS

These events are handled by plugins.  See L<Sprocket::Plugin>.

=over 4

=item remote_accept

=item remote_connected

=item remote_recieve

=item remote_disconnected

=item remote_connect_error

=item remote_resolve_failed

=back

=head1 SEE ALSO

L<POE>, L<Sprocket>, L<Sprocket::Connection>, L<Sprocket::Plugin>,
L<Sprocket::Server>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 RATING

Please rate this module.
L<http://cpanratings.perl.org/rate/?distribution=Sprocket>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2007 by David Davis

See L<Sprocket> for license information.

=cut

