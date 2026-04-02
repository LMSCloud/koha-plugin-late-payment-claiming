package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration;

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

use C4::Context;
use JSON;

use Koha::Libraries;
use Koha::Patron::Categories;

sub new {
    my ( $class, $args ) = @_;

    my $self  = {};
    bless $self, $class;

    return $self;
}

sub getConfigurationList {
    my $self = shift;
    
    my $dbh = C4::Context->dbh;
    
    my $sth = $dbh->prepare(q{
            SELECT lpcr.branchcode AS branchcode, 
                   lpcr.categorycode AS categorycode,
                   MAX(lpcr.level) AS levels_defined
            FROM   lmsc_late_payment_claim_rules lpcr
            GROUP  BY lpcr.branchcode, lpcr.categorycode
            ORDER  BY lpcr.branchcode, lpcr.categorycode
        });
    $sth->execute();
    my $configurations = [];
    while ( my $config = $sth->fetchrow_hashref ) {
        push @$configurations, {
                library_id => ($config->{branchcode} ? $config->{branchcode} : '*'),
                category_id => ($config->{categorycode} ? $config->{categorycode} : '*'),
                levels_defined => $config->{levels_defined}
            };
    }
    
    my $branchcodes = {};
    foreach my $library( Koha::Libraries->search_filtered({ -or => [ mobilebranch => undef, mobilebranch => '' ] }, { order_by => 'branchname' })->as_list ) {
        $branchcodes->{$library->branchcode} = $library->branchname;
    }
    my $categories = {};
    foreach my $categorie( Koha::Patron::Categories->search({}, {order_by => ['description']})->as_list ) {
        $categories->{$categorie->categorycode} = $categorie->description;
    }
    
    @$configurations = reverse sort { 
                                my $cmplib = compareLibraryId($a->{library_id},$b->{library_id},$branchcodes);
                                return compareCategoryId($a->{category_id},$b->{category_id},$categories) if ( $cmplib == 0 );
                                return $cmplib;
                            } @$configurations;
    
    return $configurations;
}

sub compareLibraryId {
    my ($alib_id,$blib_id,$libraries) = @_;
    
    if ( $alib_id eq '*' && $blib_id eq '*' ) {
        return 0;
    } 
    elsif ( $alib_id eq '*' ) { 
        return -1;
    }
    elsif ( $blib_id eq '*' ) {
        return 1;
    }
    else {
        my $alibname = ( exists($libraries->{$alib_id}) ? $libraries->{$alib_id} : $alib_id );
        my $blibname = ( exists($libraries->{$blib_id}) ? $libraries->{$blib_id} : $blib_id );
        return $alibname cmp $blibname;
    }
}

sub compareCategoryId {
    my ($acateg_id,$bcateg_id,$categories) = @_;
    
    if ( $acateg_id eq '*' && $bcateg_id eq '*' ) {
        return 0;
    }
    elsif ( $acateg_id eq '*' ) {
        return -1;
    }
    elsif ( $bcateg_id eq '*' ) {
        return 1;
    }
    else {
        my $acategname = ( exists($categories->{$acateg_id}) ? $categories->{$acateg_id} : $acateg_id );
        my $bcategname = ( exists($categories->{$bcateg_id}) ? $categories->{$bcateg_id} : $bcateg_id );
        return $acategname cmp $bcategname;
    }
}

sub getConfiguration {
    my $self = shift;
    my $branchcode = shift;
    my $categorycode = shift;
    
    my $dbh = C4::Context->dbh;
    
    my @params = (0);
    my $sql = q{
            SELECT *
            FROM   lmsc_late_payment_claim_rules lpcr  
            WHERE  level >= ?
        };
    
    if ($branchcode && $branchcode ne '*') {
        $sql .= ' AND branchcode = ? ';
        push @params, $branchcode;
    } else {
        $sql .= ' AND branchcode IS NULL ';
    }
    if ($categorycode && $categorycode ne '*') {
        $sql .= ' AND categorycode = ? ';
        push @params, $categorycode;
    } else {
        $sql .= ' AND categorycode IS NULL ';
    }
    $sql .= ' ORDER BY level';
    
    my $sth = $dbh->prepare($sql);
    
    $sth->execute(@params);
    my $configuration = { library_id => ($branchcode ? $branchcode : '*'), 
                          category_id => ($categorycode ? $categorycode : '*'), 
                          level_configuration => [] };
    my $json = JSON->new->allow_nonref;
    
    while ( my $config = $sth->fetchrow_hashref ) {
        push @{$configuration->{level_configuration}}, 
            {
                level                 => $config->{level},
                outstanding_fee_limit => $config->{outstanding_fee_limit},
                patron_selections     => $json->decode( $config->{patron_selections} ),
                ban_actions           => $json->decode( $config->{ban_actions} )
            };
    }
    
    return $configuration;
}

sub removeConfiguration {
    my $self = shift;
    my $branchcode = shift;
    my $categorycode = shift;
    
    my $dbh = C4::Context->dbh;
    
    my @params = (0);
    my $sql = q{DELETE FROM lmsc_late_payment_claim_rules WHERE level >= ?};
    if ($branchcode && $branchcode ne '*') {
        $sql .= ' AND branchcode = ? ';
        push @params, $branchcode;
    } else {
        $sql .= ' AND branchcode IS NULL ';
    }
    if ($categorycode && $categorycode ne '*') {
        $sql .= ' AND categorycode = ? ';
        push @params, $categorycode;
    } else {
        $sql .= ' AND categorycode IS NULL ';
    }
    
    return $dbh->do($sql,undef,@params);
}

sub saveConfiguration {
    my $self = shift;
    my $branchcode = shift;
    my $categorycode = shift;
    my $config = shift;
    
    my $json = JSON->new->allow_nonref;
    
    my $dbh = C4::Context->dbh;
    
    my $checkLevel = 0;
    foreach my $levelConfig( sort { $a->{level} <=> $b->{level} } @{$config->{level_configuration}} ) {
        return if ( $checkLevel != $levelConfig->{level} );
        $checkLevel++;
    }
    
    foreach my $levelConfig( sort { $a->{level} <=> $b->{level} } @{$config->{level_configuration}} ) {
        
        # Build the values we are going to save
        my $savedConf = {
                            branchcode => ((!$branchcode || $branchcode eq '*') ? undef : $branchcode),
                            categorycode => ((!$categorycode || $categorycode eq '*') ? undef : $categorycode),
                            level => $levelConfig->{level},
                            outstanding_fee_limit => $levelConfig->{outstanding_fee_limit},
                            patron_selections => $json->encode( $levelConfig->{patron_selections} ),
                            ban_actions => $json->encode( $levelConfig->{ban_actions} )
                        };
        
        # In order to update existing level entries initialize the where params
        my $where = '';
        my $params = [];
        if ( $savedConf->{branchcode} ) {
            $where .= "branchcode = ? ";
            push @$params, $savedConf->{branchcode};
        } else {
            $where .= "branchcode IS NULL ";
        }
        if ( $savedConf->{categorycode} ) {
            $where .= "AND categorycode = ? ";
            push @$params, $savedConf->{categorycode};
        } else {
            $where .= "AND categorycode IS NULL ";
        }

        # Check whether the level config exists and get the id of the record
        my $select = "SELECT id FROM lmsc_late_payment_claim_rules lpcr WHERE $where AND level = ?";
        my $sth = $dbh->prepare($select);
        $sth->execute(@$params,$savedConf->{level});
        
        if ( my ($id) = $sth->fetchrow_array ) {
            $savedConf->{id} = $id;
        }
        
        print STDERR Dumper($savedConf);
        
        # if we can do an update ...
        if ( exists($savedConf->{id}) ) {
            $dbh->do(q{
                             UPDATE lmsc_late_payment_claim_rules
                             SET outstanding_fee_limit = ?,
                                 patron_selections = ?,
                                 ban_actions = ?
                             WHERE
                                 id = ?
                         }, undef, 
                         $savedConf->{outstanding_fee_limit},
                         $savedConf->{patron_selections},
                         $savedConf->{ban_actions},
                         $savedConf->{id}
                     );
        }
        # or do an insert
        else {
            $dbh->do(q{
                             INSERT lmsc_late_payment_claim_rules (branchcode,categorycode,level,outstanding_fee_limit,patron_selections,ban_actions)
                             VALUES (?,?,?,?,?,?)
                         }, undef,
                         $savedConf->{branchcode},
                         $savedConf->{categorycode},
                         $savedConf->{level},
                         $savedConf->{outstanding_fee_limit},
                         $savedConf->{patron_selections},
                         $savedConf->{ban_actions}
                     );
        }
        # delete any existing higher level entry
        $dbh->do("DELETE FROM lmsc_late_payment_claim_rules WHERE $where AND level >= ?",undef,@$params,$checkLevel);
    }
    return $self->getConfiguration($branchcode,$categorycode);
}

1;

