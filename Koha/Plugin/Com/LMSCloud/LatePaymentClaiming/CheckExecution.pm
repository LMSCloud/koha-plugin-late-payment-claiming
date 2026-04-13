package Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::CheckExecution;

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
use DateTime;
use DateTime::Event::Cron;

use Koha::Calendar;

sub new {
    my ( $class ) = @_;

    my $self  = {};
    bless $self, $class;
    
    $self->{maxIterations} = 5000;

    return $self;
}

sub getNextDays {
    my ($self,$dayCron,$monthCron,$weekdayCron,$start,$execOnClosingDays,$execOnClosingDayLibrary,$count) = @_;
    
    my $checkResult = $self->checkCronEntry($dayCron,$monthCron,$weekdayCron);
    my $nextDays = [];
    
    while ( $checkResult->{ok} && $count-- >=1 ) {
        $self->getNextDay($dayCron,$monthCron,$weekdayCron,$start,$execOnClosingDays,$execOnClosingDayLibrary,$checkResult);
        if ( $checkResult->{ok} ) {
            my $next = $checkResult->{next}->clone();
            push @$nextDays, $next;
            $start = $next;
        }
    }
    return $nextDays;
}

sub getNextDay {
    my ($self,$dayCron,$monthCron,$weekdayCron,$start,$execOnClosingDays,$execOnClosingDayLibrary,$checkRes) = @_;
    
    my $startDate = DateTime->new(year => $start->year, month => $start->month, day => $start->day);
    my $today = DateTime->now();
    my $todayCompare = DateTime->new(year => $today->year, month => $today->month, day => $today->day);
    
    my $checkResult;
    if ( $checkRes ) {
        $checkResult = $checkRes;
    } else {
        $checkResult = $self->checkCronEntry($dayCron,$monthCron,$weekdayCron);
    }
    return $checkResult if (! $checkResult->{ok} );
    
    my $day = $checkResult->{day};
    my $month = $checkResult->{month};
    my $weekday = $checkResult->{weekday};
    
    if ( $day ne '*' && $weekday ne '*' ) {
        my $cronday;
        
        $cronday = DateTime::Event::Cron->new("0 0 " . $day . " " . $month ." *") if ( $day ne 'L' );
        my $cronweekday = DateTime::Event::Cron->new("0 0 * " . $month . " " . $weekday);
        
        my $nextDay;
        
        if ( $day ne 'L' ) {
            $nextDay = $cronday->next($startDate);
        } else {
            $nextDay = $self->getNextLastDayOfMonth($startDate);
        }
        my $nextWeekday = $cronweekday->next($startDate);
        
        my $maxCycles = $self->{maxIterations};
        
        my ($checkres,$useDate) = $self->compareDatesAndCheckClosingDay($nextDay,$nextWeekday,$execOnClosingDays,$execOnClosingDayLibrary);
        while ( ($checkres != 0 || $useDate < $todayCompare) && $maxCycles-- > 0 ) {
            # print "$cmpres => ", $nextDay->ymd(), " ", $nextDay->hms(), " ", $nextWeekday->ymd(), " ", , $nextDay->hms(), "\n";
            if ( $checkres == 1 ) {
                $nextWeekday = $cronweekday->next($nextWeekday);
            } else {
                if ( $day ne 'L' ) {
                    $nextDay = $cronday->next($nextDay);
                } else {
                    $nextDay = $self->getNextLastDayOfMonth($nextDay);
                }
            }
            ($checkres,$useDate) = $self->compareDatesAndCheckClosingDay($nextDay,$nextWeekday,$execOnClosingDays,$execOnClosingDayLibrary);
        }

        if ( DateTime->compare($nextDay,$nextWeekday) == 0 ) {
            # print $nextDay->dmy(".");
            $checkResult->{next} = $useDate;
        }
        else {
            push @{ $checkResult->{problems} }, { error => 'not found' };
            $checkResult->{ok} = 0 if ( $checkResult->{error} );
        }
        
    }
    else {
        
        my $cron;
        my $nextDay;
        
        while ( !$nextDay || $nextDay < $todayCompare ) {
            if ( $day ne 'L' ) {
                $cron = DateTime::Event::Cron->new("0 0 " . $day . " " . $month . " " . $weekday);
                $nextDay = $cron->next($startDate);
            } else {
                $nextDay = $self->getNextLastDayOfMonth($startDate);
            }
            
            $startDate = $nextDay;
            
            if ( $execOnClosingDays && $execOnClosingDayLibrary ) {
                my $calendar = Koha::Calendar->new( branchcode => $execOnClosingDayLibrary );
                if ( $execOnClosingDays eq 'no' ) {
                    my $maxCycles = $self->{maxIterations};
                    while ( $calendar->is_holiday($nextDay) && $maxCycles-- > 0) {
                        if ( $day ne 'L' ) {
                            $nextDay = $cron->next($nextDay);
                        } else {
                            $nextDay = $self->getNextLastDayOfMonth($nextDay);
                        }
                    }
                }
                elsif ( $execOnClosingDays eq 'delay' ) {
                    my $maxCycles = $self->{maxIterations};
                    while ( $calendar->is_holiday($nextDay) && $maxCycles-- >= 1 ) {
                        $nextDay->add(days => 1);
                    }
                }
            }
            # print $nextDay->ymd('-'), " <=> ", $todayCompare->ymd('-'), "\n";
        }
        
        $checkResult->{next} = $nextDay;
    }
    
    return $checkResult;
}

sub compareDatesAndCheckClosingDay {
    my $self = shift;
    my $date1 = shift;
    my $date2 = shift;
    my $execOnClosingDays = shift;
    my $execOnClosingDayLibrary = shift;
    my $useDate = $date1->clone;
    
    my $cmp = DateTime->compare($date1,$date2);

    if ( $cmp == 0 && $execOnClosingDays && $execOnClosingDayLibrary ) {
        # check Koha calendar
        my $calendar = Koha::Calendar->new( branchcode => $execOnClosingDayLibrary );
        if ( $execOnClosingDays eq 'delay' ) {
            my $maxCycles = $self->{maxIterations};
            while ( $calendar->is_holiday($useDate) && $maxCycles-- >= 1 ) {
                $useDate->add(days => 1);
            }
        }
        elsif ( $execOnClosingDays eq 'no' ) {
            if ( $calendar->is_holiday($date1) ) {
                $cmp = 1;
            }
        }
    }
    return ($cmp,$useDate);
}

sub checkCronEntry {
    my ($self,$dayCron,$monthCron,$weekdayCron) = @_;
    
    $dayCron = '*' if (! $dayCron );
    $monthCron = '*' if (! $monthCron );
    $weekdayCron = '*' if (! $weekdayCron );
    
    my $checkResult = { ok => 1, error => 0, problems => [], day => $dayCron, month => $monthCron, weekday => $weekdayCron };
    
    if ( $dayCron ne 'L' ) {
        eval { my $croncheck = DateTime::Event::Cron->new("0 0 " . $dayCron . " * *"); };
        if ( $@ ) { 
            $checkResult->{error} = 1;
            push @{ $checkResult->{problems} }, { field => 'day', value => $dayCron, error => 'validation' };
        }
    }
    
    eval { my $croncheck = DateTime::Event::Cron->new("0 0 * " . $monthCron . " *"); };
    if ( $@ ) { 
        $checkResult->{error} = 1;
        push @{ $checkResult->{problems} }, { field => 'month', value => $monthCron, error => 'validation' };
    }
    
    eval { my $croncheck = DateTime::Event::Cron->new("0 0 * " . $weekdayCron . " *"); };
    if ( $@ ) { 
        $checkResult->{error} = 1;
        push @{ $checkResult->{problems} }, { field => 'weekday', value => $weekdayCron, error => 'validation' };
    }
    
    $checkResult->{ok} = 0 if ( $checkResult->{error} );
    
    return $checkResult;
}

sub getNextLastDayOfMonth {
    my $self = shift;
    my $startDay = shift;
    my $dt = $startDay->clone();
    $dt->set_day(1);
    $dt->add(months => 1);
    $dt->subtract(days => 1);
    if ( DateTime->compare($startDay,$dt) == 0 ) {
        $dt->add(days => 1);
        $dt->add(months => 1);
        $dt->subtract(days => 1);
    }
    return $dt;
} 

1;

#my $cron = Koha::Plugin::Com::LMSCloud::LatePaymentClaiming::CheckExecution->new();
#my $startDate = DateTime->new(year => 2025, month => 12, day => 31);
#my $res = $cron->getNextDays('1-7','*','7',$startDate,'delay','Zentrale',10);

#foreach my $d(@$res) {
#    print $d->dmy("."),"\n";
#}
# print Dumper($res);

#my $res = $cron->getNextLastDayOfMonth(DateTime->now());
#print $res->ymd, "\n";
#$res = $cron->getNextLastDayOfMonth($res);
#print $res->ymd, "\n";
#$res = $cron->getNextLastDayOfMonth($res);
#print $res->ymd, "\n";
