package Sprocket::Plugin::Test;

# used for tests in t/

use Sprocket qw( Plugin );
use base 'Sprocket::Plugin';

use POE::Filter::Line;

use strict;
use warnings;

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(
        name => 'Test',
        @_
    );

    my $tpl = $self->{template};
    $self->{template} = [ (<$tpl>) ]
        if ( $tpl && ref $tpl eq 'GLOB' );
    
    die "must specify template for tests"
        unless( $self->{template} );

    return $self;
}

sub as_string {
    __PACKAGE__;
}

sub next_item {
    my $self = shift;
    
    shift @{$self->{template}};
}

# ---------------------------------------------------------
# server

sub local_connected {
    my ( $self, $server, $con, $socket ) = @_;
    
    $self->take_connection( $con );
    # POE::Filter::Stackable object:
    $con->filter->push( POE::Filter::Line->new() );
    
    $con->filter->shift(); # POE::Filter::Stream

    Test::More::pass("l - connected, starting test");
    
    my $n = $self->next_item();
    if ( $n ) {
        Test::More::pass("l - sent '$n'");
        $con->send( $n );
    } else {
        Test::More::fail("l - no test data in the template");
        kill(INT => $$);
        return;
    }

    return 1;
}

sub local_receive {
    my ( $self, $server, $con, $data ) = @_;
    
    my $n = $self->next_item();

    unless ( $n ) {
        Test::More::fail("l - data received '$data' but no matching item");
        kill(INT => $$);
        return;
    }

    if ( $data =~ m/^$n$/ ) {
        Test::More::pass("l - received valid result for '$n'");
        my $send = $self->next_item();
        if ( $send ) {
            Test::More::pass("l - sending '$send'");
            $con->send( $send );
        } else {
            Test::More::pass("l - last item in template, end of test");
            $con->close();
        }
    } else {
        Test::More::fail("l - received INVALID result for '$n' : '$data'");
        kill(INT => $$);
        return;
    }
    
    return 1;
}

sub local_disconnected {
    my ( $self, $server, $con, $error ) = @_;
    $server->shutdown();
    Test::More::pass("l - disconnected");
}

# ---------------------------------------------------------
# client

sub remote_connected {
    my ( $self, $client, $con, $socket ) = @_;

    $self->take_connection( $con );

    # POE::Filter::Stackable object:
    $con->filter->push( POE::Filter::Line->new() );
    
    $con->filter->shift(); # POE::Filter::Stream

    return 1;
}

sub remote_receive {
    my ( $self, $client, $con, $data ) = @_;
    
    my $n = $self->next_item();

    unless ( $n ) {
        Test::More::fail("r - data received '$data' but no matching item");
        kill(INT => $$);
        return;
    }

    if ( $data =~ m/^$n$/ ) {
        Test::More::pass("r - received valid result for '$n'");
        my $send = $self->next_item();
        if ( $send ) {
            Test::More::pass("r - sending '$send'");
            $con->send( $send );
        } else {
            Test::More::pass("r - last item in template, end of test");
            $con->close();
        }
    } else {
        Test::More::fail("r - received INVALID result for '$n' : '$data'");
        kill(INT => $$);
        return;
    }
    
    return 1;
}

sub remote_disconnected {
    my ( $self, $client, $con, $error ) = @_;
    Test::More::pass("r - disconnected");
    $client->shutdown();
}

sub remote_connect_timeout {
    warn "r - connect timeout";
}

sub remote_connect_error {
    warn "r - connect error";
}

sub remote_error {
    warn "r - remote error";
}

1;