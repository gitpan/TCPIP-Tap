use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'TCPIP::Tap',
    AUTHOR           => q{Ben AVELING <bena.aveling at optusnet.com.au>},
    VERSION_FROM     => 'lib/TCPIP/Tap.pm',
    ABSTRACT_FROM    => 'lib/TCPIP/Tap.pm',
    LICENSE          => 'Artistic_2_0',
    PL_FILES         => {},
    MIN_PERL_VERSION => 5.006,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::More' => 0,
    },
    PREREQ_PM => {
        #'ABC'              => 1.6,
        #'Foo::Bar::Module' => 5.0401,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'TCPIP-Tap-*' },
);
