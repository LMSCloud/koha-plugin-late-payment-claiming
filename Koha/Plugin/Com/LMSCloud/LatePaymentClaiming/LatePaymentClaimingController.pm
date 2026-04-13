package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingController;

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

use JSON;
use Data::Dumper;
use Try::Tiny qw( catch try );

use Mojo::Base 'Mojolicious::Controller';
use Koha::Patrons;
use Koha::DateUtils qw( dt_from_string );

use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::PatronSearch;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::CheckExecution;

sub searchPatrons {
    my $c = shift->openapi->valid_input or return;
    
    return try {
        
        my $body = $c->validation->param('body');
        
        my $search = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::PatronSearch->new();
        
        my $draw = undef;
        for (my $i=0; $i < @{$body->{search_options}};$i++) {
            if ( $body->{search_options}->[$i]->{name} eq 'draw' ) {
                $draw = $body->{search_options}->[$i]->{value};
            }
        }
        my $filter = '';
        for (my $i=0; $i < @{$body->{search_options}};$i++) {
            if ( $body->{search_options}->[$i]->{name} eq 'search' ) {
                $filter = $body->{search_options}->[$i]->{value}->{value};
            }
        }
        
        my $patron_result_set = $search->search(
                                            $body->{library_id},
                                            $body->{category_id},
                                            $body->{level},
                                            $body->{patron_selection},
                                            $filter
                                        );

        my $patron_rs = $c->objects->search_rs( $patron_result_set );
        
        # Add pagination headers
        $c->add_pagination_headers();
    
        my $patrons = $c->objects->to_api($patron_rs);
        
        return $c->render(
            status  => 200,
            openapi => { data => $patrons, recordsFiltered => ($patron_rs->is_paged ? $patron_rs->pager->total_entries : $patron_rs->count), recordsTotal => ($patron_rs->is_paged ? $patron_rs->pager->total_entries : $patron_rs->count), draw => $draw }
        );
    
    }
    catch {
        $c->unhandled_exception($_);
    };
}

sub getLatePaymentClaims {
    my $c = shift->openapi->valid_input or return;
    
    my $param = $c->validation->output;
    my $lpc = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming->new();
    
    my $parameters = {
                         claim_id => $param->{claim_id},
                         cardnumber => $param->{cardnumber},
                         patron => $param->{patron},
                         library => $param->{library},
                         category => $param->{category},
                         creationdate_from => $param->{creationdate_from},
                         creationdate_to => $param->{creationdate_to},
                         level => $param->{level},
                         status => $param->{status},
                         comment => $param->{comment}
                     };
    my $result = $lpc->getLatePaymentClaims($parameters,$param->{_per_page},$param->{_page},$param->{_order_by});
    
    my $resultClaims = [];
    
    foreach my $claim( @{$result->{late_payment_claims}} ) {
        push @$resultClaims, databaseClaim2Api($claim);
    }
    
    return $c->render(
        status  => 200,
        openapi => { data => $resultClaims, recordsFiltered => $result->{full_count}, recordsTotal => $result->{full_count}, draw => $param->{draw} }
    );
}

sub getLatePaymentClaimHistory {
    my $c = shift->openapi->valid_input or return;
    
    my $param = $c->validation->output;
    my $lpc = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming->new();
    
    my $parameters = {
                         claim_id => $param->{claim_id},
                         cardnumber => $param->{cardnumber},
                         patron_id => $param->{patron_id},
                         patron => $param->{patron},
                         library => $param->{library},
                         category => $param->{category},
                         creationdate_from => $param->{creationdate_from},
                         creationdate_to => $param->{creationdate_to},
                         level => $param->{level},
                         status => $param->{status},
                         action => $param->{action},
                         action_level => $param->{action_level},
                         action_comment => $param->{action_comment},
                         action_account_balance_from => $param->{action_account_balance_from},
                         action_account_balance_to => $param->{action_account_balance_to},
                         action_timestamp_from => $param->{action_timestamp_from},
                         action_timestamp_to => $param->{action_timestamp_to},
                         actionIdList => $param->{actionIdList}
                     };
    my $result = $lpc->getLatePaymentClaimHistory($parameters,$param->{_per_page},$param->{_page},$param->{_order_by},$param->{_search});
    
    return $c->render(
        status  => 200,
        openapi => { data => $result->{late_payment_claims}, recordsFiltered => $result->{full_count}, recordsTotal => $result->{full_count}, draw => $param->{draw} }
    );
}

sub getLatePaymentClaimComment {
    my $c = shift->openapi->valid_input or return;
    
    my $claim_id = $c->validation->output->{'claim_id'};
    my $lpc = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming->new();
    
    my $comment = $lpc->getLatePaymentClaimComment($claim_id);
    
    return $c->render(
        status  => 200,
        openapi => { comment => $comment }
    );
}

sub updateLatePaymentClaimComment {
    my $c = shift->openapi->valid_input or return;
    
    my $param = $c->validation->output;
    my $claim_id = $param->{'claim_id'};
    my $body = $c->validation->param('body');

    my $lpc = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming->new();

    my $claim = $lpc->updateLatePaymentClaim($claim_id,$body);
    
    return $c->render(
        status  => 200,
        openapi => databaseClaim2Api($claim)
    );
}

sub insertLatePaymentClaim {
    my $c = shift->openapi->valid_input or return;
    
    my $param = $c->validation->output;
    my $body = $c->validation->param('body');
    
    my $cardnumber = $body->{cardnumber};
    my $level = $body->{level};
    my $comment = $body->{comment};
    
    my $lpc = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming->new();

    my $result = {};
    
    $result = $lpc->insertLatePaymentClaim($cardnumber,$level,$comment);
    
    if ( !exists($result->{error}) && $result->{claim} ) {
        return $c->render(
            status  => 200,
            openapi => databaseClaim2Api($result->{claim})
        );
    }
    
    return $c->render(
            status  => 400,
            openapi => { detail => $result->{error} }
        );
}

sub checkExecutionFrequency {
    my $c = shift->openapi->valid_input or return;
    
    my $param = $c->validation->output;
    my $day = $param->{'day'};
    my $month = $param->{'month'};
    my $weekday = $param->{'weekday'};
    
    my $executionChecker = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::CheckExecution->new();
    
    my $checkResult = $executionChecker->checkCronEntry($day,$month,$weekday);
    
    return $c->render(
        status  => 200,
        openapi => $checkResult
    );
}

sub getNextExecutionDays {
    my $c = shift->openapi->valid_input or return;
    
    my $param = $c->validation->output;
    my $day = $param->{'day'};
    my $month = $param->{'month'};
    my $weekday = $param->{'weekday'};
    my $startDate =  eval { dt_from_string( $param->{'startDate'} ); };
    my $execOnClosingDays = $param->{'execOnClosingDays'};
    my $execOnClosingDayLibrary = $param->{'execOnClosingDayLibrary'};
    my $count = (($param->{'count'} || 0) + 0) || 20;
    
    my $executionChecker = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::CheckExecution->new();
    
    my $nextExecutionDays = $executionChecker->getNextDays($day,$month,$weekday,$startDate,$execOnClosingDays,$execOnClosingDayLibrary,$count);
    my $dates = [];
    
    foreach my $date(@$nextExecutionDays) {
        push @$dates, $date->ymd();
    }
    
    return $c->render(
        status  => 200,
        openapi => $dates
    );
}

sub databaseClaim2Api {
    my $claim = shift;
    
    return {
                claim_id => $claim->{id},
                patron_id => $claim->{borrowernumber},
                cardnumber => $claim->{cardnumber},
                surname => $claim->{surname},
                firstname => $claim->{firstname},
                middle_name => $claim->{middle_name},
                title => $claim->{title},
                other_name => $claim->{othernames},
                initials => $claim->{initials},
                pronouns => $claim->{pronouns},
                street_number => $claim->{streetnumber},
                street_type => $claim->{streettype},
                address => $claim->{address},
                address2 => $claim->{address2},
                city => $claim->{city},
                state => $claim->{state},
                postal_code => $claim->{zipcode},
                country => $claim->{country},
                email => $claim->{email},
                phone => $claim->{phone},
                mobile => $claim->{mobile},
                fax => $claim->{fax},
                secondary_email => $claim->{emailpro},
                secondary_phone => $claim->{phonepro},
                library_id => $claim->{branchcode},
                category_id => $claim->{categorycode},
                creationdate => $claim->{creationdate},
                level => $claim->{level},
                status => $claim->{status},
                comment => $claim->{comment},
                account_balance => $claim->{account_balance}
            };
}



1;

