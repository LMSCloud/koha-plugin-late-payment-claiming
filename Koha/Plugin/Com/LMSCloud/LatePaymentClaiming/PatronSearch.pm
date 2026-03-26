package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::PatronSearch;

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
use JSON;
use Koha::Patrons;

sub new {
    my ( $class, $args ) = @_;

    my $self  = {};
    bless $self, $class;

    return $self;
}

sub getPatronList {
    my $self              = shift;
    my $library_id        = shift;
    my $category_id       = shift;
    my $level             = shift;
    my $patron_selection  = shift;
    
    return [] if ( scalar(@$patron_selection) == 0 );
    my $patrons = $self->search($library_id,$category_id,$level,$patron_selection);
    
    my $patronList = [];
    my $checkid = {};
    
    if ($patrons->count) {
        while ( my $patron = $patrons->next ) {
            next if exists( $checkid->{$patron->borrowernumber} );
            push @$patronList, { patron_id => $patron->borrowernumber, library_id => $patron->branchcode, category_id => $patron->categorycode };
            $checkid->{$patron->borrowernumber} = 1;
        }
    }

    return $patronList;
}


sub search {
    my $self              = shift;
    my $library_id        = shift;
    my $category_id       = shift;
    my $level             = shift;
    my $patron_selection  = shift;
    my $filter            = shift;
    
    my $params = $self->buildSearchParams($library_id,$category_id,$level,$patron_selection,$filter);
    
    return Koha::Patrons->search($params);
    
    # print "Found ",$patrons->count," patrons\n";
}

sub buildSearchParams {
    my $self              = shift;
    my $library_id        = shift;
    my $category_id       = shift;
    my $level             = shift;
    my $patron_selection  = shift;
    my $filter            = shift;
    
    my $query;
    $query->{'-and'} = [];
    
    if ( $library_id && $library_id ne '*' ) {
        push @{$query->{'-and'}}, \[ 'me.branchcode = ?', $library_id ];
    }
    if ( $category_id && $category_id ne '*' ) {
        push @{$query->{'-and'}}, \[ 'me.categorycode = ?', $category_id ];
    }
    if ( $level ) {
        push @{$query->{'-and'}}, \[ 'NOT EXISTS (SELECT 1 FROM lmsc_late_payment_claim lpc WHERE lpc.borrowernumber = me.borrowernumber AND lpc.level >= ? AND state IN (?,?))', $level, 'paused', 'open' ];
    }
    if ( $filter ) {
        $filter = '%' . $filter . '%';
        my $q = '(me.cardnumber like ? OR me.surname like ? OR me.firstname like ? OR me.middle_name like ? OR me.othernames like ? OR me.streetnumber like ? OR me.address like ? OR me.address2 like ? OR me.city like ? OR me.state like ? OR me.zipcode like ? OR me.country like ? OR me.branchcode = ? OR EXISTS (SELECT 1 FROM branches br WHERE me.branchcode = br.branchcode AND br.branchname like ?) OR me.categorycode = ? OR EXISTS (SELECT 1 FROM categories cat WHERE me.categorycode = cat.categorycode AND cat.description like ?) OR me.borrowernotes like ?)';
        my @params = ($filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter,$filter);
        push @{$query->{'-and'}}, \[ $q, @params ];
    }
    foreach my $selection(@$patron_selection) {
        if ( ref($selection) eq 'HASH' ) {
            if ($selection->{search_field} eq 'late_payment_claim' && $selection->{search_type} ) {
                my $q = '';
                my @params;
                if ( $selection->{search_type} eq 'any' ) {
                    $q = 'EXISTS (SELECT 1 FROM lmsc_late_payment_claim lpc WHERE lpc.borrowernumber = me.borrowernumber AND lpc.level >= ? AND state IN (?,?))';
                    @params = (1,'paused', 'open');
                    if ( $selection->{search_value} && $selection->{search_value} =~ /^([0-9]+)$/ ) {
                        my $days = $1;
                        $q = 'EXISTS (SELECT 1 FROM lmsc_late_payment_claim lpc JOIN lmsc_late_payment_claim_history lpch ON (lpc.id = lpch.claim_id) WHERE lpc.borrowernumber = me.borrowernumber AND lpc.level >= ? AND lpch.level >= ? AND state IN (?,?) AND action = ? AND timestamp <= now() - interval ? day)';
                        @params = (1, 1, 'paused', 'open', 'claimed', $days);
                    }
                }
                elsif ( $selection->{search_type} =~ /^([0-9]+)$/ ) {
                    my $l = $1;
                    $q = 'EXISTS (SELECT 1 FROM lmsc_late_payment_claim lpc WHERE lpc.borrowernumber = me.borrowernumber AND lpc.level = ? AND state IN (?,?))';
                    @params = ($l, 'paused', 'open');
                    if ( $selection->{search_value} && $selection->{search_value} =~ /^([0-9]+)$/ ) {
                        my $days = $1;
                        $q = 'EXISTS (SELECT 1 FROM lmsc_late_payment_claim lpc JOIN lmsc_late_payment_claim_history lpch ON (lpc.id = lpch.claim_id) WHERE lpc.borrowernumber = me.borrowernumber AND lpc.level = ? AND lpch.level = ? AND state IN (?,?) AND action = ? AND timestamp <= now() - interval ? day)';
                        @params = ($l, $l, 'paused', 'open', 'claimed', $days);
                    }
                }
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'patron_field' && $selection->{search_type} && $selection->{search_fieldset} && $selection->{search_value} ) {
                my $q = '';
                my @params;
                
                # get search value
                my $value = $selection->{search_value};
                if ( $selection->{search_type} eq 'starts_with' ) {
                    $value .= '%';
                } 
                elsif ( $selection->{search_type} eq 'contains' ) {
                    $value = '%' . $value . '%';
                }
                
                foreach my $field(split(/,/,$selection->{search_fieldset})) {
                    $field =~ s/(^\s+|\s+$)//g;
                    $q .= ' OR ' if ( $q ne '');
                    $q .= 'me.' . $field . ' LIKE ?';
                    push @params, $value;
                }
                
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT (' . $q . ')';
                }
                else {
                    $q = '(' . $q . ')';
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'age_range' && ( $selection->{search_from} || $selection->{search_to} ) ) {
                my $q = '';
                my @params;
                if ( $selection->{search_from} && $selection->{search_to} ) {
                    $q = 'TIMESTAMPDIFF(YEAR,me.dateofbirth,CURDATE()) BETWEEN ? AND ?';
                    @params = ($selection->{search_from}, $selection->{search_to});
                }
                elsif ( $selection->{search_from} ) {
                    $q = 'TIMESTAMPDIFF(YEAR,me.dateofbirth,CURDATE()) >= ?';
                    @params = ($selection->{search_from});
                }
                elsif ( $selection->{search_to} ) {
                    $q = 'TIMESTAMPDIFF(YEAR,me.dateofbirth,CURDATE()) <= ?';
                    @params = ($selection->{search_to});
                }
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT (' . $q . ')';
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'issue_count' && ( $selection->{search_from} || $selection->{search_to} ) ) {
                my $q = '';
                my @params;
                if ( $selection->{search_from} && $selection->{search_to} ) {
                    $q = '(SELECT COUNT(*) FROM issues iss WHERE iss.borrowernumber = me.borrowernumber) BETWEEN ? AND ?';
                    @params = ($selection->{search_from}, $selection->{search_to});
                }
                elsif ( $selection->{search_from} ) {
                    $q = '(SELECT COUNT(*) FROM issues iss WHERE iss.borrowernumber = me.borrowernumber) >= ?';
                    @params = ($selection->{search_from});
                }
                elsif ( $selection->{search_to} ) {
                    $q = '(SELECT COUNT(*) FROM issues iss WHERE iss.borrowernumber = me.borrowernumber) <= ?';
                    @params = ($selection->{search_to});
                }
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT (' . $q . ')';
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'charges_amount' && ( $selection->{search_from} || $selection->{search_to} ) ) {
                my $q = '';
                my @params;
                if ( $selection->{search_from} && $selection->{search_from} =~ /^[0-9]+(\.+[0-9]+)?$/ && $selection->{search_to} && $selection->{search_to} =~ /^[0-9]+(\.+[0-9]+)?$/ ) {
                    $q = '( EXISTS (SELECT 1 FROM accountlines a WHERE a.borrowernumber = me.borrowernumber GROUP BY a.borrowernumber HAVING ';
                    if ( ($selection->{search_from} + 0.0) == 0.0 && ($selection->{search_to} + 0.0) == 0.0 ) {
                        $q .= "COALESCE(SUM(a.amountoutstanding),0) = 0.0) OR NOT EXISTS (SELECT 1 FROM accountlines aa WHERE aa.borrowernumber = me.borrowernumber) )";
                    } else {
                        $q .= "COALESCE(SUM(a.amountoutstanding),0) BETWEEN ? AND ?) ";
                        $q .= "OR NOT EXISTS ( SELECT 1 FROM accountlines aa WHERE aa.borrowernumber = me.borrowernumber) " if ( ( ( $selection->{'search_from'}  + 0.0 ) == 0.0 || ( $selection->{'search_to'}  + 0.0 ) == 0.0 ) && $selection->{'search_to'} >= $selection->{'search_from'} );
                        $q .= " )";
                        @params = ($selection->{search_from} + 0.0, $selection->{search_to} + 0.0);
                    }
                }
                elsif ( $selection->{search_from} && $selection->{search_from} =~ /^[0-9]+(\.+[0-9]+)?$/ ) {
                    $q = '( EXISTS (SELECT 1 FROM accountlines a WHERE a.borrowernumber = me.borrowernumber GROUP BY a.borrowernumber HAVING SUM(a.amountoutstanding) >= ?)';
                    $q .= "OR NOT EXISTS (SELECT 1 FROM accountlines aa WHERE aa.borrowernumber = me.borrowernumber) " if ( ($selection->{search_from} + 0.0) == 0.0 );
                    $q .= " )";
                    @params = ($selection->{search_from} + 0.0);
                }
                elsif ( $selection->{search_to} && $selection->{search_to} =~ /^[0-9]+(\.+[0-9]+)?$/ ) {
                    $q = '( EXISTS (SELECT 1 FROM accountlines a WHERE a.borrowernumber = me.borrowernumber GROUP BY a.borrowernumber HAVING SUM(a.amountoutstanding) >= ?)';
                    $q .= "OR NOT EXISTS (SELECT 1 FROM accountlines aa WHERE aa.borrowernumber = me.borrowernumber) " if ( ($selection->{search_to} + 0.0) == 0.0 );
                    $q .= " )";
                    @params = ($selection->{search_to} + 0.0);
                }
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'charges_since' && $selection->{search_value} =~ /^([0-9]+)$/ ) {
                my $days = $1;
                my $q = "EXISTS (SELECT 1 FROM accountlines al WHERE al.borrowernumber = me.borrowernumber AND al.amountoutstanding >= 0.01 and al.date <= DATE(now() - interval ? day))";
                my @params = ($days);
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'account_expired' && ( $selection->{search_from} || $selection->{search_to} ) ) {
                my $q = '';
                my @params;
                if ( $selection->{search_from} && $selection->{search_to} ) {
                    $q = 'me.dateexpiry BETWEEN DATE(now() - interval ? day) AND DATE(now() - interval ? day)';
                    @params = ($selection->{search_to}, $selection->{search_from});
                }
                elsif ( $selection->{search_from} ) {
                    $q = 'me.dateexpiry <= DATE(now() - interval ? day)';
                    @params = ($selection->{search_from});
                }
                elsif ( $selection->{search_to} ) {
                    $q = 'me.dateexpiry <= DATE(now() - interval ? day)';
                    @params = ($selection->{search_to});
                }
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT (' . $q . ')';
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'debarred_until' && ( $selection->{search_from} || $selection->{search_to} ) ) {
                my $q = '';
                my @params;
                if ( $selection->{search_from} && $selection->{search_to} ) {
                    $q = 'me.debarred BETWEEN DATE(now() - interval ? day) AND DATE(now() - interval ? day)';
                    @params = ($selection->{search_to}, $selection->{search_from});
                }
                elsif ( $selection->{search_from} ) {
                    $q = 'me.debarred <= DATE(now() - interval ? day)';
                    @params = ($selection->{search_from});
                }
                elsif ( $selection->{search_to} ) {
                    $q = 'me.debarred <= DATE(now() - interval ? day)';
                    @params = ($selection->{search_to});
                }
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT (' . $q . ')';
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'inactive_since' && $selection->{search_value} =~ /^([0-9]+)$/ ) {
                my $days = $1;
                my $q = '( NOT EXISTS (SELECT 1 FROM issues iss WHERE iss.borrowernumber = me.borrowernumber AND iss.timestamp > now() - interval ? day)';
                $q .= ' AND NOT EXISTS (SELECT 1 FROM old_issues oiss WHERE oiss.borrowernumber = me.borrowernumber AND oiss.timestamp > now() - interval ? day)';
                $q .= ' AND (me.lastseen < now() - interval ? day OR me.lastseen IS NULL) )';
                my @params = ($days,$days,$days);
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'last_letter_code' && $selection->{search_value} ) {
                my $q = "EXISTS (SELECT 1 FROM message_queue m WHERE m.borrowernumber = me.borrowernumber AND m.letter_code = ? and m.time_queued = (SELECT MAX(time_queued) FROM message_queue mq WHERE mq.borrowernumber = me.borrowernumber and status = ?))";
                my @params = ($selection->{search_value},'sent');
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'overdue_level' && $selection->{search_value} ) {
                my $q = "EXISTS (SELECT 1 FROM issues i WHERE i.borrowernumber = me.borrowernumber AND ? IN (SELECT max(claim_level) FROM overdue_issues o WHERE i.issue_id = o.issue_id GROUP BY o.issue_id))";
                my @params = ($selection->{search_value});
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
            if ( $selection->{search_field} eq 'overdue_level' && $selection->{search_value} ) {
                if ( $selection->{search_value} eq 'any' ) {
                    my $q = "EXISTS (SELECT 1 FROM issues i WHERE i.borrowernumber = me.borrowernumber AND EXISTS(SELECT 1 FROM overdue_issues o WHERE i.issue_id = o.issue_id GROUP BY o.issue_id))";
                    if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                        $q = 'NOT ' . $q;
                    }
                    push @{$query->{'-and'}}, \[ $q];
                } else {
                    my $q = "EXISTS (SELECT 1 FROM issues i WHERE i.borrowernumber = me.borrowernumber AND ? IN (SELECT max(claim_level) FROM overdue_issues o WHERE i.issue_id = o.issue_id GROUP BY o.issue_id))";
                    my @params = ($selection->{search_value});
                    if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                        $q = 'NOT ' . $q;
                    }
                    push @{$query->{'-and'}}, \[ $q, @params ];
                }
            }
            if ( $selection->{search_field} eq 'valid_email' && $selection->{search_value} ) {
                my $q;
                if ( $selection->{search_value} eq 'yes' ) {
                    $q = '(me.email REGEXP \'^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]@[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]\.[a-zA-Z]{2,4}$\' OR '.
                         'me.emailpro REGEXP \'^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]@[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]\.[a-zA-Z]{2,4}$\')';
                } else {
                    $q = '( (me.email NOT REGEXP \'^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]@[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]\.[a-zA-Z]{2,4}$\' OR me.email IS NULL) AND ' .
                         ' (me.emailpro NOT REGEXP \'^[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]@[a-zA-Z0-9][a-zA-Z0-9._-]*[a-zA-Z0-9]\.[a-zA-Z]{2,4}$\' OR me.emailpro IS NULL) )';
                }
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q ];
            }
            if ( $selection->{search_field} eq 'patron_list' && $selection->{search_value} =~ /^\d+$/ ) {
                my $q = "EXISTS (SELECT 1 FROM  patron_list_patrons p WHERE p.patron_list_id = ? AND p.borrowernumber = me.borrowernumber )";
                my @params = ($selection->{search_value});
                if ( $selection->{negate} && JSON->boolean($selection->{negate}) eq JSON::true )  {
                    $q = 'NOT ' . $q;
                }
                push @{$query->{'-and'}}, \[ $q, @params ];
            }
        }
    }
    # print Dumper($query);
    return $query;
}

1;



