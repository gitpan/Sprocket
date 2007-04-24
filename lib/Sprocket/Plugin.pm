package Sprocket::Plugin;

use Class::Accessor::Fast;
use base qw(Class::Accessor::Fast);
use Scalar::Util qw( weaken );
use POE;
use Sprocket;

__PACKAGE__->mk_accessors( qw( name parent_id ) );

use overload '""' => sub { shift->as_string(); };

use strict;
use warnings;

sub new {
    my $class = shift;
    bless( {
        &adjust_params
    }, ref $class || $class );
}

sub as_string {
    warn "This Sprocket plugin should have been subclassed!";
    __PACKAGE__;
}

sub handle_event {
    my ( $self, $event ) = ( shift, shift );
    
    return $self->$event( @_ )
        if ( $self->can( $event ) );
    
    return undef;
}

sub _log {
    $poe_kernel->call( shift->parent_id => _log => ( call => ( caller(1) )[ 3 ], @_ ) );
    return undef;
}

sub take_connection {
    my ( $self, $con ) = @_;
    $con->plugin( $self->name );
    return 1;
}

sub release_connection {
    my ( $self, $con ) = @_;
    $con->plugin( undef );
    return 1;
}

sub time_out {
    my ( $self, $server, $con, $time ) = @_;
    $server->_log( v => 4, msg => "Timeout for connection $con" );
    $con->close();
    return undef;
}

sub local_accept {
    my ( $self, $server, $con, $socket ) = @_;
    $con->accept();
    return 1;
}

sub remote_accept {
    my ( $self, $server, $con, $socket ) = @_;
    $con->accept();
    return 1;
}

sub remote_connect_error {
    my ( $self, $server, $con ) = @_;
    $con->close();
    return 1;
}

sub remote_disconnected {
    my ( $self, $server, $con ) = @_;
    $con->close();
    return 1;
}

sub remote_resolve_failed {
    my ( $self, $server, $con ) = @_;
    $con->close();
    return 1;
}

1;

__END__

=pod

=head1 NAME

Sprocket::Plugin - Base class for Sprocket plugins

=head1 SYNOPSIS

  use Sprocket qw( Plugin );
  use base qw( Sprocket::Plugin );

  sub new {
      shift->SUPER::new(
          name => 'MyPlugin',
          @_
      );
  }

  sub as_string {
      __PACKAGE__;
  }

  ...

=head1 ABSTRACT

This is a base class for Sprocket plugins.  It provides several default methods
for easy plugin implementation.

=head1 NOTES

A plugin can define any of the methods below.  All are optional, but a plugin
should have a conncted and a recieve method for it to function.  See the
Sprocket site for examples.  L<http://sprocket.cc/>  Plugins should use the
template in the SYNOPSIS.

=head1 METHODS

=head2 Server Methods

These are methods that can be defined in a plugin for Sprocket server instances

=over 4

=item local_accept

Called with ( $self, $server, $con, $socket )
Defining this method is optional.  The default behavior is to accept the
connection.  You can call $con->reject() or $con->accept() to reject or
accept a connection.  You can also call $self->take_connection( $con );
in this phase.  See L<Sprocket::Connection> for more information on the
accept and reject methods.

=item local_connected

Called with ( $self, $server, $con, $socket )
This is the last chance for a plugin to take a connection with
$self->take_connection( $con );  You should apply your filters for the
connection in this method.  See L<Sprocket::Connection> for details on how
to access the connection's filters.

=item local_receive

Called with ( $self, $server, $con, $data )
$data is the data from the filter applied to the connection.

=item local_disconnected

Called with ( $self, $server, $con, $error )
If error is true, then $operation, $errnum, and $errstr will also be defined
after $error.   If a connection was closed with $con->close() then $error
will be false.  If a connection was closed remotely but without an error then
$error will be true, but $errnum will be 0.  For more details, see ErrorEvent
in L<POE::Wheel::ReadWrite>.

=back

=head2 Client Methods

These are methods that can be defined in a plugin for Sprocket client instances

=over 4

=item remote_accept

Why is there an accept method for client connections?!
Well, good question.  This method is here to allow you to set the filters
and blocksize using the $con-accept method.  See L<Sprocket::Connection>

See local_accept.

=item remote_connected

See local_connected.

=item remote_receive

See local_receive.

=item remote_disconnected

See local_disconnected.
You can call $con->reconnect() to attempt to reconnect to the original host.

=item remote_connect_error

Called with ( $self, $client, $con, $operation, $errnum, $errstr )
See ErrorEvent in L<POE::Wheel::ReadWrite>.  This is called when a connection
couldn't be established.

=item remote_resolve_failed

Called with ( $self, $client, $con, $response_error, $response_obj )
Sprocket uses L<POE::Component::DNS> internally.  Connections to ip's
are not resolved.

=back

=head1 SEE ALSO

L<Sprocket>, L<Sprocket::Connection>, L<Sprocket::AIO>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2007 by David Davis

See L<Sprocket> for license information.

=cut
