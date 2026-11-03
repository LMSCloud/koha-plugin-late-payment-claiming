package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::NoteText;

# Copyright 2026 (C) LMSCLoud GmbH
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# This program comes with ABSOLUTELY NO WARRANTY;

use Modern::Perl;
use utf8;

=head1 NAME

Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::NoteText

=head1 DESCRIPTION

Helper to take a text back out of a patron note (circulation note or OPAC
note) that the late payment claiming run has appended before.

The claiming run appends a text to an existing note by removing a trailing
period of the existing note and adding '. ' and the new text. A text that
ends with a period therefore loses it as soon as something is appended
afterwards. This module has no dependency on Koha so it can be tested alone.

=head2 remove

    my ( $newnote, $found ) = remove( $note, $text );

Removes one occurrence of C<$text> from C<$note>. The text is only found
if it forms a section of its own: it starts at the beginning of the note or
after a '. ' and it ends at the end of the note or before a '. '. If the
text occurs more than once, the last occurrence is removed because the claim
run always appends at the end.

Returns the changed note and 1 if the text was found, else the unchanged note
and 0.

=cut

sub remove {
    my ( $note, $text ) = @_;

    return ( $note, 0 ) if ( !defined($note) || !defined($text) );

    my $t = $text;
    $t =~ s/^\s+//;
    $t =~ s/\s+$//;
    $t =~ s/\.$//;
    return ( $note, 0 ) if ( $t eq '' );

    my $tlen = length($t);
    my $from = length($note);

    while ( $from >= 0 ) {
        my $pos = rindex( $note, $t, $from );
        last if ( $pos < 0 );

        my $before = substr( $note, 0, $pos );
        my $after  = substr( $note, $pos + $tlen );

        if ( $pos == 0 || $before =~ /\.\s+\z/ ) {
            if ( $after =~ /\A\.?\s*\z/ ) {
                # last section of the note: remove it with the separator in front of it
                $before =~ s/\.\s+\z//;
                return ( $before, 1 );
            }
            elsif ( $after =~ /\A\.\s+(.*)\z/s ) {
                # section followed by other sections: remove it with the separator behind it
                return ( $before . $1, 1 );
            }
        }
        $from = $pos - 1;
    }

    return ( $note, 0 );
}

1;
