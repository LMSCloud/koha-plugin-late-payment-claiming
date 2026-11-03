#!/usr/bin/perl

use Modern::Perl;
use utf8;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/..";

use_ok('Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::NoteText');

sub rm {
    return Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::NoteText::remove(@_);
}

my @cases = (
    # note,                          text,         expected note,        found, name
    [ 'A',                           'A',          '',                   1, 'note is exactly the text' ],
    [ 'Info. A',                     'A',          'Info',               1, 'text appended at the end' ],
    [ 'A. Info',                     'A',          'Info',               1, 'text at the start' ],
    [ 'Info. A. B',                  'A',          'Info. B',            1, 'text in the middle' ],
    [ 'Info. A. A',                  'A',          'Info. A',            1, 'text twice: only the last one' ],
    [ 'Info. A',                     'A.',         'Info',               1, 'text with period, found at the end' ],
    [ 'Info. A.',                    'A.',         'Info',               1, 'text with period kept at the end of the note' ],
    [ 'Info. A. B',                  'A.',         'Info. B',            1, 'text with period lost its period when something was appended' ],
    [ '1. Mahnung vom 03.11.2026',   '1. Mahnung vom 03.11.2026', '',    1, 'text contains ". " and dots' ],
    [ 'Info. 1. Mahnung vom 03.11.2026. 2. Mahnung vom 10.11.2026', '1. Mahnung vom 03.11.2026', 'Info. 2. Mahnung vom 10.11.2026', 1, 'text with ". " inside, in the middle' ],
    [ 'Info A',                      'A',          'Info A',             0, 'text only part of a sentence: not found' ],
    [ 'Info. AB',                    'A',          'Info. AB',           0, 'text only part of a section: not found' ],
    [ 'Info. BA',                    'A',          'Info. BA',           0, 'text at the end of a word: not found' ],
    [ 'Etwas anderes',               'A',          'Etwas anderes',      0, 'text not in the note' ],
    [ 'Info. A',                     '',           'Info. A',            0, 'empty text' ],
    [ 'Info. A',                     ' A ',        'Info',               1, 'whitespace around the text is ignored' ],
    [ '',                            'A',          '',                   0, 'empty note' ],
    [ undef,                         'A',          undef,                0, 'undefined note' ],
    [ 'Info. A',                     undef,        'Info. A',            0, 'undefined text' ],
    [ 'Ä-Hinweis. Über Mahnung',     'Über Mahnung', 'Ä-Hinweis',        1, 'umlauts' ],
);

foreach my $case (@cases) {
    my ( $note, $text, $expected, $found, $name ) = @$case;
    my ( $result, $isfound ) = rm( $note, $text );
    is( $result,  $expected, "$name: note" );
    is( $isfound, $found,    "$name: found" );
}

# remove two texts one after the other, newest first, like the claiming run
{
    my $note = 'Info. 1. Mahnung vom 03.11.2026. 2. Mahnung vom 10.11.2026';
    my ( $n, $f1 ) = rm( $note, '2. Mahnung vom 10.11.2026' );
    my ( $n2, $f2 ) = rm( $n, '1. Mahnung vom 03.11.2026' );
    is( $n2, 'Info', 'two texts removed one after the other' );
    ok( $f1 && $f2, 'both found' );
}

done_testing();
