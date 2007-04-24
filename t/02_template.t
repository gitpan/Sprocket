use warnings;
use strict;

use Test::More 'no_plan';

BEGIN {
    use_ok 'POE';
    use_ok 'Sprocket';
    use_ok 'Sprocket::Client';
    use_ok 'Sprocket::Server';
    use_ok 'Sprocket::Plugin::Test';
}

my %opts = (
    LogLevel => 1,
    TimeOut => 0,
);

my @template = (
    'test1',
    'test2',
    'test3',
    'test4',
);

Sprocket::Server->spawn(
    %opts,
    Name => 'Test Server',
    ListenPort => 9979,
    ListenAddress => '127.0.0.1',
    Plugins => [
        {
            plugin => Sprocket::Plugin::Test->new(
                template => [ @template ],
            ),
        },
    ],
);

Sprocket::Client->spawn(
    %opts,
    Name => 'Test Client',
    ClientList => [
        '127.0.0.1:9979',
    ],
    Plugins => [
        {
            plugin => Sprocket::Plugin::Test->new(
                template => [ @template ],
            ),
        },
    ],
);

$poe_kernel->run();
