package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming;

# Koha is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License, or
# (at your option) any later version.
#
# Koha is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Koha; if not, see <http://www.gnu.org/licenses>.

use Modern::Perl;

use base qw(Koha::Plugins::Base);
use utf8;
use JSON qw( decode_json );
use Try::Tiny;
use Cwd qw(abs_path);

use C4::Context;
use C4::Auth qw( get_template_and_user );

use Koha::DateUtils qw( dt_from_string output_pref );
use Koha::Patrons;

our $VERSION = "0.1.0";
our $MINIMUM_VERSION = "22.11";

our $metadata = {
    name            => 'Late Payment Claiming',
    author          => 'LMSCloud GmbH',
    date_authored   => '2026-02-15',
    date_updated    => "2026-01-19",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Koha plugin to claim outstanding fees with claim messages or and configurable actions',
};

sub new {
    my ( $class, $args ) = @_;

    $args->{'metadata'} = $metadata;
    $args->{'metadata'}->{'class'} = $class;

    my $self = $class->SUPER::new($args);

    $self->{cgi} = CGI->new();

    return $self;
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};

    unless ( $cgi->param('save') ) {
        my $template = $self->get_template({ file => 'configure.tt' });

        $template->param(
            claim_config                      => $self->retrieve_data('claim_config'),
            batch_active                      => $self->retrieve_data('batch_active'),
            last_upgraded                     => $self->retrieve_data('last_upgraded'),
        );

        $self->output_html( $template->output() );
        exit;
    }
    $self->store_data(
        {
            claim_config                      => scalar $cgi->param('claim_config'),
            batch_active                      => scalar $cgi->param('batch_active'),
        }
    );
    $self->go_home();
    exit;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install() {
    my ( $self, $args ) = @_;

    #    my $table = $self->get_qualified_table_name('configuration');
    #
    #    return C4::Context->dbh->do( "
    #        CREATE TABLE IF NOT EXISTS $table (
    #            `apikey` VARCHAR( 255 ) NOT NULL DEFAULT ''
    #        ) ENGINE = INNODB;
    #    " );

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );
    
    return 1;
}

## This is the 'upgrade' method. It will be triggered when a newer version of a
## plugin is installed over an existing older version of a plugin
sub upgrade {
    my ( $self, $args ) = @_;

    my $dt = dt_from_string();
    $self->store_data( { last_upgraded => $dt->ymd('-') . ' ' . $dt->hms(':') } );

    return 1;
}

## This method will be run just before the plugin files are deleted
## when a plugin is uninstalled. It is good practice to clean up
## after ourselves!
sub uninstall() {
    my ( $self, $args ) = @_;

    #    my $table = $self->get_qualified_table_name('configuration');
    #
    #    return C4::Context->dbh->do("DROP TABLE IF EXISTS $table");
}

sub api_namespace {
    my ($self) = @_;

    return 'latepaymentclaiming';
}

1;
