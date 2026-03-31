package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming;

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
use Data::Dumper;
use Clone 'clone';
use Try::Tiny qw(try catch);
use JSON;

use C4::Context;
use C4::Scrubber;

use Koha::Database;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::PatronSearch;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::BanActions;

sub new {
    my ( $class, $args ) = @_;

    my $self  = {};
    bless $self, $class;
    
    $self->{config} = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration->new();
    
    my $configurations = $self->{config}->getConfigurationList();
    my $noclaimConfigs = {};
    
    foreach my $configuration(@$configurations) {
        $configuration->{configdata} = $self->{config}->getConfiguration($configuration->{library_id},$configuration->{category_id});
        if ( $configuration->{levels_defined} == 0 ) {
            $noclaimConfigs->{$configuration->{library_id}."\t".$configuration->{category_id}} = 1;
        }
    }
    
    $self->{configurations} = $configurations;
    $self->{noclaimConfiguration} = $noclaimConfigs;

    return $self;
}

sub isNoClaimConfig {
    my $self = shift;
    my $library_id = shift;
    my $category_id = shift;
    
    if ( exists($self->{noclaimConfiguration}->{$library_id."\t".$category_id}) ) {
        return 1;
    }
    return 0;
}

sub getClaimPatrons {
    my $self = shift;
    my $configurations = shift;
    
    my $patronSearch = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::PatronSearch->new();
    
    my $claimPatrons = {};
    
    my $dbh = C4::Context->dbh;
    my $sth = $dbh->prepare("SELECT id,level,state,branchcode,categorycode FROM lmsc_late_payment_claim WHERE borrowernumber = ? and state <> 'closed'");
    
    # check each configuration
    foreach my $configuration(@$configurations) {
        if (! $self->isNoClaimConfig($configuration->{library_id},$configuration->{category_id}) ) {
            # check each level configuration
            foreach my $levelConfiguration(@{$configuration->{configdata}->{level_configuration}}) {
                # check each only levels >= 1 and where patron_selections exists
                next if ( $levelConfiguration->{level} < 1 || scalar(@{$levelConfiguration->{patron_selections}}) == 0 );
                # check each patron selection
                foreach my $patronSelection( @{$levelConfiguration->{patron_selections}} ) {
                    my $patrons = $patronSearch->getPatronList($configuration->{library_id},$configuration->{category_id},$levelConfiguration->{level},$patronSelection);
                    print scalar(@$patrons), " patrons found\n";
                    foreach my $patron(@$patrons) {
                        # check whether the patron already exists
                        next if ( exists($claimPatrons->{$patron->{patron_id}}) );
                        # check whether the patron belongs to a no claim configuration
                        next if ( $self->isNoClaimConfig( $patron->{library_id}, $patron->{category_id} ) );
                        # check whether this is the appropriate level for this patron
                        # means:
                        #   - patron has not reached this or a higher level
                        #   - if the level is > 1, check whether the patron has reached the level below
                        #   - if all applies, check whether the late payment claim is paused
                        #   - if there is a state paused or open and the configuration level is 1
                        #   - if the state is not open
                        $sth->execute($patron->{patron_id});
                        my $claim_id = undef;
                        if ( my ($id,$level,$state,$branchcode,$categorycode) = $sth->fetchrow_array ) {
                            next if ($level >= $levelConfiguration->{level});
                            next if ($levelConfiguration->{level} > 1 && ($level+1) != $levelConfiguration->{level} );
                            next if ($levelConfiguration->{level} == 1);
                            next if ($state eq 'paused');
                            $claim_id = $id;
                        }
                        $claimPatrons->{$patron->{patron_id}} = {
                                                                    claim_id => $claim_id,
                                                                    level => $levelConfiguration->{level},
                                                                    library_id => $patron->{library_id},
                                                                    category_id => $patron->{category_id},
                                                                    patron_selection => $patronSelection,
                                                                    ban_actions => $levelConfiguration->{ban_actions}
                                                                 };
                        print $configuration->{library_id}," ",$configuration->{category_id}," ",$levelConfiguration->{level}," ",$patron->{patron_id},"\n";
                    }
                    print scalar(keys %$claimPatrons), " patrons remain\n";
                }
            }
        }
    }
    return $claimPatrons;
}

sub claimPatronsOfAllConfigurations {
    my $self = shift;
    
    my $configurations = clone($self->{configurations});
    my $claimPatrons = $self->getClaimPatrons($configurations);
    
    my $dbh = C4::Context->dbh;
    my $json = JSON->new->allow_nonref;
    
    my $doBans = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::BanActions->new();
    
    foreach my $patron_id(sort { $claimPatrons->{$a}->{level} <=> $claimPatrons->{$b}->{level} } keys %$claimPatrons) {
        my $claimPatron = $claimPatrons->{$patron_id};

        if ( $claimPatron->{claim_id} ) {
            $dbh->do("UPDATE lmsc_late_payment_claim SET branchcode = ?, categorycode = ?, level = ? WHERE id = ?",
                        undef,
                        $claimPatron->{library_id},
                        $claimPatron->{category_id},
                        $claimPatron->{level},
                        $claimPatron->{claim_id});
        }
        else {
            $dbh->do("INSERT INTO lmsc_late_payment_claim (borrowernumber, branchcode, categorycode, creationdate, level, state) VALUES (?,?,?,now(),?,?)",
                        undef,
                        $patron_id,
                        $claimPatron->{library_id},
                        $claimPatron->{category_id},
                        $claimPatron->{level},
                        'open');
            my $claim_id = $dbh->{mysql_insertid};
            $claimPatrons->{claim_id} = $claim_id;
        }
        
        my ($amountoutstanding)  = $dbh->selectrow_array("SELECT SUM(amountoutstanding) FROM accountlines WHERE borrowernumber = ?", undef, $patron_id);

        $dbh->do("INSERT INTO lmsc_late_payment_claim_history (claim_id, action, level, amountoutstanding, patron_selections, ban_actions) VALUES (?,?,?,?,?,?)",
                    undef,
                    $claimPatrons->{claim_id},
                    'claimed',
                    $claimPatron->{level},
                    $amountoutstanding,
                    $json->encode( $claimPatron->{patron_selection} ),
                    $json->encode( $claimPatron->{ban_actions} ));
        
        $doBans->executeBanActions($patron_id,$claimPatrons->{claim_id},$claimPatron->{level},$claimPatron->{ban_actions});
    }
}

sub getLatePaymentClaims {
    my $self = shift;
    my $parameters = shift;
    my $page_count = shift;
    my $page = shift;
    my $orderBy = shift;
    
    # print STDERR "getLatePaymentClaims: " . Dumper($parameters);
    
    my $dbh = C4::Context->dbh;
    my @params;
    my @where;
    
    if ( $parameters->{claim_id} ) {
        push @where, "lpc.id = ?";
        push @params, $parameters->{claim_id};
    }
    if ( $parameters->{cardnumber} ) {
        push @where, "b.cardnumber LIKE ?";
        push @params, '%' . $parameters->{cardnumber} . '%';
    }
    if ( $parameters->{patron} ) {
        my $sPatron = '%' . $parameters->{patron} . '%';
        push @where, "(b.surname LIKE ? OR b.firstname LIKE ? OR b.middle_name LIKE ? OR b.othernames LIKE ? OR b.address LIKE ? OR b.address2 LIKE ? OR b.city LIKE ? OR b.zipcode LIKE ? OR b.country LIKE ?)";
        push @params,          $sPatron,             $sPatron,               $sPatron,             $sPatron,            $sPatron,            $sPatron,        $sPatron,           $sPatron,           $sPatron;
    }
    if ( $parameters->{library} ) {
        push @where, "b.branchcode = ?";
        push @params, $parameters->{library};
    }
    if ( $parameters->{category} ) {
        push @where, "b.categorycode = ?";
        push @params, $parameters->{category};
    }
    if ( $parameters->{creationdate_from} ) {
        push @where, "lpc.creationdate >= ?";
        push @params, $parameters->{creationdate_from};
    }
    if ( $parameters->{creationdate_to} ) {
        push @where, "lpc.creationdate <= ?";
        push @params, $parameters->{creationdate_to};
    }
    if ( $parameters->{level} ) {
        push @where, "lpc.level = ?";
        push @params, $parameters->{level};
    }
    if ( $parameters->{status} ) {
        push @where, "lpc.state = ?";
        push @params, $parameters->{status};
    }
    if ( $parameters->{comment} ) {
        push @where, "lpc.comment LIKE ?";
        push @params, '%' . $parameters->{comment} . '%';
    }
    my $sqlcount = "SELECT count(*) FROM lmsc_late_payment_claim lpc JOIN borrowers b ON (lpc.borrowernumber = b.borrowernumber)";
    my $sqlfetch = q{
                        SELECT  lpc.*,
                                lpc.state AS status,
                                b.*,
                                (SELECT SUM(amountoutstanding) FROM accountlines a WHERE a.borrowernumber=lpc.borrowernumber) AS account_balance,
                                br.branchname AS branchname,
                                cat.description AS categoryname
                        FROM    lmsc_late_payment_claim lpc 
                                JOIN borrowers b ON (lpc.borrowernumber = b.borrowernumber)
                                JOIN branches br ON (b.branchcode = br.branchcode) 
                                JOIN categories cat ON (b.categorycode = cat.categorycode)
                    };
    my $where = join(" AND ", @where);
    $sqlcount .= " WHERE " . $where if ($where);
    $sqlfetch .= " WHERE " . $where if ($where);

    my ($count) = $dbh->selectrow_array($sqlcount,undef,@params);
    
    # print STDERR "getLatePaymentClaims orderBy: $orderBy\n";
    if ( $orderBy ) {
        my @order;
        foreach my $oField(split(/,/,$orderBy)) {
            if ( $oField =~ /^([-+])(.+)$/ ) {
                my $sdirection = $1 eq '-' ? 'DESC' : 'ASC';
                my $sfield = $2;
                if    ( $sfield eq 'claim_id')        { push @order, "lpc.id $sdirection" }
                elsif ( $sfield eq 'cardnumber')      { push @order, "b.cardnumber $sdirection" }
                elsif ( $sfield eq 'patron')          { push @order, "b.surname $sdirection, b.firstname $sdirection, b.middle_name $sdirection, b.othernames $sdirection" }
                elsif ( $sfield eq 'library')         { push @order, "branchname $sdirection" }
                elsif ( $sfield eq 'category')        { push @order, "categoryname $sdirection" }
                elsif ( $sfield eq 'creationdate')    { push @order, "creationdate $sdirection" }
                elsif ( $sfield eq 'level')           { push @order, "lpc.level $sdirection" }
                elsif ( $sfield eq 'status')          { push @order, "lpc.state $sdirection" }
                elsif ( $sfield eq 'comment')         { push @order, "lpc.comment $sdirection" }
                elsif ( $sfield eq 'account_balance') { push @order, "account_balance $sdirection" }
            }
        }
        if ( scalar(@order) ) {
            $sqlfetch .= " ORDER BY " . join(", ",@order);
        }
    }
    
    if ( $page_count ) {
        $sqlfetch .= " LIMIT ";
        $sqlfetch .= (($page-1) * $page_count) . ',';
        $sqlfetch .= $page_count;
    }
    
    # print STDERR "getLatePaymentClaims SQL: $sqlfetch\n with params: " . join(", ",@params) ."\n";
    
    my $sth = $dbh->prepare($sqlfetch);
    $sth->execute(@params);
    
    my $claims = [];
    while ( my $claim = $sth->fetchrow_hashref ) {
        push @$claims, $claim;
    }
    
    return { late_payment_claims => $claims, count => scalar(@$claims), full_count => $count, page => $page, page_count => $page_count};
}

sub getLatePaymentClaimComment {
    my $self = shift;
    my $claim_id = shift;
    
    return if (! $claim_id);

    my $dbh = C4::Context->dbh;
    my ($comment) = $dbh->selectrow_array("SELECT comment FROM lmsc_late_payment_claim WHERE id = ?",undef,$claim_id);
    
    return $comment;
}

sub updateLatePaymentClaim {
    my $self = shift;
    my $claim_id = shift;
    my $claim = shift;
    
    return if (! $claim_id);

    my $dbh = C4::Context->dbh;
    
    my @fields;
    my @data;
    
    my $scrubber = C4::Scrubber->new();
    my $action = $scrubber->scrub($claim->{action});
    my $comment;
    
    foreach my $field(keys %$claim) {
        if ( $field eq 'comment' ) {
            $comment = $claim->{$field};
            $comment = $scrubber->scrub($comment) if ($comment);
            if ( $comment ) {
                push @fields,"$field = ?";
                push @data,$comment;
            } else {
                push @fields,"$field = NULL";
                $comment = '';
            }
        }
        elsif ( $field eq 'status' ) {
            my $value = $claim->{$field};
            $value = $scrubber->scrub($value) if ($value);
            if ( $value =~ /^(open|paused|closed)$/ ) {
                push @fields,"state = ?";
                push @data,$value;
            }
        }
    }
    
    if ( scalar(@fields) && $action && $action =~ /^(comment|open|pause|close|reopen)$/) {
        my $setvalues = join(", ",@fields);
        push @data,$claim_id;
        
        $dbh->do("UPDATE lmsc_late_payment_claim SET " . $setvalues . " WHERE id = ?", undef, @data);
    }
    
    # SELECT the changed late claim with additional data
    my $sql = "SELECT lpc.*,lpc.state AS status,b.*,(SELECT SUM(amountoutstanding) FROM accountlines a WHERE a.borrowernumber=lpc.borrowernumber) AS account_balance FROM lmsc_late_payment_claim lpc JOIN borrowers b ON (lpc.borrowernumber = b.borrowernumber) WHERE lpc.id = ?";
    my $sth = $dbh->prepare($sql);
    $sth->execute($claim_id);
    
    my $updatedClaim = $sth->fetchrow_hashref;
    
    if ( scalar(@fields) && $action && $action =~ /^(comment|open|pause|close|reopen)$/) {
        $dbh->do("INSERT INTO lmsc_late_payment_claim_history (claim_id,action,level,comment,amountoutstanding) VALUES (?,?,?,?,?)",undef,$claim_id,$action,$updatedClaim->{level},$comment,$updatedClaim->{account_balance});
    }
    
    return $updatedClaim;
}

sub getLatePaymentClaimHistory {
    my $self = shift;
    my $parameters = shift;
    my $page_count = shift;
    my $page = shift;
    my $orderBy = shift;
    my $searchAll = shift;
    
    my $dbh = C4::Context->dbh;
    my $json = JSON->new->allow_nonref;
    my @params;
    my @where;
    
    if ( $parameters->{claim_id} ) {
        push @where, "lpc.id = ?";
        push @params, $parameters->{claim_id};
    }
    if ( $parameters->{cardnumber} ) {
        push @where, "b.cardnumber LIKE ?";
        push @params, '%' . $parameters->{cardnumber} . '%';
    }
    if ( $parameters->{patron_id} ) {
        push @where, "b.borrowernumber = ?";
        push @params, $parameters->{borrowernumber};
    }
    if ( $parameters->{patron} || $parameters->{surname} ) {
        my $sPatron = '%' . $parameters->{patron} . '%';
        push @where, "(b.surname LIKE ? OR b.firstname LIKE ?)";
        push @params, $sPatron, $sPatron;
    }
    if ( $parameters->{library} ) {
        push @where, "b.branchcode = ?";
        push @params, $parameters->{library};
    }
    if ( $parameters->{category} ) {
        push @where, "b.categorycode = ?";
        push @params, $parameters->{category};
    }
    if ( $parameters->{creationdate_from} ) {
        push @where, "lpc.creationdate >= ?";
        push @params, $parameters->{creationdate_from};
    }
    if ( $parameters->{creationdate_to} ) {
        push @where, "lpc.creationdate <= ?";
        push @params, $parameters->{creationdate_to};
    }
    if ( $parameters->{level} ) {
        push @where, "lpc.level = ?";
        push @params, $parameters->{level};
    }
    if ( $parameters->{status} ) {
        push @where, "lpc.state = ?";
        push @params, $parameters->{status};
    }
    if ( $parameters->{action} ) {
        push @where, "hist.action = ?";
        push @params, $parameters->{action};
    }
    if ( $parameters->{action_level} ) {
        push @where, "hist.level = ?";
        push @params, $parameters->{action_level};
    }
    if ( $parameters->{action_comment} ) {
        push @where, "hist.comment LIKE ?";
        push @params, '%' . $parameters->{action_comment} . '%';
    }
    if ( $parameters->{action_account_balance_from} ) {
        push @where, "IFNULL(hist.amountoutstanding,0.0) >= ?";
        push @params, $parameters->{action_account_balance_from};
    }
    if ( $parameters->{action_account_balance_to} ) {
        push @where, "IFNULL(hist.amountoutstanding,0.0) <= ?";
        push @params, $parameters->{action_account_balance_to};
    }
    if ( $parameters->{action_timestamp_from} ) {
        push @where, "DATE(hist.timestamp) >= ?";
        push @params, $parameters->{action_timestamp_from};
    }
    if ( $parameters->{action_timestamp_to} ) {
        push @where, "DATE(hist.timestamp) <= ?";
        push @params, $parameters->{action_timestamp_to};
    }
    if ( $searchAll ) {
        my $searchAllTrunc = '%' . $searchAll . '%';
        push @where, "(lpc.id = ? OR b.cardnumber LIKE ? OR b.borrowernumber = ? OR b.surname LIKE ? OR b.firstname LIKE ? OR b.middle_name LIKE ? OR b.title LIKE ? OR b.othernames LIKE ? OR b.branchcode = ? OR br.branchname LIKE ? OR b.categorycode = ? OR cat.description LIKE ? OR lpc.creationdate = ? OR lpc.level = ? OR lpc.state = ? OR hist.action = ? OR hist.comment LIKE ? OR hist.timestamp = ?)";
        push @params, $searchAll,    $searchAllTrunc,       $searchAll,             $searchAllTrunc,    $searchAllTrunc,      $searchAllTrunc,        $searchAllTrunc,  $searchAllTrunc,       $searchAll,         $searchAllTrunc,        $searchAll,           $searchAllTrunc,          $searchAll,             $searchAll,      $searchAll,      $searchAll,        $searchAllTrunc,       $searchAll;
    }
    
    my $sqlcount = q{
                        SELECT count(*) 
                        FROM   lmsc_late_payment_claim_history hist
                               JOIN lmsc_late_payment_claim lpc ON (lpc.id = hist.claim_id)
                               JOIN borrowers b ON (lpc.borrowernumber = b.borrowernumber)
                               LEFT JOIN borrowers m ON (hist.manager_id = m.borrowernumber)
                               JOIN branches br ON (b.branchcode = br.branchcode) 
                               JOIN categories cat ON (b.categorycode = cat.categorycode)
                    };
    my $sqlfetch = q{
                        SELECT hist.claim_id AS claim_id,
                               b.borrowernumber AS patron_id,
                               b.cardnumber AS cardnumber,
                               b.surname AS surname,
                               b.firstname AS firstname,
                               b.middle_name AS middle_name,
                               b.title AS title,
                               b.othernames AS other_name,
                               b.initials AS initials,
                               b.pronouns AS pronouns,
                               b.branchcode AS library_id,
                               b.categorycode AS category_id,
                               lpc.creationdate AS creationdate,
                               lpc.level AS level,
                               lpc.state AS status,
                               hist.action AS action,
                               hist.level AS action_level,
                               hist.comment AS action_comment,
                               hist.amountoutstanding AS action_account_balance,
                               hist.timestamp AS action_timestamp,
                               m.borrowernumber AS manager_patron_id,
                               m.cardnumber AS manager_cardnumber,
                               m.surname AS manager_surname,
                               m.firstname AS manager_firstname,
                               JSON_EXTRACT(hist.patron_selections, '$**.description') AS patron_selections_description,
                               JSON_EXTRACT(hist.ban_actions, '$**.description') AS ban_actions_description,
                               br.branchname AS library_name,
                               cat.description AS category_name
                        FROM   lmsc_late_payment_claim_history hist
                               JOIN lmsc_late_payment_claim lpc ON (lpc.id = hist.claim_id)
                               JOIN borrowers b ON (lpc.borrowernumber = b.borrowernumber)
                               JOIN branches br ON (b.branchcode = br.branchcode) 
                               JOIN categories cat ON (b.categorycode = cat.categorycode)
                               LEFT JOIN borrowers m ON (hist.manager_id = m.borrowernumber)
                    };
    my $where = join(" AND ", @where);
    $sqlcount .= " WHERE " . $where if ($where);
    $sqlfetch .= " WHERE " . $where if ($where);
    
    my ($count) = $dbh->selectrow_array($sqlcount,undef,@params);
    
    if ( $orderBy ) {
        my @order;
        foreach my $oField(split(/,/,$orderBy)) {
            if ( $oField =~ /^([-+])(.+)$/ ) {
                my $sdirection = $1 eq '-' ? 'DESC' : 'ASC';
                my $sfield = $2;
                if    ( $sfield eq 'claim_id')                 { push @order, "lpc.id $sdirection" }
                elsif ( $sfield eq 'cardnumber')               { push @order, "b.cardnumber $sdirection" }
                elsif ( $sfield eq 'patron')                   { push @order, "b.surname $sdirection, firstname $sdirection" }
                elsif ( $sfield eq 'surname')                  { push @order, "b.surname $sdirection, firstname $sdirection" }
                elsif ( $sfield eq 'library')                  { push @order, "library_name $sdirection" }
                elsif ( $sfield eq 'category')                 { push @order, "category_name $sdirection" }
                elsif ( $sfield eq 'creationdate')             { push @order, "creationdate $sdirection" }
                elsif ( $sfield eq 'level')                    { push @order, "lpc.level $sdirection" }
                elsif ( $sfield eq 'status')                   { push @order, "lpc.state $sdirection" }
                elsif ( $sfield eq 'action_account_balance')   { push @order, "hist.amountoutstanding $sdirection" }
                elsif ( $sfield eq 'action')                   { push @order, "hist.action $sdirection, hist.level ASC" }
                elsif ( $sfield eq 'action_level')             { push @order, "hist.level $sdirection" }
                elsif ( $sfield eq 'action_comment')           { push @order, "hist.comment $sdirection" }
                elsif ( $sfield eq 'action_timestamp')         { push @order, "hist.timestamp $sdirection" }
            }
        }
        if ( scalar(@order) ) {
            $sqlfetch .= " ORDER BY " . join(", ",@order);
        }
    }
    
    if ( $page_count ) {
        $sqlfetch .= " LIMIT ";
        $sqlfetch .= (($page-1) * $page_count) . ',';
        $sqlfetch .= $page_count;
    }
    
    my $sth = $dbh->prepare($sqlfetch);
    $sth->execute(@params);
    
    my $claimhistory = [];
    while ( my $claimhist = $sth->fetchrow_hashref ) {
        print STDERR Dumper($claimhist);
        if ( $claimhist->{patron_selections_description} ) {
            $claimhist->{patron_selections_description} = $json->decode( $claimhist->{patron_selections_description} );
        }
        else {
            $claimhist->{patron_selections_description} = [];
        }
        if ( $claimhist->{ban_actions_description} ) {
            $claimhist->{ban_actions_description} = $json->decode( $claimhist->{ban_actions_description} );
        } else {
            $claimhist->{ban_actions_description} = [];
        }
        push @$claimhistory, $claimhist;
    }
    
    return { late_payment_claims => $claimhistory, count => scalar(@$claimhistory), full_count => $count, page => $page, page_count => $page_count};    
}

sub closePaidLatePaymentClaim {
    my $self = shift;
    my $patron = shift;
    my $claim = shift;
    my $unbanActions = shift;
    
    my $dbh = C4::Context->dbh;
    my $json = JSON->new->allow_nonref;
    
    $dbh->do("UPDATE lmsc_late_payment_claim SET branchcode = ?, categorycode = ?, state = ? WHERE id = ?",
                        undef,
                        $patron->branchcode,
                        $patron->categorycode,
                        'closed',
                        $claim->{id});

    $dbh->do("INSERT INTO lmsc_late_payment_claim_history (claim_id,action,level,amountoutstanding,ban_actions) VALUES (?,?,?,?,?)",
                        undef,
                        $claim->{id},
                        'paid',
                        $claim->{level},
                        $patron->account->balance,
                        $json->encode( $unbanActions )
                        );
                        
    my $doActions = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::BanActions->new();
    $doActions->executeBanActions($patron->borrowernumber,$claim->{id},$claim->{level},$unbanActions);

}
    
1;

