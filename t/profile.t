#!/usr/bin/perl

use strict;
use warnings;

use Time::HiRes qw(time clock);
use Try::Tiny;
use Test::More;
use List::Util qw(shuffle);

BEGIN {
    try {
        require Cache::Ref::FIFO;
        require Cache::Ref::LRU;
        require Cache::Ref::CART;
    } catch {
        if ( m{^Can't locate Cache/Ref/(?:FIFO|LRU)\.pm} ) {
            plan skip_all => "Cache::Ref::FIFO and Cache::Ref::LRU required";
        } else {
            die $_;
        }
    };
}

use ok 'Cache::Profile';
use ok 'Cache::Profile::CorrelateMissTiming';

# this uses a weighted key set
my @keys = shuffle( ( map { 1 .. $_ } 1 .. 25 ), 1 .. 200 );
my %seen;
my $sigma = grep { !$seen{$_}++ } @keys;

my $size = 20;

my $p_fifo = Cache::Profile->new(
    cache => Cache::Ref::FIFO->new( size => $size ),
);

$p_fifo->set( foo => "bar" );
is( $p_fifo->get("foo"), "bar", "simple set/get" );

is( $p_fifo->hit_count, 1, "hit count" );
is( $p_fifo->miss_count, 0, "miss count" );

$p_fifo->reset;

is( $p_fifo->get("bar"), undef, "cache miss" );

is( $p_fifo->hit_count, 0, "hit count" );
is( $p_fifo->miss_count, 1, "miss count" );

$p_fifo->reset;

my $p_lru = Cache::Profile::CorrelateMissTiming->new(
    cache => Cache::Ref::LRU->new( size => $size ),
);

my $p_cart = Cache::Profile->new(
    cache => Cache::Ref::CART->new( size => $size ),
);

my @more_caches;

try {
    require CHI;
    push @more_caches, CHI->new( driver => 'Memory', datastore => {}, max_size => $size );
} catch {
    warn $_;
};

try {
    require Cache::FastMmap;
    push @more_caches, Cache::FastMmap->new(cache_size => '1k');
} catch {
    warn $_;
};

try {
    require Cache::Bounded;
    push @more_caches, Cache::Bounded->new({ interval => 5, size => $size });
} catch {
    warn $_;
};

try {
    require Cache::Memory;
    push @more_caches, Cache::Memory->new();
} catch {
    warn $_;
};

try {
    require Cache::MemoryCache;
    push @more_caches, Cache::MemoryCache->new();
} catch {
    warn $_;
};

my @more = map { Cache::Profile::CorrelateMissTiming->new( cache => $_ ) } @more_caches;

my ( $get, $set );

my $start = clock();
my $end = $start + 0.3 * ( 3 + @more );

sub _waste_time {
    my @foo;
    push @foo, [ 1 .. 100 ] for 1 .. 100;
}

my $i;
until ( (clock() > $end) and $i > @keys * 3 ) {
    my $key = $keys[rand > 0.7 ? int rand @keys : $i++ % @keys];

    foreach my $cache ( $p_fifo, $p_lru, @more ) { 
        unless ( $cache->get($key) ) {
            _waste_time();
            $cache->set( $key => rand > 0.5 ? { foo => "bar", data => [ 1 .. 10 ] } : "blahblah" );
        }
    }

    $get++;
    $p_cart->compute( $key, sub {
        $set++;
        _waste_time();
        return rand > 0.5 ? { foo => "bar", data => [ 1 .. 10 ] } : "blahblah";
    });
    
}

is( $p_cart->call_count_get, $get, "get count" );
is( $p_cart->call_count_set, $set, "set count" );

is( $p_cart->query_count, $p_fifo->call_count_get, "no multi key queries" );

my $report = $p_cart->report;

like( $report, qr/hit rate/i, "report contains 'hit rate'" );
like( $report, qr/${\ $p_cart->hit_count }/, "contains hit count" );
like( $report, qr/${\ $p_cart->query_count }/, "contains query count" );

foreach my $cache ( $p_cart, $p_lru, @more ) {
    unless  ( $cache->cache->isa("CHI::Driver") ) {
        # CHI expires too eagerly... this basically just makes sure some data
        # was actually proxied into the cache
        my $hit;
        foreach my $key ( @keys ) {
            if ( defined $cache->get($key) ) {
                $hit++;
                last;
            }
        }
        ok($hit, "at least one key in cache (" . ref($cache->cache) . ")");
    }

    cmp_ok( $p_cart->hit_rate, '>=', ( ( $size / @keys ) / 2), "hit rate bigger than minimum" );

    foreach my $method qw(get set miss) {
        cmp_ok( $cache->${\"call_count_$method"}, '>=', $sigma, "$method called enough times" );

        foreach my $measure qw(real cpu) {
            cmp_ok( $cache->${\"total_${measure}_time_${method}"}, '>=', 0.001, "some $measure time accrued for $method" );
        }
    }
}

cmp_ok( $p_cart->hit_rate, '>', $p_lru->hit_rate, "CART beats LRU" );
cmp_ok( $p_lru->hit_rate,  '>', $p_fifo->hit_rate, "LRU beats FIFO" );

done_testing;

# ex: set sw=4 et:
