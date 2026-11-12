package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::BanActions;

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
use Try::Tiny qw( catch try );
use Data::Dumper;
use JSON;
use Template;
use Carp qw(carp croak);
use DateTime;

use Koha::Database;
use Koha::Patrons;
use Koha::Patron;
use Koha::Patron::Attribute::Types;
use Koha::Patron::Categories;
use Koha::Libraries;
use Koha::DateUtils qw(dt_from_string output_pref);
use Koha::List::Patron qw(GetPatronLists AddPatronsToList);
use Koha::Patron::Debarments qw(DelDebarment AddDebarment);

use C4::Koha qw( GetAuthorisedValues );
use C4::Context;

use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::NoteText;
use Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::Compat;

sub new {
    my ( $class ) = @_;

    my $self  = {};
    bless $self, $class;

    my $template = Template->new(
        {   EVAL_PERL    => 0,
            ABSOLUTE     => 0,
            PLUGIN_BASE  => 'Koha::Template::Plugin',
            ENCODING     => 'UTF-8',
        }
    ) or die Template->error();
    
    $self->{template} = $template;
    $self->{atributes} = getAttributes();
    return $self;
}

sub executeBanActions {
    my $self = shift;
    my $patron_id = shift;
    my $claim_id = shift;
    my $level = shift;
    my $ban_actions = shift;
   
    my $sortHelp = { 'letter' => 100, 'fee' => 50, 'delete_debarement' => 30, 'debarement' => 40, 'set_field' => 10, 'patron_list' => 20, 'remove_notes' => 5 };
    
    $ban_actions = [ (sort { $sortHelp->{$a->{action}} <=> $sortHelp->{$b->{action}} } @$ban_actions) ];
    
    # print Dumper($ban_actions);
    
    my $dbh = C4::Context->dbh;
    
    my $patron  = Koha::Patrons->find( $patron_id );
    my $library = Koha::Libraries->find( $patron->branchcode );
    my $claim   = $dbh->selectrow_hashref("SELECT * FROM lmsc_late_payment_claim WHERE id = ?",undef,$claim_id);
    my $today   = output_pref( { dt => DateTime->now(), dateonly => 1 } );
    
    my $templateVars = {
                            patron  => $patron,
                            claim   => $claim,
                            library => $library,
                            today   => $today
                       };
    
    if ( $patron ) {
        for my $ban_action(@$ban_actions) {
            if ( $ban_action->{action} eq 'set_field' ) {
                # remember what was written so that it can be removed again later
                $ban_action->{applied} = $self->setFieldValuesAction($patron,$ban_action->{parameter},$templateVars);
            }
            elsif ( $ban_action->{action} eq 'remove_notes' ) {
                my $result = $self->removeNotesAction($patron,$ban_action->{parameter},$templateVars,$claim_id);
                if ( $result ) {
                    $ban_action->{result} = $result;
                    $ban_action->{description} = ( $ban_action->{description} // '' ) . ' [' . $result . ']';
                }
            }
            elsif ( $ban_action->{action} eq 'patron_list' ) {
                $self->patronListAction($patron,$ban_action->{parameter},$templateVars);
            }
            elsif ( $ban_action->{action} eq 'delete_debarement' ) {
                my $result = $self->deleteDebarementAction($patron,$ban_action->{parameter},$templateVars,$claim_id);
                if ( $result ) {
                    $ban_action->{result} = $result;
                    $ban_action->{description} = ( $ban_action->{description} // '' ) . ' [' . $result . ']';
                }
            }
            elsif ( $ban_action->{action} eq 'debarement' ) {
                # remember the restriction so that it can be removed again by the claim case
                $ban_action->{applied} = $self->addDebarementAction($patron,$ban_action->{parameter},$templateVars);
            }
            elsif ( $ban_action->{action} eq 'fee' ) {
                $self->addFeeAction($patron,$ban_action->{parameter},$templateVars);
            }
            elsif ( $ban_action->{action} eq 'letter' ) {
                $self->sendLetterAction($patron,$ban_action->{parameter},$templateVars);
            }
        }
    }
}

sub sendLetterAction {
    my $self = shift;
    my $patron = shift;
    my $parameters = shift;
    my $templateVars = shift;

    my $params = {};
    
    foreach my $param(@$parameters) {
        $params->{$param->{parameter_name}} = $param->{parameter_value};
    }
    my $letter = $params->{letter};
    my $letter_transport_type = $params->{letter_transport_type};
    my $amount = $params->{letter_charge};
    my $description = $params->{letter_charge_description};
    my $note = $params->{letter_charge_note};
    
    if ( $letter ) {
        
        if ( $amount ) {
            $description = $self->formatAsTemplate($description,$templateVars) if ( $description );
            $note = $self->formatAsTemplate($note,$templateVars) if ( $note );
            my $library = $patron->library;
            
            my $debitData = {
                                amount      => $amount,
                                description => $description,
                                note        => $note,
                                user_id     => C4::Context->userenv ? C4::Context->userenv->{'number'} : undef,
                                interface   => C4::Context->interface,
                                library_id  => $library->branchcode,
                                # the debit type NOTIFICATION exists only in the LMSCloud Koha
                                type        => Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::Compat->hasDebitType('NOTIFICATION') ? 'NOTIFICATION' : 'LATE_PAYMENT_CLAIM'
                            };
            try {
                my $accountline = $patron->account->add_debit($debitData);
            }
            catch {
                carp "Cannot add account debit for borrower " . $patron->borrowernumber .": @_. Debit data: ". Dumper($debitData);
            };
        }
        
        my %tables = ( 
                        'borrowers' => $patron->borrowernumber, 
                        'branches' =>  $patron->branchcode 
                    );
        my $substitute = {};
        
        my $library             = Koha::Libraries->find($patron->branchcode);
        my $admin_email_address = $library->branchemail;
        my $notice_email        = '';
        $notice_email = $patron->notice_email_address if ( $letter_transport_type eq 'email' );
        if ( $letter_transport_type eq 'email' && !$notice_email ) {
            $letter_transport_type = 'print';
        }

        try {
            my $prepared_letter = C4::Letters::GetPreparedLetter (
                module => 'members',
                letter_code => $letter,
                branchcode => $patron->branchcode,
                tables => \%tables,
                substitute => $substitute,
                objects => { claim => $templateVars->{claim} },
                message_transport_type => $letter_transport_type,
            );
            
            my $message_id = C4::Letters::EnqueueLetter(
                {   letter                 => $prepared_letter,
                    borrowernumber         => $patron->borrowernumber,
                    message_transport_type => $letter_transport_type,
                    from_address           => $admin_email_address,
                    to_address             => $notice_email,
                    branchcode             => $patron->branchcode
                }
            );
        }
        catch {
            carp "Error while creating a letter for patron " . $patron->borrowernumber .": @_. Letter data: "
                . Dumper({
                            module => 'members',
                            letter_code => $letter,
                            branchcode => $patron->branchcode,
                            tables => \%tables,
                            substitute => $substitute,
                            objects => { claim => $templateVars->{claim} },
                            message_transport_type => $letter_transport_type,
                            from_address => $admin_email_address,
                            to_address => $notice_email,
                            branchcode => $patron->branchcode
                        });
        };
    }
}

sub addFeeAction {
    my $self = shift;
    my $patron = shift;
    my $parameters = shift;
    my $templateVars = shift;

    my $params = {};
    
    foreach my $param(@$parameters) {
        $params->{$param->{parameter_name}} = $param->{parameter_value};
    }
    my $debitType = $params->{fee_debit_type};
    my $amount = $params->{fee_amount};
    my $description = $params->{fee_description};
    my $note = $params->{fee_note};
    
    if ( $amount && $amount > 0.0 && $debitType ) {
        $description = $self->formatAsTemplate($description,$templateVars) if ( $description );
        $note = $self->formatAsTemplate($note,$templateVars) if ( $note );
        my $library = $patron->library;
        
        my $debitData = {
                            amount      => $amount,
                            description => $description,
                            note        => $note,
                            user_id     => C4::Context->userenv ? C4::Context->userenv->{'number'} : undef,
                            interface   => C4::Context->interface,
                            library_id  => $library->branchcode,
                            type        => $debitType
                        };
        
        try {
            my $accountline = $patron->account->add_debit($debitData);
        }
        catch {
            carp "Cannot add account debit for borrower " . $patron->borrowernumber .": @_. Debit data: ". Dumper($debitData);
        };
    }
}

sub addDebarementAction {
    my $self = shift;
    my $patron = shift;
    my $parameters = shift;
    my $templateVars = shift;

    my $params = {};
    
    foreach my $param(@$parameters) {
        $params->{$param->{parameter_name}} = $param->{parameter_value};
    }

    my $type  = $params->{debarement_type};
    $type = 'MANUAL' if ( !$type );
    
    my $comment = $params->{debarement_comment};
    my $expirationDays = $params->{debarement_expiration};
    
    my $debarmentParams = { 
                                borrowernumber => $patron->borrowernumber, 
                                type           => $type,
                                comment        => $comment
                          };
    if ( $expirationDays ) {
        $debarmentParams->{expiration} = output_pref( { 'dt' => DateTime->now()->add( days => $expirationDays ), dateformat => 'iso', dateonly => 1 } );
    }
    
    # AddDebarment does not return the id of the restriction, so look for the new one
    my $dbh = C4::Context->dbh;
    my ($lastId) = $dbh->selectrow_array("SELECT MAX(borrower_debarment_id) FROM borrower_debarments WHERE borrowernumber = ?",undef,$patron->borrowernumber);
    $lastId //= 0;
    
    my $applied = {};
    if ( AddDebarment($debarmentParams) ) {
        my ($newId) = $dbh->selectrow_array("SELECT MAX(borrower_debarment_id) FROM borrower_debarments WHERE borrowernumber = ? AND type = ? AND borrower_debarment_id > ?",undef,$patron->borrowernumber,$type,$lastId);
        $applied->{restriction_id} = $newId + 0 if ( $newId );
    }
    return $applied;
}

=head2 deleteDebarementAction

Deletes restrictions of a patron: all restrictions of a type, all restrictions, or
only the restrictions that were set by the claim case (parameter delete_debarement_claim).

Returns a short description of the result for the claim history if restrictions of
the claim case were handled.

=cut

sub deleteDebarementAction {
    my $self = shift;
    my $patron = shift;
    my $parameters = shift;
    my $templateVars = shift;
    my $claim_id = shift;
    
    my $params = {};
    
    foreach my $param(@$parameters) {
        $params->{$param->{parameter_name}} = $param->{parameter_value};
    }
    
    my $delType = ( $params->{delete_debarement_type} && $params->{delete_debarement_type} == JSON::true );
    my $delAll  = ( $params->{delete_debarement_all} && $params->{delete_debarement_all} == JSON::true );
    my $delClaim = ( $params->{delete_debarement_claim} && $params->{delete_debarement_claim} == JSON::true );
    my $type    = $params->{delete_debarement_types};

    if ( $delClaim ) {
        return $self->deleteClaimDebarements($patron,$claim_id);
    }
    elsif ( $delType && $type ) {
        my @debarements = $patron->restrictions->search( { type => $type } )->as_list;
        foreach my $debarement( @debarements ) {
            DelDebarment( $debarement->borrower_debarment_id );
        }
    }
    elsif ( $delAll ) {
        my @debarements = $patron->restrictions->as_list;
        foreach my $debarement( @debarements ) {
            DelDebarment( $debarement->borrower_debarment_id );
        }
    }
    
    # only the deletion of restrictions of the claim case reports a result
    return '';
}

=head2 claimedHistory

Returns the 'claimed' history entries of a claim case, newest first.

=cut

sub claimedHistory {
    my $self = shift;
    my $claim_id = shift;
    
    return C4::Context->dbh->selectall_arrayref(
                    q{SELECT id, level, timestamp, manager_id, ban_actions 
                      FROM   lmsc_late_payment_claim_history 
                      WHERE  claim_id = ? AND action = 'claimed' 
                      ORDER  BY timestamp DESC, id DESC}, 
                    { Slice => {} }, $claim_id);
}

=head2 deleteClaimDebarements

Deletes the restrictions that the actions of the claim case have set. The ids of the
restrictions are stored with the 'claimed' history entries. For history entries written
before the ids were stored, the restriction is looked for by type, comment, staff member
and the time the history entry was written. If that finds nothing, the restriction stays.

Restrictions that do not exist any more are counted but not touched.

=cut

sub deleteClaimDebarements {
    my $self = shift;
    my $patron = shift;
    my $claim_id = shift;
    
    return '' if ( !$claim_id );
    
    my $dbh = C4::Context->dbh;
    my $json = JSON->new->allow_nonref;
    
    my $total = 0;
    my $removed = 0;
    my $seen = {};
    
    foreach my $entry ( @{ $self->claimedHistory($claim_id) } ) {
        my $actions = eval { $json->decode( $entry->{ban_actions} ) };
        next if ( !$actions || ref($actions) ne 'ARRAY' );
        
        foreach my $action ( @$actions ) {
            next if ( ref($action) ne 'HASH' || ($action->{action} // '') ne 'debarement' );
            
            my $restrictionId;
            if ( ref($action->{applied}) eq 'HASH' ) {
                # the id of the restriction was stored (it is missing if the restriction could not be added)
                $restrictionId = $action->{applied}->{restriction_id};
            }
            else {
                # older entry: find the restriction again
                my $params = {};
                foreach my $param ( @{ $action->{parameter} || [] } ) {
                    $params->{$param->{parameter_name}} = $param->{parameter_value};
                }
                my $type = $params->{debarement_type} || 'MANUAL';
                my $comment = $params->{debarement_comment};
                $comment = undef if ( defined($comment) && length($comment) == 0 );
                
                ($restrictionId) = $dbh->selectrow_array(
                        q{SELECT borrower_debarment_id 
                          FROM   borrower_debarments 
                          WHERE  borrowernumber = ? AND type = ? AND comment <=> ? AND manager_id <=> ? 
                                 AND created BETWEEN DATE_SUB(?, INTERVAL 1 MINUTE) AND DATE_ADD(?, INTERVAL 1 HOUR)
                          ORDER  BY borrower_debarment_id},
                        undef, $patron->borrowernumber, $type, $comment, $entry->{manager_id}, $entry->{timestamp}, $entry->{timestamp});
            }
            
            next if ( !$restrictionId || $seen->{$restrictionId} );
            $seen->{$restrictionId} = 1;
            $total++;
            
            my $restriction = $patron->restrictions->search( { borrower_debarment_id => $restrictionId } )->next;
            if ( $restriction ) {
                DelDebarment( $restrictionId );
                $removed++;
            }
        }
    }
    
    return 'Sperren: ' . ( $total == 0 ? 'keine durch den Mahnfall gesetzten Sperren gefunden' : $removed . ' von ' . $total . ' gelöscht' );
}

sub patronListAction {
    my $self = shift;
    my $patron = shift;
    my $parameters = shift;
    my $templateVars = shift;
    
    my $params = {};
    
    foreach my $param(@$parameters) {
        $params->{$param->{parameter_name}} = $param->{parameter_value};
    }
    
    my $listID = $params->{patron_list};
    my $add = ( $params->{patron_list_add} && $params->{patron_list_add} == JSON::true );
    my $del = ( $params->{patron_list_delete} && $params->{patron_list_delete} == JSON::true );
    
    my $schema = Koha::Database->new()->schema();
    my ($patronList) = $schema->resultset('PatronList')->search( { patron_list_id => $listID } );
    
    if ( $patronList ) {
        if ( $add ) {
            AddPatronsToList( { list => $patronList, borrowernumbers => [ $patron->borrowernumber ] } );
        }
        if ( $del ) {
            # DelPatronsFromList expects the ids of the list entries, not borrowernumbers, so delete the entry directly
            $schema->resultset('PatronListPatron')->search( { patron_list_id => $listID, borrowernumber => $patron->borrowernumber } )->delete();
        }
    }
    
}

sub setFieldValuesAction {
    my $self = shift;
    my $patron = shift;
    my $parameters = shift;
    my $templateVars = shift;

    my $setvalues = {};
    my $attrValues = {};
    my $params = {};
    my $renderedNotes = {};
    my $applied = {};
    
    foreach my $param(@$parameters) {
        $params->{$param->{parameter_name}} = $param->{parameter_value};
    }
    foreach my $param(@$parameters) {
        if ( $param->{parameter_name} eq 'set_field_categorycode' && $param->{parameter_value} ) {
            my $category = $param->{parameter_value};
            my $bor_category = Koha::Patron::Categories->find($category);
            if ( $bor_category ) {
                $setvalues->{categorycode} = $category;
            }
            else {
                carp "Cannot set borrower category $category for borrower " . $patron->borrowernumber .". Category does not exists.";
            }
        }
        elsif ( $param->{parameter_name} eq 'set_field_borrowernotes' && $param->{parameter_value} ) {
            my $note = $param->{parameter_value};
            $note = $self->formatAsTemplate($note,$templateVars);
            $renderedNotes->{borrowernotes} = $note;
            $setvalues->{borrowernotes} = $note;
            if ( $params->{'set_field_borrowernotes_append'} && $params->{'set_field_borrowernotes_append'} == JSON::true ) {
                my $currnote = $patron->borrowernotes;
                if ( $currnote ) {
                    $currnote =~ s/\.\s*$//;
                    $currnote .= '. ' . $note;
                    $setvalues->{borrowernotes} = $currnote;
                }
            }
        }
        elsif ( $param->{parameter_name} eq 'set_field_opacnote' && $param->{parameter_value} ) {
            my $note = $param->{parameter_value};
            $note = $self->formatAsTemplate($note,$templateVars);
            $renderedNotes->{opacnote} = $note;
            $setvalues->{opacnote} = $note;
            if ( $params->{'set_field_opacnote_append'} && $params->{'set_field_opacnote_append'} == JSON::true ) {
                my $currnote = $patron->opacnote;
                if ( $currnote ) {
                    $currnote =~ s/\.\s*$//;
                    $currnote .= '. ' . $note;
                    $setvalues->{opacnote} = $currnote;
                }
            }
        }
        elsif ( $param->{parameter_name} eq 'set_field_dateexpiry_action' && $param->{parameter_value} ) {
            my $value = $param->{parameter_value};
            if ( $value eq 'current' ) {
                $setvalues->{dateexpiry} = output_pref( { 'dt' => DateTime->now(), dateformat => 'iso', dateonly => 1 } );
            }
            elsif ( $value eq 'yesterday' ) {
                $setvalues->{dateexpiry} = output_pref( { 'dt' => DateTime->now()->subtract( days => 1 ), dateformat => 'iso', dateonly => 1 } );
            }
        }
        elsif ( $param->{parameter_name} eq 'set_field_attribute_value' && defined($param->{parameter_value}) && length($param->{parameter_value}) > 0) {
            my $value = $param->{parameter_value};
            
            if ( $params->{'set_field_attribute_code'} ) {
                my $attribute = $params->{'set_field_attribute_code'};
                my $attrSetting;
                for my $attrType( @{$self->{atributes}} ) {
                    if ( $attrType->{attribute_code} eq $attribute ) {
                        $attrSetting = $attrType;
                        last;
                    }
                }
                if ( $attrSetting ) {
                    if ( $attrSetting->{type} eq 'text' ) {
                        $attrValues->{$attribute} = $self->formatAsTemplate($value,$templateVars);
                    }
                    elsif ( $attrSetting->{type} eq 'select' ) {
                        if ( $attrSetting->{options} ) {
                            my $setvalue;
                            for my $option( @{$attrSetting->{options}} ) {
                                if ( $value eq $option->{authorised_value} ) {
                                    $setvalue = $value;
                                    last
                                }
                            }
                            if ( defined($setvalue) && length($setvalue)>0 ) {
                                $attrValues->{$attribute} = $setvalue;
                            } else {
                                carp "Attribute '$attribute' cannot be set to value '$value' for borrower " . $patron->borrowernumber .". The value is not an authorised value of the configured athorised value category.";
                            }
                        }
                    }
                } else {
                    carp "Attribute '$attribute' cannot be set to value '$value' for borrower " . $patron->borrowernumber .". The atrribute type cennot be found.";
                }
            }
        }
    }
    
    if ( scalar(keys %$setvalues) ) {
        eval { $patron->set($setvalues)->store; };
        if ( $@ ) { 
            carp "Error saving data changes of borrower " . $patron->borrowernumber .": $@. Field values: " . Dumper($setvalues);
        }
        else {
            foreach my $field ( keys %$renderedNotes ) {
                $applied->{$field} = $renderedNotes->{$field} if ( defined($renderedNotes->{$field}) && length($renderedNotes->{$field}) > 0 );
            }
        }
    }
    if ( scalar(keys %$attrValues) ) {
        foreach my $attr(keys %$attrValues) {
            my $attribute = {};
            $attribute->{code} = $attr;
            $attribute->{attribute} = $attrValues->{$attr};
            eval {
                $patron->extended_attributes->search({'me.code' => $attribute->{code}})->filter_by_branch_limitations->delete;
                $patron->add_extended_attribute($attribute);
            };
            if ( $@ ) { 
                carp "Error saving extended attribute of borrower " . $patron->borrowernumber .": $@. Attribute values: " . Dumper($attribute);
            }
        }
    }
    
    return $applied;
};

=head2 removeNotesAction

Removes the texts that the late payment claims of a claim case have written
into the circulation note and/or the OPAC note of the patron.

The texts are taken from the 'applied' entries the claiming run stores with
the 'claimed' history entries of the claim case. History entries that were
written before these entries existed are rebuilt from the action's template.
A text that cannot be found in the note any more (e.g. because the note was
edited by staff) is left alone.

Returns a short description of the result for the claim history.

=cut

sub removeNotesAction {
    my $self = shift;
    my $patron = shift;
    my $parameters = shift;
    my $templateVars = shift;
    my $claim_id = shift;
    
    my $params = {};
    foreach my $param(@$parameters) {
        $params->{$param->{parameter_name}} = $param->{parameter_value};
    }
    
    my $fields = [];
    my $labels = { borrowernotes => 'Ausleihnotiz', opacnote => 'OPAC-Notiz' };
    foreach my $field ( 'borrowernotes', 'opacnote' ) {
        my $name = 'remove_notes_' . $field;
        push @$fields, $field if ( $params->{$name} && $params->{$name} == JSON::true );
    }
    return '' if ( !scalar(@$fields) || !$claim_id );
    
    my $dbh = C4::Context->dbh;
    my $json = JSON->new->allow_nonref;
    
    # claimed history entries of the claim case, newest first
    my $history = $self->claimedHistory($claim_id);
    
    my $claim = $dbh->selectrow_hashref("SELECT * FROM lmsc_late_payment_claim WHERE id = ?",undef,$claim_id);
    
    my $notes = {};
    my $total = {};
    my $removed = {};
    foreach my $field (@$fields) {
        $notes->{$field} = $patron->$field;
        $total->{$field} = 0;
        $removed->{$field} = 0;
    }
    
    foreach my $entry (@$history) {
        my $actions = eval { $json->decode( $entry->{ban_actions} ) };
        next if ( !$actions || ref($actions) ne 'ARRAY' );
        
        # the actions were executed in the given order, so undo them in reverse order
        foreach my $action ( reverse @$actions ) {
            next if ( ref($action) ne 'HASH' || ($action->{action} // '') ne 'set_field' );
            
            foreach my $field (@$fields) {
                my @candidates;
                if ( ref($action->{applied}) eq 'HASH' ) {
                    # new style: the text that was really written is known
                    @candidates = ( $action->{applied}->{$field} ) if ( defined($action->{applied}->{$field}) && length($action->{applied}->{$field}) > 0 );
                }
                else {
                    # old style: render the configured text again
                    @candidates = $self->renderHistoricNotes($patron,$action,$field,$entry,$claim,$templateVars);
                }
                next if ( !scalar(@candidates) );
                
                $total->{$field}++;
                foreach my $text (@candidates) {
                    my ( $newnote, $found ) = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::NoteText::remove( $notes->{$field}, $text );
                    if ( $found ) {
                        $notes->{$field} = $newnote;
                        $removed->{$field}++;
                        last;
                    }
                }
            }
        }
    }
    
    my $setvalues = {};
    foreach my $field (@$fields) {
        my $current = $patron->$field;
        if ( ( $current // '' ) ne ( $notes->{$field} // '' ) ) {
            $setvalues->{$field} = ( defined($notes->{$field}) && length($notes->{$field}) > 0 ) ? $notes->{$field} : undef;
        }
    }
    if ( scalar(keys %$setvalues) ) {
        eval { $patron->set($setvalues)->store; };
        if ( $@ ) {
            carp "Error removing notes of borrower " . $patron->borrowernumber .": $@. Field values: " . Dumper($setvalues);
            return 'Fehler beim Speichern der Notizen';
        }
    }
    
    my @result;
    foreach my $field (@$fields) {
        if ( $total->{$field} == 0 ) {
            push @result, $labels->{$field} . ': keine gesetzten Hinweise gefunden';
        }
        else {
            my $text = $labels->{$field} . ': ' . $removed->{$field} . ' von ' . $total->{$field} . ' Hinweisen entfernt';
            my $missing = $total->{$field} - $removed->{$field};
            $text .= ', ' . $missing . ' nicht mehr in der Notiz gefunden' if ( $missing > 0 );
            push @result, $text;
        }
    }
    return join('; ', @result);
}

=head2 renderHistoricNotes

Rebuilds the text that an action of an older history entry wrote into a note.
The date of the claiming run is taken from the history entry. The run used
the UTC date, so the day before is tried as well.

=cut

sub renderHistoricNotes {
    my $self = shift;
    my $patron = shift;
    my $action = shift;
    my $field = shift;
    my $entry = shift;
    my $claim = shift;
    my $templateVars = shift;
    
    my $template;
    foreach my $param ( @{$action->{parameter}} ) {
        if ( $param->{parameter_name} eq 'set_field_' . $field && defined($param->{parameter_value}) && length($param->{parameter_value}) > 0 ) {
            $template = $param->{parameter_value};
        }
    }
    return () if ( !defined($template) );
    
    my $timestamp = eval { dt_from_string( $entry->{timestamp}, 'iso' ) };
    return () if ( !$timestamp );
    
    my @texts;
    foreach my $date ( $timestamp, $timestamp->clone()->subtract( days => 1 ) ) {
        my $vars = {
                       %$templateVars,
                       claim => { %{ $claim || {} }, level => $entry->{level} },
                       today => output_pref( { dt => $date, dateonly => 1 } )
                   };
        my $text = $self->formatAsTemplate($template,$vars);
        push @texts, $text if ( defined($text) && length($text) > 0 );
    }
    return @texts;
}

sub getAttributes {
    
    my $patron_attribute_types = Koha::Patron::Attribute::Types->search_with_library_limits({}, {});
    my @patron_categories = Koha::Patron::Categories->search_with_library_limits({}, {order_by => ['description']})->as_list;

    my @patron_attributes_codes;
        
    while ( my $attr_type = $patron_attribute_types->next ) {
        next if $attr_type->repeatable;
        next if $attr_type->unique_id; # Don't display patron attributes that must be unqiue
        
        my $options = $attr_type->authorised_value_category
            ? GetAuthorisedValues( $attr_type->authorised_value_category )
            : undef;

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
                options        => $options
            };
    }
    return \@patron_attributes_codes;
}

sub formatAsTemplate {
    my $self = shift;
    my $text = shift;
    my $templateVars = shift;
    
    my $data;
    binmode( STDOUT,":encoding(UTF-8)");
    
    # process() returns false on template errors instead of dying
    my $ok = eval { $self->{template}->process( \$text, $templateVars, \$data ) };
    if ( !$ok || !defined($data) ) {
        carp "Error while processing template string '$text': " . ( $@ || $self->{template}->error() || 'unknown error' );
        return $text;
    }
    return $data;
}

1;

#use C4::Context;
#use JSON;

#my $patron_id = 300;
#my $claim_id = 69;
#my $level = 1;

#my $json = JSON->new->allow_nonref;
#my $dbh = C4::Context->dbh;

## my ($ban_actions) = $dbh->selectrow_array("SELECT ban_actions FROM lmsc_late_payment_claim_history WHERE claim_id = ?",undef,$claim_id);
#my ($ban_actions) = $dbh->selectrow_array("SELECT ban_actions FROM lmsc_late_payment_claim_rules WHERE branchcode IS NULL AND categorycode IS NULL AND level=1");
#$ban_actions = $json->decode($ban_actions);

#my $doBans = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::BanActions->new();
#$doBans->executeBanActions($patron_id,$claim_id,$level,$ban_actions);
#$doBans->executeBanActions($patron_id,$claim_id,$level,$ban_actions);

