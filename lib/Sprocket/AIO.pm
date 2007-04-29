package Sprocket::AIO;

use Fcntl;
use POE;
use Carp qw( croak );

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

sub import {
    return unless ( HAS_AIO );

    my $self = shift;
    my $package = caller();

    my $code = "package $package; use IO::AIO 2; sub plugin_start_aio { Sprocket::AIO->new( parent_id => shift->parent_id ); }";
    eval( $code );
    croak "could not import AIO into $package : $@"
        if ( $@ );
}

sub new {
    my $class = shift;
    return $singleton if ( $singleton );
    
    my $self = $singleton = bless({
        session_id => undef,
        @_,
        pid => $$,
    }, ref $class || $class );

    return $self unless ( HAS_AIO && $self->{parent_id} );

    POE::Session->create(
        object_states =>  [
            $self => {
                _start => '_start',
                _stop => '_stop',
                poll_cb => 'poll_cb',
                watch_aio => 'watch_aio',
                watch_fork => 'watch_fork',
                shutdown => '_shutdown',
                restart => '_restart',
            },
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
    $kernel->delay_set( watch_fork => 1 );
    
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

    # save our pid for watch_fork
    $self->{pid} = $$;
   
    return;
}

sub watch_fork {
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

    if ( $self->{pid} != $$ ) {
        $self->_log( v => 4, msg => 'fork detected, restarting aio' );
        $kernel->call( $_[SESSION] => 'restart' );
    }

    $kernel->delay_set( watch_fork => 1 );
}

sub _stop {
    $_[ OBJECT ]->_log(v => 2, msg => 'stopped');
}

sub _log {
    $poe_kernel->call( shift->{parent_id} => _log => ( call => ( caller(1) )[ 3 ], @_ ) );
}

sub shutdown {
    my $self = shift;
    return unless ( $self->{session_id} );
    return $poe_kernel->call( $self->{session_id} => shutdown => @_ );
}

sub _shutdown {
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];

    $kernel->alias_remove( "$self" );
    $kernel->alarm_remove_all();
    $kernel->select_read( delete $self->{fh} );
    $singleton = undef;

    return;
}

sub restart {
    my $self = shift;
    return unless ( $self->{session_id} );
    return $poe_kernel->call( $self->{session_id} => restart => @_ );
}

sub _restart {
    my ( $self, $kernel, $session ) = @_[ OBJECT, KERNEL, SESSION ];
    
    $kernel->select_read( delete $self->{fh} );
    $kernel->call( $session, 'watch_aio' );

    $self->_log( v => 2, msg => 'AIO support module restarted' );
    
    return;
}

1;

__END__

=pod

=head1 NAME

Sprocket::AIO - IO::AIO support for Sprocket plugins

=head1 SYNOPSIS

  package MyPlugin;

  use Sprocket qw( Plugin AIO );
  use base qw( Sprocket::Plugin );
  
  ... snip ...
  
  aio_stat( $file, $con->callback( 'stat_file' ) );

=head1 DESCRIPTION

This module handles everything needed to use IO::AIO within Sprocket plugins.
You only need to use Sprocket::AIO and the callbacks from L<Sprocket::Connection>.
Sprocket::AIO will import AIO into your package for you.

=head1 SEE ALSO

L<IO::AIO>, L<POE::Component::AIO>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2007 by David Davis

See L<Sprocket> for license information.

=cut

