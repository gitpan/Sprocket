package Sprocket::Connection;

use POE qw( Wheel::SocketFactory Wheel::ReadWrite );
use Sprocket;
use Class::Accessor::Fast;
use Time::HiRes qw( time );
use base qw( Class::Accessor::Fast );

use Scalar::Util qw( weaken );

__PACKAGE__->mk_accessors( qw(
    sf
    wheel
    socket
    connected
    close_on_flush
    error
    plugin
    active_time
    create_time
    parent_id
    event_manager
    fused
    peer_ip
    peer_ips
    peer_port
    peer_addr
    peer_hostname
    local_ip
    local_port
    state
    time_out
    time_out_id
    ID
) );

our %callback_ids;

sub new {
    my $class = shift;
    my $time = time();

    my $self = bless({
        sf => undef,
        wheel => undef,
        connected => 0,
        close_on_flush => 0,
        plugin => undef,
        active_time => $time,
        create_time => $time,
        parent_id => undef,
        event_manager => 'eventman', # XXX
        fused => undef,
        peer_ip => undef,
        peer_port => undef,
        state => undef,
        channels => {},
        alarms => {},
        clid => undef,
        destroy_events => {},
        peer_ips => [],
        socket => undef,
        error => undef,
        time_out_id => undef,
        @_
    }, ref $class || $class );

    # generate the connection ID
    $self->ID( ( "$self" =~ m/\(0x([^\)]+)\)/o )[ 0 ] );

    # XXX keep this?
    if ( $self->{peer_ip} && !@{$self->{peer_ips}} ) {
        push( @{$self->{peer_ips}}, $self->{peer_ip} );
    }

    return $self;
}

sub event {
    my ( $self, $event ) = @_;

    return $self->ID.'/'.$event;
}

sub socket_factory {
    my $self = shift;

    $self->sf(
        POE::Wheel::SocketFactory->new( @_ )
    );

    return;
}

sub wheel_readwrite {
    my $self = shift;

    $self->wheel(
        POE::Wheel::ReadWrite->new( @_ )
    );

    return;
}

sub filter {
    my $self = shift;

    $self->wheel->set_filter( @_ ) if ( @_ );

    return $self->wheel->get_input_filter;
}

sub filter_in {
    my $self = shift;

    $self->wheel->set_input_filter( @_ ) if ( @_ );

    return $self->wheel->get_input_filter;
}

sub filter_out {
    my $self = shift;

    $self->wheel->set_output_filter( @_ ) if ( @_ );

    return $self->wheel->get_output_filter;
}

*write = *send;

sub send {
    my $self = shift;

    if ( my $wheel = $self->wheel ) {
        $self->active();
        return $wheel->put(@_);
    } else {
        # XXX does this happen
        $self->_log( v => 1, msg => "cannot send data, where did my wheel go?!".
            ( $self->error ? $self->error : '' ) );
    }
}

sub set_time_out {
    my $self = shift;

    $self->active();
    
    $self->time_out( shift );
}

sub alarm_set {
    my $self = shift;
    my $event = $self->event( shift );
    
    $self->active();

    my $id = $poe_kernel->alarm_set( $event => @_ );
    $self->{alarms}->{ $id } = $event;

    return $id;
}

sub alarm_adjust {
    my $self = shift;
    
    $self->active();

    $poe_kernel->alarm_adjust( @_ );
}

sub alarm_remove {
    my $self = shift;
    my $id = shift;

    $self->active();
    
    # XXX exists
    delete $self->{alarms}{ $id };
    $poe_kernel->alarm_remove( $id => @_ );
}

sub alarm_remove_all {
    my $self = shift;
    
    $self->active();

    foreach ( keys %{$self->{alarms}} ) {
        $self->_log( v => 4, "removed alarm $_ for client" );
        $poe_kernel->alarm_remove( $_ );
    }

    return;
}

sub delay_set {
    my $self = shift;
    
    $self->active();

    $poe_kernel->delay_set( $self->event( shift ) => @_ );
}

sub delay_adjust {
    my $self = shift;
    
    $self->active();

    $poe_kernel->delay_adjust( @_ );
}

sub yield {
    my $self = shift;
    
    $self->active();

    $poe_kernel->post( $self->parent_id => $self->event( shift ) => @_ );
}

sub call {
    my $self = shift;
    
    $self->active();

    $poe_kernel->call( $self->parent_id => $self->event( shift ) => @_ );
}

sub post {
    my $self = shift;
    
    $self->active();

    $poe_kernel->post( @_ );
}

sub fuse {
    my ( $self, $con ) = @_;

    $self->active();
    
    $self->fused( $con );
    weaken( $self->{fused} );

    $con->fused( $self );
    weaken( $con->{fused} );

    # TODO some code to fuse the socket or other method
    return;
}


sub accept {
    my $self = shift;
    
    $self->active();

    $self->connected( 1 );

    $poe_kernel->call( $self->parent_id => $self->event( 'accept' ) => @_ );
}

sub reject {
    my $self = shift;
    
    $self->close( 1 );
}

sub close {
    my ( $self, $force ) = @_;

    # XXX
    $self->active();

    if ( my $wheel = $self->wheel ) {
        my $out = $wheel->get_driver_out_octets;

        if ( !$force && $out ) {
            $self->close_on_flush( 1 );
            return;
        } else {
            $wheel->shutdown_input();
            $wheel->shutdown_output();
        }
    }
    
    $self->wheel( undef ) if ( $force );

    $self->time_out( undef );
    
    # kill the socket factory if any
    $self->sf( undef );
   
    # socket is only here during the accept phase
    if ( my $socket = $self->socket ) {
        close( $socket );
    }
    $self->socket( undef );

    # fused sockets closes its peer
    if ( my $con = $self->fused() ) {
        $con->close( $force );
        $self->fused( undef );
    }

    if ( $self->connected ) {
        $self->connected( 0 );
        $poe_kernel->call( $self->parent_id => cleanup => $self->ID );
    }

    return;
}

sub reconnect {
    my $self = shift;
    
    $self->active();
    
    $poe_kernel->call( $self->parent_id => $self->event( 'reconnect' ) => @_ );
}

sub get_driver_out_octets {
    my $self = shift;

    if ( my $wheel = $self->wheel ) {
        $self->active();
        return $wheel->get_driver_out_octets();
    }

    return 0;
}

sub active {
    shift->active_time( time() );
}

sub callback {
    my ($self, $event, @etc) = @_;
    
    $self->active();

    my $id = $self->parent_id;
    $event = $self->event( $event );

    my $callback = Sprocket::Connection::AnonCallback->new(sub {
        $poe_kernel->call( $id => $event => @etc => @_ );
    });

    $callback_ids{$callback} = $id;

    $poe_kernel->refcount_increment( $id, 'anon_event' );

    return $callback;
}

sub postback {
    my ($self, $event, @etc) = @_;

    $self->active();
    
    my $id = $self->parent_id;
    $event = $self->event( $event );

    my $postback = Sprocket::Connection::AnonCallback->new(sub {
        $poe_kernel->post( $id => $event => @etc => @_ );
        return 0;
    });

    $callback_ids{$postback} = $id;

    $poe_kernel->refcount_increment( $id, 'anon_event' );

    return $postback;
}

sub _log {
    my $self = shift;

    $poe_kernel->call( $self->parent_id => _log => ( l => 1, @_ ) );
}

# Danga::Socket type compat
# ------------------------
# Do not document

sub tcp_cork {
    # XXX is this the same as watch_read(0)?
}

sub watch_write {
    my ( $self, $watch ) = @_;

    $self->active();

    if ( my $wheel = $self->wheel ) {
        if ( $watch ) {
            $wheel->resume_output();
        } else {
            $wheel->pause_output();
        }
    } # XXX else

    return;
}

sub watch_read {
    my ( $self, $watch ) = @_;

    $self->active();

    if ( my $wheel = $self->wheel ) {
        if ( $watch ) {
            $wheel->resume_input();
        } else {
            $wheel->pause_input();
        }
    } # XXX else

    return;
}

# ------------------------

sub DESTROY {
    my $self = shift;

    # XXX this will change
    if ( keys %{$self->{destroy_events}} ) {
        foreach my $type ( keys %{$self->{destroy_events}} ) {
            $poe_kernel->post( @{$self->{destroy_events}->{$type}} );
        }
    }

    # remove alarms for this connection
    foreach ( keys %{$self->{alarms}} ) {
        $self->_log( v => 4, "removed alarm $_ for client" );
        $poe_kernel->alarm_remove( $_ );
    }
    
    return;
}

1;

package Sprocket::Connection::AnonCallback;

use POE;

sub new {
    my $class = shift;

    bless( shift, $class );
}

sub DESTROY {
    my $self = shift;
    my $parent_id = delete $Sprocket::Connection::callback_ids{"$self"};

    if ( defined $parent_id ) {
        $poe_kernel->refcount_decrement( $parent_id, 'anon_event' );
    } else {
        warn "connection callback DESTROY without session_id to refcount_decrement";
    }

    return;
}

1;

__END__

=pod

=head1 NAME

Sprocket::Connection - Encapsulates a client or server connection

=head1 ABSTRACT

This module provides accessors and methods to handle Sprocket connections.

=head1 NOTES

Connection objects are created by L<Sprocket::Server> and L<Sprocket::Client>
and passed to L<Sprocket::Plugin> events.

=head1 METHODS

=over 4

=item event( $event_name )

Returns an event name suitable for use with Sprocket witch pairs the
event with the connection.

=item send( $data )

Send data to the connected peer.  This is the same as a L<POE::Wheel> put()

=item write( $data )

Same as send, whichever you prefer.

=item set_time_out( $seconds )

Set the idle disconnect time in seconds.  

=item alarm_set( $event, $epoch_time, @etc )

See L<POE::Kernel>.  $event is passed through event() for you.
Returns the alarm id.

=item alarm_adjust( $alarm_id, $seconds )

See L<POE::Kernel>.  Adjust an alarm by id.

=item alarm_remove( $alarm_id )

See L<POE::Kernel>.  Removes an alarm by id.

=item alarm_remove_all()

See L<POE::Kernel>.  Removes all alarms set for this connection.

=item delay_set( $event, $seconds_hence, @etc )

See L<POE::Kernel>.  Returns a delay id.  $event is passed through
event() for you.

=item delay_adjust( $delay_id, $seconds )

See L<POE::Kernel>.

=item yield( $event, @etc )

Yield to an event in the same plugin.

=item call( $event, @etc )

Call an event in the same plugin.

=item post( $session, $event, @etc )

Shortcut to $poe_kernel->post().

=item accept()

Accept a connection during the accept phase.

=item reject()

Reject a connection during the accept phase.

=item close( $force )

Close a connection after all data is flused, unless $force is defined
then the connection is closed immediately.

=item reconnect()

Reconnect to a client.

=item get_driver_out_octets()

Returns the number of octets are left to write to the client.
See L<POE::Wheel::ReadWrite>.

=item active()

Update the connection's active time, to keep it from timing out.
(If a timeout is set)

=item callback( $event, @etc )

Returns a callback tied to this connection.  $event is passed through
event() for you.  Extra params (@etc) are optional.

=item postback( $event, @etc )

Returns a postback tied to this connection.  $event is passed through
event() for you.  Extra params (@etc) are optional.

=item time_out( $seconds )

Set the idle disconnection time.  Set to undef to disable.

=back

=head1 ACCESSORS

=over 4

=item filter

Returns the input/output filter.  Normally a L<POE::Filter::Stackable> object.

=item filter_in

Returns the input filter.  Only use this if your plugin does not use the
default filter: L<POE::Filter::Stackable>

=item filter_out

Returns the output filter.  Only use this if your plugin does not use the
default filter: L<POE::Filter::Stackable>

=item wheel

Returns the L<POE::Wheel::ReadWrite> wheel for this connection.

=item connected

Returns true if this connection is connected.

=item error

A dualvar containing the error number and error string ONLY after an
error has occurred.

=item active_time

The last time this conneciton was active.

=item create_time

The time this connection was created.

=item peer_ip

The peer ip for this connection.

=item peer_ips

Returns an array ref of peer ips for this connection.  Only for client
connections. If a hostname was used during a connect and that hostname
resolved to multiple 'A' records, then they are retreivable here after
a remote_connected event.

=item peer_port

The peer's port for this connection.

=item peer_addr

Combination of peer_ip:peer_port.

=item peer_hostname

Peer hostname for this connection (could be an IP).

=item local_ip

Local ip for this connection.

=item local_port

Local port for this connection.

=item state

Current conneciton state name.  One of the L<Sprocket::Plugin> event method names.

=item ID

The connection's ID

=head1 SEE ALSO

L<POE>, L<Sprocket>, L<Sprocket::Plugin>, L<Sprocket::Server>, L<Sprocket::Client>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2007 by David Davis

See L<Sprocket> for license information.

=cut

