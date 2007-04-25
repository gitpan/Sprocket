package Sprocket::AIO;

use Fcntl;
use POE;

use strict;
use warnings;

use overload '""' => sub { shift->as_string(); };

BEGIN {
    eval "use IO::AIO qw( poll_fileno poll_cb 2 )";
    if ( $@ ) {
        eval 'sub HAS_AIO () { 0 }';
    } else {
        eval 'sub HAS_AIO () { 1 }';
        eval 'IO::AIO::min_parallel 8';
    }
}

our $singleton;

sub new {
    my $class = shift;
    return $singleton if ( $singleton );
    return unless ( HAS_AIO );

    my $self = $singleton = bless({
        session_id => undef,
        @_
    }, ref $class || $class );

    POE::Session->create(
        object_states =>  [
            $self => [qw(
                _start
                _stop
                poll_cb
                watch_aio
                shutdown
                restart
            )]
        ],
    );

    return $self;
}

sub as_string {
    __PACKAGE__;
}

sub _start {
    my ( $self, $kernel, $session ) = @_[ OBJECT, KERNEL, SESSION ];
    
    $self->{session_id} = $session->ID();
    
    $kernel->alias_set( "$self" );

    $kernel->call( $session => 'watch_aio' );
    
    $self->_log( v => 2, msg => 'AIO support module started' );
   
    return;
}

sub watch_aio {
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];
    
    # eval here because poll_fileno isn't imported when IO::AIO isn't installed
    open( my $fh, "<&=".eval "poll_fileno()" );
    #or die "error during open in watch_aio $!";
    $kernel->select_read( $fh, 'poll_cb' );
    $self->{fh} = $fh;
   
    return;
}

sub _stop {
    $_[ OBJECT ]->_log(v => 2, msg => 'stopped');
}

sub _log {
    $poe_kernel->call( shift->{parent_id} => _log => ( call => ( caller(1) )[ 3 ], @_ ) );
}

sub shutdown {
    unless ( $_[KERNEL] && ref $_[KERNEL] ) {
        return $poe_kernel->call( shift->{session_id} => shutdown => @_ );
    }
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

    $kernel->alias_remove( "$self" );
    my $fh = delete $self->{fh};
    $kernel->select_read( $fh );
    $singleton = undef;

    return;
}

sub restart {
    unless ( $_[KERNEL] && ref $_[KERNEL] ) {
        return $poe_kernel->call( shift->{session_id} => restart => @_ );
    }
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];
    
    my $fh = delete $self->{fh};
    $kernel->select_read( $fh );

    $kernel->call( $_[SESSION] => 'watch_aio' );

    $self->_log( v => 2, msg => 'AIO support module restarted' );
    
    return;
}

1;

__END__

=pod

=head1 NAME

Sprocket::AIO - IO::AIO support for Sprocket plugins

=head1 SYNOPSIS

  use IO::AIO;
  
  ...
  
  aio_stat( $file, $con->callback( 'stat_file' ) );

=head1 DESCRIPTION

This module handles everything needed to use IO::AIO within Sprocket plugins.
You only need to use IO::AIO and the callbacks from L<Sprocket::Connection>.

=head1 SEE ALSO

L<IO::AIO>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2007 by David Davis

See L<Sprocket> for license information.

=cut

