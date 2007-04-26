package Sprocket;

use strict;
use warnings;

our $VERSION = '0.03';

use Carp qw( croak );
use Sprocket::Common;
use Sprocket::Connection;
use Sprocket::Session;
use Sprocket::AIO;
use Scalar::Util qw( weaken blessed );

use POE;

use overload '""' => sub { shift->as_string(); };

# weak list of all sprocket components
our @COMPONENTS;

# events sent to process_plugins
sub EVENT_NAME() { 0 }
sub SERVER()     { 1 }
sub CONNECTION() { 2 }

BEGIN {
    eval "use BSD::Resource";
    if ( $@ ) {
        eval "sub HAS_BSD_RESOURCE() { 0 }";
    } else {
        eval "sub HAS_BSD_RESOURCE() { 1 }";
    } 
}

sub import {
    my $self = shift;

    my @modules = @_;

    unshift( @modules, 'Common' );
    @modules = map { 'Sprocket::'.$_  } @modules;
   
    # XXX does this work right, TESTME
    unshift( @modules, 'POE' );

    my $package = caller();
    my @failed;

    foreach my $module ( @modules ) {
        my $code = "package $package; use $module;";
        eval( $code );
        if ( $@ ) {
            warn $@;
            push( @failed, $module );
        }
    }

    @failed and croak "could not import (" . join( ' ', @failed ) . ")";
}

our @base_states = qw(
    _start
    _default
    signals
    _shutdown
    _log
    events_received
    events_ready
    exception
    process_plugins
    sig_child
    time_out_check
    cleanup
);


sub spawn {
    my ( $class, $self, @states ) = @_;

    Sprocket::Session->create(
#       options => { trace => 1 },
        object_states => [
            $self => [ @base_states, @states ]
        ],
    );

    return $self;
}

sub as_string {
    __PACKAGE__;
}

sub new {
    my $class = shift;
    croak "$class requires an even number of parameters" if @_ % 2;
    my %opts = &adjust_params;
    
    $opts{alias} = 'sprocket' unless defined( $opts{alias} ) and length( $opts{alias} );
    $opts{time_out} = defined $opts{time_out} ? $opts{time_out} : 30;
    $opts{listen_address} ||= '0.0.0.0';
    $opts{log_level} = 4 unless( defined $opts{log_level} );
    
    my $type = delete $opts{_type}; # local / remote
    my $self = bless( {
        name => $opts{name},
        opts => \%opts, 
        heaps => {},
        connections => 0,
        plugins => {},
        plugin_pri => [],
        time_out => 10, # time_out checker
        type => $type,
    }, ref $class || $class );
    
    die 'ListenPort not set, please a port to listen to' if ( $self->isa( 'Sprocket::Server' ) && !defined( $opts{listen_port} ) );

    if ( $opts{max_connections} ) {
        if ( HAS_BSD_RESOURCE ) {
            my $ret = setrlimit( RLIMIT_NOFILE, $opts{max_connections}, $opts{max_connections} );
            unless ( defined $ret && $ret ) {
                if ( $> == 0 ) {
                    #warn "Unable to set max connections limit";
                    $self->_log(v => 1, msg => 'Unable to set max connections limit');
                } else {
                    #warn "Need to be root to increase max connections";
                    $self->_log(v => 1, msg => 'Need to be root to increase max connections');
                }
            }
        } else {
            $self->_log(v => 1, msg => 'Need BSD::Resource installed to increase max connections');
        }
    }

    push( @COMPONENTS, $self );
    weaken( $COMPONENTS[ -1 ] );
    
    return $self;
}

sub _start {
    my ( $self, $kernel ) = @_[OBJECT, KERNEL];

    Sprocket::AIO->new( parent_id => $self->{session_id} = $_[ SESSION ]->ID() );

    if ( $self->{opts}->{plugins} ) {
        foreach my $t ( @{ $self->{opts}->{plugins} } ) {
            $t = adjust_params($t);
            $self->add_plugin(
                $t->{plugin},
                $t->{priority} || 0
            );
        }
    }
    
    if ( my $ev = delete $self->{opts}->{event_manager} ) {
        eval "use $ev->{module}";
        if ($@) {
            $self->_log(v => 1, msg => "Error loading $ev->{module} : $@");
            $self->shutdown_all();
            return;
        }
        unless ( $ev->{options} && ref( $ev->{options} ) eq 'ARRAY' ) {
            $ev->{options} = [];
        }
        $self->{event_manager} = "$ev->{module}"->new(
            @{$ev->{options}},
            parent_id => $self->{session_id}
        );
    }

    $self->{aio} = Sprocket::AIO::HAS_AIO();

    $self->{time_out_id} = $kernel->alarm_set( time_out_check => time() + $self->{time_out} )
        if ( $self->{time_out} );

    $kernel->sig( DIE => 'exception' )
       if ( $self->{opts}->{use_exception_handler} );

    $kernel->sig( TSTP => 'signals' );

    $kernel->yield( '_startup' );
}

sub _default {
    my ( $self, $con, $cmd ) = @_[OBJECT, HEAP, ARG0];
    return if ( $cmd =~ m/^_(child|parent)/ );

    return $self->process_plugins( [ $cmd, $self, $con, @_[ ARG1 .. $#_ ] ] )
        if ( blessed( $con ) );
    
    $self->_log(v => 1, msg => "_default called, no handler for event $cmd [$con] (the connection for this event may be gone)");
}

sub signals {
    my ( $self, $signal_name ) = @_[OBJECT, ARG0];

    $self->_log(v => 1, msg => "Client caught SIG$signal_name");

    # to stop ctrl-c / INT
    if ($signal_name eq 'INT') {
        #$_[KERNEL]->sig_handled();
    } elsif ( $signal_name eq 'TSTP' ) {
        local $SIG{TSTP} = 'DEFAULT';
        kill( TSTP => $$ );
        $_[KERNEL]->sig_handled();
    }

    return 0;
}

sub sig_child {
    $_[KERNEL]->sig_handled();
}

sub new_connection {
    my $self = shift;
   
    my $con = Sprocket::Connection->new(
        parent_id => $self->{session_id},
        @_
    );
    
    $con->event_manager( $self->{event_manager}->{alias} )
        if ( $self->{event_manager} );

    $self->{heaps}->{ $con->ID } = $con;

    $self->{connections}++;
    
    return $con;
}

# gets a connection obj from any component
sub get_connection {
    my ( $self, $id ) = @_;
    
    if ( my $con = $self->{heaps}->{$id} ) {
        return $con;
    }
    
    foreach ( @COMPONENTS ) {
        next unless ( defined );
        if ( my $con = $_->{heaps}->{$id} ) {
            return $con;
        }
    }

    return undef;
}

sub _log {
    my ( $self, %o );
    if ( ref $_[ KERNEL ] ) {
        ( $self, %o ) = @_[ OBJECT, ARG0 .. $#_ ];
#        $o{l}++;
    } else {
        ( $self, %o ) = @_;
    }
    return unless ( $o{v} <= $self->{opts}->{log_level} );
    my $con = $self->{heap};
    my $sender = ( $con )
        ? ( $con->peer_addr ? $con->peer_addr : '' )."(".$con->ID.")" : "?";
    my $l = $o{l} ? $o{l}+1 : 1;
    my $caller = $o{call} ? $o{call} : ( caller($l) )[3] || '?';
    $caller =~ s/^POE::Component/PoCo/o;
    print STDERR '['.localtime()."][pid:$$][$self->{connections}][$caller][$sender] $o{msg}\n";
}

sub cleanup {
    my ( $self, $con_id ) = @_[ OBJECT, ARG0 ];
    my $con = $self->{heaps}->{$con_id};

    return unless ( $con );
    
    $self->process_plugins( [ $self->{type}.'_disconnected', $self, $con, 0 ] )
        unless ( defined $con->error );

    $self->cleanup_connection( $con );
}

sub cleanup_connection {
    my ( $self, $con ) = @_;

    return unless( $con );
    
    my $wheel = $con->{wheel};
    if ( $wheel ) {
        $wheel->shutdown_input();
        $wheel->shutdown_output();
    }
    
    delete $con->{wheel};
    
    $self->{connections}--;
    delete $self->{heaps}->{ $con->ID };
    
    return undef;
}
      
sub shutdown_all {
    foreach my $comp (@COMPONENTS) {
        next unless ( defined $comp );
        $comp->shutdown();
    }
}

sub shutdown {
    my $self = shift;
    $poe_kernel->call( $self->{session_id} => '_shutdown' );
}

sub _shutdown {
    my ( $self, $kernel ) = @_[ OBJECT, KERNEL ];
    foreach ( values %{$self->{heaps}} ) {
        $_->close( 1 ); # force
        $self->cleanup_connection( $_ );
    }
    $self->{heaps} = {};
    foreach ( keys %{$self->{listeners}} ) {
        $kernel->refcount_decrement( $_, __PACKAGE__ );
    }
    $kernel->sig( INT => undef );
    $kernel->sig( TSTP => undef );
    $kernel->alarm_remove_all();
    $kernel->alias_remove( $self->{opts}->{alias} )
        if ( $self->{opts}->{alias} );
    # XXX remove plugins one by one?
    delete @{$self}{qw( wheel sf )};
    # last component, shutdown aio
    my $count = 0;
    for my $i ( 0 .. $#COMPONENTS ) {
        next unless defined $COMPONENTS[ $i ];
        if ( "$COMPONENTS[ $i ]" eq "$self" ) {
            splice( @COMPONENTS, $i, 1 );
            next;
        }
        $count++;
    }
    if ( $count == 0 && $self->{aio} ) {
        Sprocket::AIO->new()->shutdown();
    }
    return undef;
}

# TODO class:accessor::fast
sub name {
    shift->{name};
}

sub events_received {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    $self->process_plugins( [ 'events_received', $self, @_[ HEAP, ARG0 .. $#_ ] ] );
}

sub events_ready {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    $self->process_plugins( [ 'events_ready', $self, @_[ HEAP, ARG0 .. $#_ ] ] );
}

sub exception {
    my ($kernel, $self, $con, $sig, $error) = @_[KERNEL, OBJECT, HEAP, ARG0, ARG1];
    $self->_log(v => 1, l => 1, msg => "plugin exception handled: ($sig) : "
        .join(' | ',map { $_.':'.$error->{$_} } keys %$error ) );
    # doesn't work?
    if ( blessed( $con ) && $con->isa( 'Sprocket::Connection' ) ) {
        $con->close( 1 );
    }
    $kernel->sig_handled();
}

sub time_out_check {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    my $time = time();
    $self->{time_out_id} = $kernel->alarm_set( time_out_check => $time + $self->{time_out} );

    foreach my $con ( values %{$self->{heaps}} ) {
        if ( my $timeout = $con->time_out() ) {
#            warn "$con timeout is $con->{time_out} ".( $con->active_time() + $timeout ). " < $time";
            if ( ( $con->active_time() + $timeout ) <  $time ) {
                $self->process_plugins( [ 'time_out', $self, $con, $time ] );
            }
        }
    }
}

sub add_plugin {
    my $self = shift;
    
    my $t = $self->{plugins};
   
    my ( $plugin, $pri ) = @_;
    my $name;
    
    if ( $plugin->can( 'name' ) ) {
        $name = $plugin->name();
    } else {
        $name = "$plugin";
    }
    
    warn "WARNING : Overwriting existing plugin '$name' (You have two plugins with the same name)"
        if ( exists( $t->{ $name } ) );

    $pri ||= 0;

    my $found = 0;
    foreach ( keys %$t ) {
        $pri == $t->{$_}->{priority} && $found++;
    }
    
    if ( $found ) {
        warn "WARNING: You have defined more than one plugin with the same priority, was this intended? plugin: $name pri: $pri";
    }

    $t->{ $name } = {
        plugin => $plugin,
        priority => $pri,
    };
    
    $plugin->parent_id( $self->{session_id} );
    
    $plugin->add_plugin( $self, $pri )
        if ( $plugin->can( 'add_plugin' ) );
    
    # recalc plugin order
    @{ $self->{plugin_pri} } = sort {
        $t->{ $a }->{priority} <=> $t->{ $b }->{priority}
    } keys %$t;

    return 1;
}

sub remove_plugin {
    my $self = shift;
    my $tr = shift;
    
    # TODO remove by name or obj
    
    my $t = $self->{plugins};
    
    my $plugin = delete $t->{ $tr };
    return 0 unless ( $plugin );
    
    $plugin->{plugin}->remove_plugin( $self, $plugin->{priority} )
        if ( $plugin->{plugin}->can( 'remove_plugin' ) );
    
    # recalc plugin_pri
    @{ $self->{plugin_pri} } = sort {
        $t->{ $a }->{priority} <=> $t->{ $b }->{priority}
    } keys %$t;
    
    return 1;
}

sub process_plugins {
    my ( $self, $args, $i ) = $_[ KERNEL ] ? @_[ OBJECT, ARG0, ARG1 ] : @_;

    return unless ( @{ $self->{plugin_pri} } );
   
    my $con = $args->[ CONNECTION ];
    $con->state( $args->[ EVENT_NAME ] );
  
    if ( my $t = $con->plugin() ) {
        return $self->{plugins}->{ $t }->{plugin}->handle_event( @$args );
    } else {
        $i ||= 0;
        if ( $#{ $self->{plugin_pri} } >= $i ) {
            return if ( $self->{plugins}->{
                $self->{plugin_pri}->[ $i ]
            }->{plugin}->handle_event( @$args ) );
        }
        $i++;
        # avoid a post
        return if ( $#{ $self->{plugin_pri} } < $i );
    }
    
    # XXX call?
    #$poe_kernel->call( $self->{session_id} => process_plugins => $args => $i );
    $poe_kernel->yield( process_plugins => $args => $i );
}

sub forward_plugin {
    my $self = shift;
    my $plug_name = shift;

    unless( exists( $self->{plugins}->{ $plug_name } ) ) {
        $self->_log( v => 4, msg => 'plugin not loaded: '.$plug_name );
        return 0;
    }
    
    # XXX 
    my $con = $self->{heap};
    $con->plugin( $plug_name );

    return $self->process_plugins( [ $con->state, $self, $con, @_ ] );
}


1;

__END__

=pod

=head1 NAME

Sprocket - A pluggable POE based Client / Server Library

=head1 SYNOPSIS

See examples

=head1 ABSTRACT

Sprocket is an POE based client server library that uses plugins similar to POE
Components.

=head1 DESCRIPTION

Sprocket uses a single session for each object/component created to increase speed
and reduce the memory footprint of your apps.  Sprocket is used in the Perl version
of Cometd L<http://cometd.com/>

=head1 NOTES

Sprocket is fully compatable with other POE Compoents.  Apps are normally written as
Sprocket plugins and paired with a L<Sprocket::Server> or L<Sprocket::Client>.

=head1 SEE ALSO

L<POE>, L<Sprocket::Connection>, L<Sprocket::Plugin>, L<Sprocket::Server>,
L<Sprocket::Client>, L<Sprocket::AIO>

=head1 AUTHOR

David Davis E<lt>xantus@cpan.orgE<gt>

=head1 RATING

Please rate this module.
L<http://cpanratings.perl.org/rate/?distribution=Sprocket>

=head1 COPYRIGHT AND LICENSE

Copyright 2006-2007 by David Davis

Artistic License

=cut

