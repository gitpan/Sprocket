#!/usr/bin/perl

use lib qw( lib );

use Sprocket qw(
    Client
    Server
    Plugin::HTTP::Server
    Plugin::HTTP::Deny
);
use POE;

my %opts = (
    LogLevel => 4,
    TimeOut => 0,
#    MaxConnections => 10000,
);

# http server
Sprocket::Server->spawn(
    %opts,
    Name => 'HTTP Server',
    ListenPort => 8002,
    ListenAddress => '0.0.0.0',
    Plugins => [
        {
            Plugin => Sprocket::Plugin::HTTP::Server->new(
                DocumentRoot => $ENV{PWD}.'/html',
                ForwardList => {
                    qr|/\.| => 'HTTP::Deny',
                }
            ),
            Priority => 0,
        },
        {
            Plugin => Sprocket::Plugin::HTTP::Deny->new(),
            Priority => 1,
        },
    ],
);

$poe_kernel->run();

1;
