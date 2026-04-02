package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming;

# Copyright 2026 (C) LMSCLoud GmbH
#
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
use JSON qw( decode_json encode_json );
use Try::Tiny;
use Cwd qw(abs_path);
use Data::Dumper;

use C4::Context;
use C4::Koha qw( GetAuthorisedValues );
use C4::Auth qw( get_template_and_user );

use Koha::Acquisition::Currencies qw( get_active );
use Koha::DateUtils qw( dt_from_string output_pref );
use Koha::Patrons;
use Koha::Account::DebitTypes;
use Koha::Patron::Restriction::Types;
use Koha::List::Patron qw( GetPatronLists );
use Koha::Patron::Attribute::Types;
use Koha::Patron::Categories;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::CheckExecution;

our $VERSION = "0.7.0";
our $MINIMUM_VERSION = "22.11";

our $metadata = {
    name            => 'Gebührenmahnung',
    author          => 'LMSCloud GmbH',
    date_authored   => '2026-02-15',
    date_updated    => "2026-04-02",
    minimum_version => $MINIMUM_VERSION,
    maximum_version => undef,
    version         => $VERSION,
    description     => 'Koha Plugin zur automatisierten Durchführung von Gebührenmahnungen anhand konfigurierbarer Benutzerselektionen udn Aktionen für jede Mahnstufe',
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
    
    if ( $cgi->param('save_general')  ) {
        $self->store_data(
            {
                batch_active                      => scalar $cgi->param('batch_active'),
                execution_month_days              => scalar $cgi->param('execution_month_days') || '*',
                execution_monthes                 => scalar $cgi->param('execution_monthes') || '*',
                execution_weekdays                => scalar $cgi->param('execution_weekdays') || '*',
                execution_on_closing_days         => scalar $cgi->param('execution_on_closing_days') || 'yes',
                execution_on_closing_days_library => scalar $cgi->param('execution_on_closing_days_library'),
                account_balance_for_closing       => scalar $cgi->param('account_balance_for_closing') || '0.0',
                unban_actions                     => scalar $cgi->param('unban_actions') || '[]',
                do_automatic_close_on_payment     => (scalar $cgi->param('do_automatic_close_on_payment')) + 0,
            }
        );
    }
    
    my $template = $self->get_template({ file => 'configure.tt' });
    
    my $do = $cgi->param('do') || '';
    


    # get debit types
    my @debit_types = Koha::Account::DebitTypes->search_with_library_limits({ can_be_invoiced => 1, archived => 0 },{})->as_list;
    
    # get restriction types
    my @restriction_types = Koha::Patron::Restriction::Types->search()->as_list;

    # get the patron attributes list
    my @patron_attributes_values;
    my @patron_attributes_codes;
    my $library_id = C4::Context->userenv ? C4::Context->userenv->{'branch'} : undef;
    my $patron_attribute_types = Koha::Patron::Attribute::Types->search_with_library_limits({}, {}, $library_id);
    my @patron_categories = Koha::Patron::Categories->search_with_library_limits({}, {order_by => ['description']})->as_list;
    while ( my $attr_type = $patron_attribute_types->next ) {
        next if $attr_type->repeatable;
        next if $attr_type->unique_id; # Don't display patron attributes that must be unqiue
        my $options = $attr_type->authorised_value_category
            ? GetAuthorisedValues( $attr_type->authorised_value_category )
            : undef;
        push @patron_attributes_values,
            {
                attribute_code => $attr_type->code,
                options        => $options,
            };

        my $category_code = $attr_type->category_code;
        my ( $category_lib ) = map {
            ( defined $category_code and $attr_type->category_code eq $category_code ) ? $attr_type->description : ()
        } @patron_categories;
        push @patron_attributes_codes,
            {
                attribute_code => $attr_type->code,
                attribute_lib  => $attr_type->description,
                category_lib   => $category_lib,
                type           => $attr_type->authorised_value_category ? 'select' : 'text',
            };
    }
        
    if ( $do eq 'edit' ) {
        my $action = $cgi->param('do');
        if ( $action && $action eq 'edit' ) {
            $template->param(
                action  => 'edit_config'
            );
        }
    }
        
    my $currency = Koha::Acquisition::Currencies->get_active;
    
    my $dbh = C4::Context->dbh;
    my $selectLetter = q{SELECT   code, module, name, GROUP_CONCAT(DISTINCT message_transport_type SEPARATOR ',') message_transport_type
                         FROM     letter
                         WHERE    module IN ('members')
                         GROUP BY code, module, name 
                         ORDER BY name};
    my $letters = $dbh->selectall_arrayref($selectLetter,{ Slice => {} });

    $template->param(
        last_upgraded                     => $self->retrieve_data('last_upgraded'),
        debit_types                       => \@debit_types,
        restriction_types                 => \@restriction_types,
        patron_attributes_codes           => \@patron_attributes_codes,
        patron_attributes_values          => \@patron_attributes_values,
        patron_lists                      => [ GetPatronLists() ],
        library_id                        => scalar $cgi->param('library_id'),
        category_id                       => scalar $cgi->param('category_id'),
        currency                          => ($currency) ? $currency->symbol : '',
        patronLetters                     => $letters,
        defaultStrings                    => {
                                               letter_charge_description => 'Benachrichtigungsgebühr für [% claim.level %]. Gebührenmahnung',
                                               letter_charge_note        => '[% claim.level %]. Gebührenmahnung vom [% today %]',
                                               fee_note                  => '[% claim.level %]. Gebührenmahnung vom [% today %]',
                                             },
    );
    
    my $config = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaimingConfiguration->new();
    
    $template->param(
        batch_active                      => $self->retrieve_data('batch_active') || 0,
        execution_month_days              => $self->retrieve_data('execution_month_days') || '*',
        execution_monthes                 => $self->retrieve_data('execution_monthes') || '*',
        execution_weekdays                => $self->retrieve_data('execution_weekdays') || '*',
        execution_on_closing_days         => $self->retrieve_data('execution_on_closing_days') || 'yes',
        execution_on_closing_days_library => $self->retrieve_data('execution_on_closing_days_library'),
        account_balance_for_closing       => $self->retrieve_data('account_balance_for_closing') || '0.0',
        unban_actions                     => $self->retrieve_data('unban_actions') || '[]',
        do_automatic_close_on_payment     => $self->retrieve_data('do_automatic_close_on_payment') + 0, 
        configurations                    => $config->getConfigurationList()
    );
    
    # $self->go_home() ;
    
    $self->output_html( $template->output() );
    exit;
}

sub cronjob_nightly {
    my ( $self ) = @_;
    
    my $batch_active = $self->retrieve_data('batch_active') || 0;
    return if ( $batch_active );
    
    my $execution_month_days = $self->retrieve_data('execution_month_days') || '*';
    my $execution_monthes = $self->retrieve_data('execution_monthes') || '*';
    my $execution_weekdays = $self->retrieve_data('execution_weekdays') || '*';
    my $execution_on_closing_days = $self->retrieve_data('execution_on_closing_days');
    my $execution_on_closing_days_library = $self->retrieve_data('execution_on_closing_days_library');

    my $cron = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::CheckExecution->new();
    
    my $result = $cron->getNextDay(  
                        $execution_month_days,
                        $execution_monthes,
                        $execution_weekdays,
                        DateTime->now()->subtract(days => 1),
                        $execution_on_closing_days,
                        $execution_on_closing_days_library);
    if ( $result->{ok} ) {
        if ( $result->{next}->ymd('-') eq DateTime->now()->ymd('-') ) {
            my $doClaim = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming->new();
            $doClaim->claimPatronsOfAllConfigurations();
        }
    }
}

sub tool {
    my ( $self, $args ) = @_;

    my $cgi = $self->{'cgi'};
    
    my $toolaction = $cgi->param('toolaction');
    
    if ( $toolaction && $toolaction eq 'claimHistory' ) {
        $self->claimHistory();
    }
    elsif ( $toolaction && $toolaction eq 'currentClaims' ) {
        $self->currentClaims();
    }
    else {
        my $template = $self->get_template({
            file => 'claimHistory.tt'
        });
        $self->output_html( $template->output );
    }
}

sub after_account_action {
    my ($self, $args) = @_;
    
    my $do_automatic_close_on_payment = ($self->retrieve_data('do_automatic_close_on_payment')) + 0;
    
    return if (! $do_automatic_close_on_payment);
    
    my $line;
    if ( exists($args->{payload}) && exists($args->{payload}->{line}) ) {
        $line = $args->{payload}->{line};
    }
    if ( exists($args->{action}) && $args->{action} eq "add_credit" ) {
        if ( $line && $line->borrowernumber ) {
            my $dbh = C4::Context->dbh;
            my $claim = $dbh->selectrow_hashref("SELECT * FROM lmsc_late_payment_claim WHERE borrowernumber = ?",undef,$line->borrowernumber);
            if ( $claim ) {
                my $patron  = Koha::Patrons->find( $line->borrowernumber );
                if ( $patron ) {
                    my $balance = $patron->account->balance;
                    $balance = 0.0 if (!defined $balance);
                    $balance += 0.0;
                    my $checkAmount = $self->retrieve_data('account_balance_for_closing') + 0.0;
                    if ( $balance <= $checkAmount ) {
                        print STDERR "after_account_action: Patron ", $line->borrowernumber, " reached level to close claim\n";
                        
                        my $json = JSON->new->allow_nonref;
                        my $unbanJSON = $self->retrieve_data('unban_actions') || '[]';
                        my $unbanActions = $json->decode( $unbanJSON );
                        
                        my $claiming = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::LatePaymentClaiming->new();
                        $claiming->closePaidLatePaymentClaim($patron,$claim,$unbanActions);
                    }
                }
            }
        }
    }
}

sub claimHistory {
    my ($self, $args) = @_;

    my $cgi = $self->{cgi};
    my $template = $self->get_template({
        file => 'claimHistory.tt'
    });
    
    my @branches = map { value => $_->branchcode, label => $_->branchname }, Koha::Libraries->search_filtered({ -or => [ mobilebranch => undef, mobilebranch => '' ] }, { order_by => 'branchname' })->as_list;
    my @categorylist = map { value => $_->categorycode, label => $_->description }, Koha::Patron::Categories->search({}, {order_by => ['description']})->as_list;
    
    $template->param( 
        action => 'list',
        branches => \@branches, 
        categorylist => \@categorylist 
    );

    $self->output_html( $template->output );
    exit;
}

sub currentClaims {
    my ($self, $args) = @_;

    my $cgi = $self->{cgi};
    
    my $status_filter = $cgi->param('status_filter') || '';
    
    $status_filter = 'open' if (! $status_filter );
    $status_filter = '' if ( $status_filter eq 'all' );
    
    my $template = $self->get_template({
        file => 'currentClaims.tt'
    });
    
    my @branches = map { value => $_->branchcode, label => $_->branchname }, Koha::Libraries->search_filtered({ -or => [ mobilebranch => undef, mobilebranch => '' ] }, { order_by => 'branchname' })->as_list;
    my @categorylist = map { value => $_->categorycode, label => $_->description }, Koha::Patron::Categories->search({}, {order_by => ['description']})->as_list;
    
    $template->param( 
        status_filter => $status_filter,
        action => 'list',
        branches => \@branches, 
        categorylist => \@categorylist 
    );

    $self->output_html( $template->output );
    exit;
}

## This is the 'install' method. Any database tables or other setup that should
## be done when the plugin if first installed should be executed in this method.
## The installation method should always return true if the installation succeeded
## or false if it failed.
sub install {
    my ( $self, $args ) = @_;

    #    my $table = $self->get_qualified_table_name('configuration');
    #
    C4::Context->dbh->do(q{
        CREATE TABLE IF NOT EXISTS `lmsc_late_payment_claim` (
          `id` INT(11) NOT NULL AUTO_INCREMENT               COMMENT 'Unique identifier added by Koha',
          `borrowernumber` INT(11) NOT NULL                  COMMENT 'The user the late payment claim is for',
          `branchcode` VARCHAR(10) DEFAULT NULL              COMMENT 'Foreign key from the branches table, includes the code of the patron/borrower''s home branch',
          `categorycode` VARCHAR(10) DEFAULT NULL            COMMENT 'Foreign key from the categories table, includes the code of the patron category',
          `creationdate` DATE DEFAULT NULL                   COMMENT 'The date the late payment claim was created',
          `level` TINYINT UNSIGNED NOT NULL DEFAULT 0        COMMENT 'Late payment claim level starting with 1',
          `state` ENUM('open','paused','closed') 
                  NOT NULL default 'open'                    COMMENT 'Current status of the late payment claim case',
          `comment` mediumtext NOT NULL                      COMMENT 'Comment of the late payment claim case',
          PRIMARY KEY (`id`),
          KEY `lmsc_lpc_borrowernumber` (`borrowernumber`),
          KEY `lmsc_lpc_branchcode` (`branchcode`),
          KEY `lmsc_lpc_categorycode` (`categorycode`),
          CONSTRAINT `lmsc_lpcr_ibcfk_1` FOREIGN KEY (`branchcode`) REFERENCES `branches` (`branchcode`) ON DELETE CASCADE ON UPDATE CASCADE,
          CONSTRAINT `lmsc_lpcr_ibcfk_2` FOREIGN KEY (`categorycode`) REFERENCES `categories` (`categorycode`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    });
    
    C4::Context->dbh->do(q{
        CREATE TABLE IF NOT EXISTS `lmsc_late_payment_claim_history` (
          `id` int(11) NOT NULL AUTO_INCREMENT               COMMENT 'Unique identifier added by Koha',
          `claim_id` int(11) NOT NULL                        COMMENT 'Id of the late payment claim',
          `action` VARCHAR(20) NOT NULL                      COMMENT 'Action that was performed for the late payment claim case',
          `level` TINYINT UNSIGNED NOT NULL                  COMMENT 'Late payment claim level starting with 1',
          `comment` mediumtext NOT NULL                      COMMENT 'Comment of the late payment claim case',
          `amountoutstanding` DECIMAL(28,6) default NULL     COMMENT 'Outstanding fee at the time of the history entry',
          `patron_selections` mediumtext DEFAULT NULL        COMMENT 'Selection parameters applied to reach that level JSON format',
          `ban_actions` mediumtext NOT NULL                  COMMENT 'Ban actions performed at the level in JSON format',
          `unban_actions` mediumtext NOT NULL                COMMENT 'Unban actions performed in JSON format',
          `timestamp` timestamp NOT NULL 
                      DEFAULT current_timestamp()            COMMENT 'The timestamp the action was performed',
          `manager_id` int(11) DEFAULT NULL                  COMMENT 'Staff member who performed the action (NULL if it was an automated action)',
          PRIMARY KEY (`id`),
          KEY `lmsc_lpch_claim_id` (`claim_id`,`timestamp`),
          KEY `lmsc_lpch_level` (`claim_id`,`level`),
          KEY `lmsc_lpch_action` (`claim_id`,`action`),
          CONSTRAINT `lmsc_lpch_ibcfk_1` FOREIGN KEY (`claim_id`) REFERENCES `lmsc_late_payment_claim` (`id`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    });
    
    
    C4::Context->dbh->do(q{
        CREATE TABLE IF NOT EXISTS `lmsc_late_payment_claim_rules` (
          `id` int(11) NOT NULL AUTO_INCREMENT               COMMENT 'Unique identifier added by Koha',
          `branchcode` VARCHAR(10) DEFAULT NULL              COMMENT 'Foreign key from the branches table, includes the code of the patron/borrower''s home branch',
          `categorycode` VARCHAR(10) DEFAULT NULL            COMMENT 'Foreign key from the categories table, includes the code of the patron category',
          `level` TINYINT UNSIGNED NOT NULL DEFAULT 0        COMMENT 'Late payment claim level starting with 1 (entry with 0 just for existence of a rule)',
          `outstanding_fee_limit` DECIMAL(28,6) default NULL COMMENT 'Fee limit that needs to be reached for this level',
          `patron_selections` mediumtext NOT NULL            COMMENT 'Selection parameters defined in JSON format',
          `ban_actions` mediumtext NOT NULL                  COMMENT 'Ban actions to perform in JSON format',
          `unban_actions` mediumtext NOT NULL                COMMENT 'Unban actions to perform in JSON format',
          PRIMARY KEY (`id`),
          UNIQUE KEY `lmsc_lpcr_uniq` (`branchcode`,`categorycode`,`level`),
          KEY `lmsc_lpcr_ibfk_1` (`branchcode`),
          KEY `lmsc_lpcr_ibfk_2` (`categorycode`),
          CONSTRAINT `lmsc_lpcr_ibfk_1` FOREIGN KEY (`branchcode`) REFERENCES `branches` (`branchcode`) ON DELETE CASCADE ON UPDATE CASCADE,
          CONSTRAINT `lmsc_lpcr_ibfk_2` FOREIGN KEY (`categorycode`) REFERENCES `categories` (`categorycode`) ON DELETE CASCADE ON UPDATE CASCADE
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    });
    
    C4::Context->dbh->do(
                q{
                    INSERT IGNORE INTO account_debit_types ( code, description, can_be_invoiced, can_be_sold, default_amount, is_system )
                    VALUES ('LATE_PAYMENT_CLAIM', 'Gebührenmahnung', 1, 0, NULL, 1);
                }
            );
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

    C4::Context->dbh->do("DROP TABLE IF EXISTS `lmsc_late_payment_claim`");
    C4::Context->dbh->do("DROP TABLE IF EXISTS `lmsc_late_payment_claim_history`");
    C4::Context->dbh->do("DROP TABLE IF EXISTS `lmsc_late_payment_claim_rules`");
    
    return 1;
}

sub static_routes {
    my ( $self, $args ) = @_;

    my $spec_str = $self->mbf_read('staticapi.json');
    my $spec     = decode_json($spec_str);

    return $spec;
}

sub api_namespace {
    my ($self) = @_;

    return 'latepaymentclaiming';
}

sub api_routes {
    my ( $self, $args ) = @_;

    my $spec_dir = $self->mbf_dir();

    my $schema = JSON::Validator::Schema::OpenAPIv2->new;
    my $spec = $schema->resolve($spec_dir . '/openapi.yaml');

    return $self->_convert_refs_to_absolute($spec->data->{'paths'}, 'file://' . $spec_dir . '/');
}

sub _convert_refs_to_absolute {
    my ( $self, $hashref, $path_prefix ) = @_;

    foreach my $key (keys %{ $hashref }) {
        if ($key eq '$ref') {
            if ($hashref->{$key} =~ /^(\.\/)?openapi/) {
                $hashref->{$key} = $path_prefix . $hashref->{$key};
            }
        } elsif (ref $hashref->{$key} eq 'HASH' ) {
            $hashref->{$key} = $self->_convert_refs_to_absolute($hashref->{$key}, $path_prefix);
        } elsif (ref($hashref->{$key}) eq 'ARRAY') {
            $hashref->{$key} = $self->_convert_array_refs_to_absolute($hashref->{$key}, $path_prefix);
        }
    }
    return $hashref;
}

sub _convert_array_refs_to_absolute {
    my ( $self, $arrayref, $path_prefix ) = @_;

    my @res;
    foreach my $item (@{ $arrayref }) {
        if (ref($item) eq 'HASH') {
            $item = $self->_convert_refs_to_absolute($item, $path_prefix);
        } elsif (ref($item) eq 'ARRAY') {
            $item = $self->_convert_array_refs_to_absolute($item, $path_prefix);
        }
        push @res, $item;
    }
    return \@res;
}


1;
