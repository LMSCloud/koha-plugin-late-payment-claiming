package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfigurationController;

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

use JSON;
use Data::Dumper;
use Try::Tiny qw( catch try );

use Mojo::Base 'Mojolicious::Controller';
use Koha::Patrons;
use Koha::DateUtils qw( dt_from_string );

use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration;


sub listConfigurations {
    my $c = shift->openapi->valid_input or return;

    my $config = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration->new();
    my $response = $config->getConfigurationList();
    
    return $c->render(status  => 200, openapi => $response );
}

sub getConfiguration {
    my $c = shift->openapi->valid_input or return;

    my $library_id = $c->validation->output->{'library_id'};
    my $category_id = $c->validation->output->{'category_id'};
    
    my $config = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration->new();
    my $response = $config->getConfiguration($library_id,$category_id);
    
    return $c->render(status  => 200, openapi => $response );
}

sub removeConfiguration {
    my $c = shift->openapi->valid_input or return;

    my $library_id = $c->validation->output->{'library_id'};
    my $category_id = $c->validation->output->{'category_id'};
    
    my $config = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration->new();
    my $result = $config->removeConfiguration($library_id,$category_id);
    
    return $c->render(status  => 200, openapi => { detail => "Configuration succesful removed." } );
}

sub saveConfiguration {
    my $c = shift->openapi->valid_input or return;

    my $library_id = $c->validation->output->{'library_id'};
    my $category_id = $c->validation->output->{'category_id'};
    
    my $body = $c->validation->param('body');
    
    my $config = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration->new();
    
    return try {
        if ( my $saved_config = $config->saveConfiguration($library_id,$category_id,$body) ) {
            return $c->render(status  => 200, openapi => $saved_config );
        }
    }
    catch {
        $c->unhandled_exception($_);
    }
}


1;
