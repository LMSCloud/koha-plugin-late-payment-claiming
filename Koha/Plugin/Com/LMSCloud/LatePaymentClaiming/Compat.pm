package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::Compat;

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

use C4::Context;

=head1 NAME

Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::Compat

=head1 DESCRIPTION

The plugin runs with the LMSCloud Koha as well as with the Koha community version.
The LMSCloud Koha has some additions that the community version does not know (a column
of the table branches, a table for overdue levels, a debit type, a template plugin).
This module tells which of them the running Koha has so that the plugin can do without them.

The answers are cached for the lifetime of the process.

=cut

my %cache;

=head2 hasTable

    Koha::Plugin::...::Compat->hasTable('overdue_issues');

=cut

sub hasTable {
    my ( $class, $table ) = @_;

    return $cache{table}->{$table} //= do {
        my ($found) = C4::Context->dbh->selectrow_array( 'SHOW TABLES LIKE ?', undef, $table );
        $found ? 1 : 0;
    };
}

=head2 hasColumn

    Koha::Plugin::...::Compat->hasColumn('branches','mobilebranch');

=cut

sub hasColumn {
    my ( $class, $table, $column ) = @_;

    return 0 if ( $table !~ /^[a-z_0-9]+$/i );
    return $cache{column}->{$table}->{$column} //= do {
        my ($found) = C4::Context->dbh->selectrow_array( "SHOW COLUMNS FROM `$table` LIKE ?", undef, $column );
        $found ? 1 : 0;
    };
}

=head2 notMobileLibraries

Search condition for Koha::Libraries that leaves out mobile stations of the LMSCloud Koha
(column branches.mobilebranch). With the community version there are no mobile stations,
so the condition is empty.

=cut

sub notMobileLibraries {
    my ($class) = @_;

    return $class->hasColumn( 'branches', 'mobilebranch' )
        ? { -or => [ mobilebranch => undef, mobilebranch => '' ] }
        : {};
}

=head2 hasDebitType

=cut

sub hasDebitType {
    my ( $class, $code ) = @_;

    return $cache{debit_type}->{$code} //= do {
        my ($found) = C4::Context->dbh->selectrow_array( 'SELECT 1 FROM account_debit_types WHERE code = ?', undef, $code );
        $found ? 1 : 0;
    };
}

=head2 patronLetters

Letters that are sent to patrons (code and name), sorted by name. This is what the LMSCloud
template plugin "Letters" provides, which the community version does not have.

=cut

sub patronLetters {
    my ($class) = @_;

    return C4::Context->dbh->selectall_arrayref(
        q{SELECT code, name
          FROM   letter
          WHERE  module IN ('circulation','members','reserves','suggestions')
          GROUP  BY code, name
          ORDER  BY name, code},
        { Slice => {} }
    );
}

1;
