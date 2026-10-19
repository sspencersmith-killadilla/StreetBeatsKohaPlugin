package Koha::Plugin::Com::McKinney::StreetBeats;

use Modern::Perl;
use base qw(Koha::Plugins::Base);
use C4::Context;
use C4::Auth qw(haspermission);
use JSON qw(decode_json);
use Koha::Token;

sub new {
    my ( $class, $args ) = @_;
    $args->{'metadata'} = {
        name            => 'StreetBeats Integration',
        author          => 'Spencer Smith',
        description     => 'Published performance slots, venue information, patron reservations, and staff booking reports.',
        date_authored   => '2026-05-13',
        date_updated    => '2026-10-19',
        minimum_version => '22.11',
        version         => '1.20',
    };
    return $class->SUPER::new($args);
}

sub api_namespace {
    return 'streetbeats';
}

sub api_routes {
    my ($self) = @_;
    return decode_json( $self->mbf_read('api.json') );
}

sub static_routes {
    my ($self) = @_;
    return decode_json( $self->mbf_read('staticapi.json') );
}

# -------------------------------------------------------------------------
# STAFF DASHBOARD: Performance Analytics
# -------------------------------------------------------------------------
sub tool {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    my $dbh = C4::Context->dbh;

    # 1. PERMISSIONS
    unless ( $self->_can_manage ) {
        print $cgi->redirect("/cgi-bin/koha/mainpage.pl");
        return;
    }

    my $output;
    my $ok = eval {
        my ( $message, $action_error );
        if ( $cgi->request_method eq 'POST' && ( ( $cgi->param('action') // '' ) eq 'booking_decision' ) ) {
            my $decision_ok = eval {
                $message = _decide_booking( $dbh, $cgi );
                1;
            };
            unless ($decision_ok) {
                $action_error = $@ || 'The booking decision could not be saved.';
                $action_error =~ s/[\r\n]+/ /g;
                $action_error =~ s/\s+/ /g;
                $action_error =~ s/^\s+|\s+$//g;
            }
        }

        # 2. CALCULATE SUMMARY STATS
        my $stats = {};
        $stats->{total_active} = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM streetbeats_slots WHERE start_time >= NOW() AND status IN ('pending', 'approved')"
        );
        $stats->{unique_musicians} = $dbh->selectrow_array(
            "SELECT COUNT(DISTINCT borrowernumber) FROM streetbeats_slots WHERE status IN ('pending', 'approved')"
        );
        $stats->{pending_review} = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM streetbeats_slots WHERE status = 'pending'"
        );
        $stats->{top_location} = $dbh->selectrow_array(
            "SELECT l.location_name FROM streetbeats_slots s JOIN streetbeats_locations l ON s.location_id = l.location_id WHERE s.status IN ('pending', 'approved') GROUP BY s.location_id ORDER BY COUNT(*) DESC LIMIT 1"
        ) || "None";
        $stats->{avg_per_week} = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM streetbeats_slots WHERE start_time >= DATE_SUB(NOW(), INTERVAL 7 DAY) AND status IN ('pending', 'approved')"
        );

        # 3. GET DETAILED BOOKINGS
        my $query = "
            SELECT s.*, l.location_name, b.cardnumber, b.firstname, b.surname, b.borrowernumber,
                   COALESCE(g.title, 'StreetBeats performance') AS gig_title,
                   COALESCE(p.band_name, '') AS band_name,
                   COALESCE(p.genre, '') AS genre,
                   COALESCE(p.bio, '') AS bio,
                   COALESCE(p.social_link, '') AS social_link,
                   COALESCE(p.image_url, '') AS image_url,
                   COALESCE(p.technical_needs, '') AS technical_needs
            FROM streetbeats_slots s
            JOIN streetbeats_locations l ON s.location_id = l.location_id
            JOIN borrowers b ON s.borrowernumber = b.borrowernumber
            LEFT JOIN streetbeats_profiles p ON p.borrowernumber = b.borrowernumber
            LEFT JOIN streetbeats_gigs g
                ON g.gig_id = s.gig_id
                OR (s.gig_id IS NULL AND g.location_id = s.location_id AND g.start_time = s.start_time)
            ORDER BY s.start_time DESC
        ";
        my $slots = $dbh->selectall_arrayref( $query, { Slice => {} } );
        my $session_id = $cgi->cookie('CGISESSID');
        my $csrf_token = $session_id
            ? Koha::Token->new->generate_csrf( { session_id => $session_id } )
            : '';
        my $template = $self->get_template( { file => 'streetbeats/report.tt' } );
        $template->param(
            slots      => $slots,
            stats      => $stats,
            message    => $message,
            action_error => $action_error,
            csrf_token => $csrf_token,
        );
        $output = $template->output();
        1;
    };

    return $self->_output_runtime_error($@) unless $ok;
    $self->output_html($output);
}

sub _decide_booking {
    my ( $dbh, $cgi ) = @_;
    my $slot_id  = $cgi->param('slot_id') // '';
    my $decision = $cgi->param('decision') // '';
    my $note     = $cgi->param('staff_note') // '';
    $note =~ s/^\s+|\s+$//g;
    die "Choose a valid booking and decision.\n"
        unless $slot_id =~ /\A\d+\z/ && $decision =~ /\A(?:approved|rejected)\z/;
    die "Staff notes must be 1,000 characters or fewer.\n" if length($note) > 1000;
    $dbh->begin_work;
    my $decided = eval {
        my $current = $dbh->selectrow_hashref(
            "SELECT status FROM streetbeats_slots WHERE slot_id = ? FOR UPDATE",
            undef, $slot_id
        );
        die "Booking not found.\n" unless $current;
        die "Only pending booking requests can be reviewed.\n" unless $current->{status} eq 'pending';
        my $updated = $dbh->do(
            "UPDATE streetbeats_slots SET status = ?, staff_note = ? WHERE slot_id = ? AND status = 'pending'",
            undef, $decision, $note, $slot_id
        );
        die( $dbh->errstr || "Could not update the booking.\n" ) unless defined($updated) && $updated == 1;
        $dbh->commit;
        1;
    };
    unless ($decided) {
        my $error = $@ || "Could not update the booking.\n";
        eval { $dbh->rollback; };
        die $error;
    }
    return $decision eq 'approved' ? 'Booking approved.' : 'Booking rejected; the slot is open again.';
}

# -------------------------------------------------------------------------
# LEGACY OPAC ENTRY POINT
# -------------------------------------------------------------------------
sub opac {
    my ($self) = @_;
    my $cgi = $self->{'cgi'};
    print $cgi->redirect('/api/v1/contrib/streetbeats/static/booking.html');
}

sub public_list {
    my ($self) = @_;
    my $cgi = $self->{'cgi'};
    print $cgi->redirect('/api/v1/contrib/streetbeats/static/booking.html');
}

sub configure {
    my ( $self, $args ) = @_;
    my $cgi = $self->{'cgi'};
    unless ( $self->_can_configure ) {
        print $cgi->redirect("/cgi-bin/koha/mainpage.pl");
        return;
    }

    my $output;
    my $ok = eval {
        my $dbh = C4::Context->dbh;
        my $message;
        if ( $cgi->request_method eq 'POST' ) {
            my $action = $cgi->param('action') // '';
            if ( $action eq 'save_branding' || $action eq 'reset_branding' ) {
                my %defaults = (
                    primary    => '#176B50',
                    header     => '#532C4D',
                    accent     => '#D6F06F',
                    background => '#F7F5F0',
                    surface    => '#FFFEFA',
                );
                my %setting_keys = (
                    primary    => 'STREETBEATS_BRAND_PRIMARY',
                    header     => 'STREETBEATS_BRAND_HEADER',
                    accent     => 'STREETBEATS_BRAND_ACCENT',
                    background => 'STREETBEATS_BRAND_BACKGROUND',
                    surface    => 'STREETBEATS_BRAND_SURFACE',
                );
                my %colors = %defaults;
                if ( $action eq 'save_branding' ) {
                    %colors = (
                        primary    => $cgi->param('brand_primary') // '',
                        header     => $cgi->param('brand_header') // '',
                        accent     => $cgi->param('brand_accent') // '',
                        background => $cgi->param('brand_background') // '',
                        surface    => $cgi->param('brand_surface') // '',
                    );
                    for my $name ( keys %colors ) {
                        die "Choose a valid hex color for every branding field.\n"
                            unless $colors{$name} =~ /\A#[0-9A-Fa-f]{6}\z/;
                        $colors{$name} = uc $colors{$name};
                    }
                    $message = 'Public page branding colors saved.';
                } else {
                    $message = 'Default StreetBeats branding colors restored.';
                }
                my %stored = map { $setting_keys{$_} => $colors{$_} } keys %colors;
                $self->store_data( \%stored );
            } elsif ( $action eq 'add_location' ) {
                my $name = $cgi->param('loc_name') // '';
                $name =~ s/^\s+|\s+$//g;
                die "Enter a location name.\n" unless length $name;
                $dbh->do(
                    "INSERT INTO streetbeats_locations (location_name, description, features) VALUES (?, ?, ?)",
                    undef, $name, ( $cgi->param('loc_desc') // '' ), ( $cgi->param('loc_features') // '' )
                );
                $message = 'Location added.';
            } elsif ( $action eq 'update_location' ) {
                my $location_id = $cgi->param('location_id') // '';
                my $name        = $cgi->param('loc_name') // '';
                $name =~ s/^\s+|\s+$//g;
                die "Enter a valid location and name.\n"
                    unless $location_id =~ /\A\d+\z/ && length $name;
                $dbh->do(
                    "UPDATE streetbeats_locations SET location_name = ?, description = ?, features = ? WHERE location_id = ?",
                    undef, $name, ( $cgi->param('loc_desc') // '' ), ( $cgi->param('loc_features') // '' ), $location_id
                );
                $message = 'Location updated.';
            } elsif ( $action eq 'publish_gig' ) {
                my $location_id = $cgi->param('location_id') // '';
                my $title       = $cgi->param('gig_title') // '';
                my $raw_time    = $cgi->param('start_time') // '';
                my $duration    = $cgi->param('duration_minutes') // '';
                $title =~ s/^\s+|\s+$//g;
                die "Choose a location, enter a title, and use a valid date and time.\n"
                    unless $location_id =~ /\A\d+\z/
                    && length $title
                    && $raw_time =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/
                    && $duration =~ /\A\d+\z/
                    && $duration >= 15
                    && $duration <= 480;
                my $start_time = $raw_time;
                $start_time =~ s/T/ /;
                $start_time .= ':00';
                my $is_future = $dbh->selectrow_array(
                    "SELECT STR_TO_DATE(?, '%Y-%m-%d %H:%i:%s') > NOW()",
                    undef, $start_time
                );
                my $location_exists = $dbh->selectrow_array(
                    "SELECT COUNT(*) FROM streetbeats_locations WHERE location_id = ?",
                    undef, $location_id
                );
                die "The time must be a valid future date, and the location must exist.\n"
                    unless $is_future && $location_exists;
                my $inserted = $dbh->do(
                    "INSERT INTO streetbeats_gigs (location_id, title, start_time, duration_minutes, details, is_published) VALUES (?, ?, ?, ?, ?, 1)",
                    undef, $location_id, $title, $start_time, $duration, ( $cgi->param('gig_details') // '' )
                );
                die( $dbh->errstr || "Could not publish this gig.\n" ) unless defined $inserted;
                $message = 'Gig published and available for booking.';
            } elsif ( $action eq 'update_gig' ) {
                my $gig_id      = $cgi->param('gig_id') // '';
                my $location_id = $cgi->param('location_id') // '';
                my $title       = $cgi->param('gig_title') // '';
                my $raw_time    = $cgi->param('start_time') // '';
                my $duration    = $cgi->param('duration_minutes') // '';
                my $is_published = $cgi->param('is_published') ? 1 : 0;
                $title =~ s/^\s+|\s+$//g;
                die "Enter a valid gig, venue, title, future time, and duration.\n"
                    unless $gig_id =~ /\A\d+\z/
                    && $location_id =~ /\A\d+\z/
                    && length $title
                    && $raw_time =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}\z/
                    && $duration =~ /\A\d+\z/
                    && $duration >= 15
                    && $duration <= 480;
                my $gig = $dbh->selectrow_hashref(
                    "SELECT location_id, start_time, is_published FROM streetbeats_gigs WHERE gig_id = ?",
                    undef, $gig_id
                );
                die "Gig not found.\n" unless $gig;
                my $start_time = $raw_time;
                $start_time =~ s/T/ /;
                $start_time .= ':00';
                my $is_future = $dbh->selectrow_array(
                    "SELECT STR_TO_DATE(?, '%Y-%m-%d %H:%i:%s') > NOW()",
                    undef, $start_time
                );
                my $location_exists = $dbh->selectrow_array(
                    "SELECT COUNT(*) FROM streetbeats_locations WHERE location_id = ?",
                    undef, $location_id
                );
                my $requires_future = $is_published
                    && ( !$gig->{is_published} || $location_id != $gig->{location_id} || $start_time ne $gig->{start_time} );
                die "A published gig must have a future time, and the venue must exist.\n"
                    unless ( !$requires_future || $is_future ) && $location_exists;
                my $has_booking = $dbh->selectrow_array(
                    "SELECT COUNT(*) FROM streetbeats_slots WHERE status IN ('pending', 'approved') AND (gig_id = ? OR (gig_id IS NULL AND location_id = ? AND start_time = ?))",
                    undef, $gig_id, $gig->{location_id}, $gig->{start_time}
                );
                die "Reject or cancel the active booking before changing its venue or time.\n"
                    if $has_booking
                    && ( $location_id != $gig->{location_id} || $start_time ne $gig->{start_time} );
                die "Use the cancel action to unpublish a gig that has an active booking.\n"
                    if $has_booking && !$is_published;
                my $updated = $dbh->do(
                    "UPDATE streetbeats_gigs SET location_id = ?, title = ?, start_time = ?, duration_minutes = ?, details = ?, is_published = ? WHERE gig_id = ?",
                    undef, $location_id, $title, $start_time, $duration, ( $cgi->param('gig_details') // '' ), $is_published, $gig_id
                );
                die( $dbh->errstr || "Could not update the gig.\n" ) unless defined $updated;
                $message = 'Gig updated.';
            } elsif ( $action eq 'cancel_gig' ) {
                my $gig_id = $cgi->param('gig_id') // '';
                die "Choose a valid gig.\n" unless $gig_id =~ /\A\d+\z/;
                $dbh->begin_work;
                my $cancelled = eval {
                    my $gig = $dbh->selectrow_hashref(
                        "SELECT location_id, start_time FROM streetbeats_gigs WHERE gig_id = ? FOR UPDATE",
                        undef, $gig_id
                    );
                    die "Gig not found.\n" unless $gig;
                    my $note = $cgi->param('staff_note') // '';
                    $note =~ s/^\s+|\s+$//g;
                    die "Staff notes must be 1,000 characters or fewer.\n" if length($note) > 1000;
                    $note ||= 'Gig cancelled by library staff.';
                    my $updated_slots = $dbh->do(
                        "UPDATE streetbeats_slots SET status = 'cancelled', staff_note = ? WHERE status IN ('pending', 'approved') AND (gig_id = ? OR (gig_id IS NULL AND location_id = ? AND start_time = ?))",
                        undef, $note, $gig_id, $gig->{location_id}, $gig->{start_time}
                    );
                    die( $dbh->errstr || "Could not cancel active bookings.\n" ) unless defined $updated_slots;
                    my $updated_gig = $dbh->do( "UPDATE streetbeats_gigs SET is_published = 0 WHERE gig_id = ?", undef, $gig_id );
                    die( $dbh->errstr || "Could not cancel the gig.\n" ) unless defined $updated_gig;
                    $dbh->commit;
                    1;
                };
                unless ($cancelled) {
                    my $error = $@ || "Could not cancel the gig.\n";
                    eval { $dbh->rollback; };
                    die $error;
                }
                $message = 'Gig cancelled. Any pending or approved bookings were marked cancelled.';
            }
        }

        my $locations = $dbh->selectall_arrayref(
            "SELECT location_id, location_name, description, features FROM streetbeats_locations ORDER BY location_name",
            { Slice => {} }
        );
        my $gigs = $dbh->selectall_arrayref(
            "SELECT g.*, l.location_name, (SELECT COUNT(*) FROM streetbeats_slots s WHERE s.location_id = g.location_id AND s.start_time = g.start_time AND s.status IN ('pending', 'approved')) AS booking_count, (SELECT COUNT(*) FROM streetbeats_slots s WHERE s.location_id = g.location_id AND s.start_time = g.start_time AND s.status = 'pending') AS pending_count FROM streetbeats_gigs g JOIN streetbeats_locations l ON l.location_id = g.location_id ORDER BY g.start_time DESC",
            { Slice => {} }
        );
        for my $gig ( @{$gigs} ) {
            $gig->{start_time_local} = substr( $gig->{start_time} // '', 0, 16 );
            $gig->{start_time_local} =~ s/ /T/;
        }
        my $session_id = $cgi->cookie('CGISESSID');
        my $csrf_token = $session_id
            ? Koha::Token->new->generate_csrf( { session_id => $session_id } )
            : '';
        my %brand_defaults = (
            primary    => '#176B50',
            header     => '#532C4D',
            accent     => '#D6F06F',
            background => '#F7F5F0',
            surface    => '#FFFEFA',
        );
        my %brand_setting_keys = (
            primary    => 'STREETBEATS_BRAND_PRIMARY',
            header     => 'STREETBEATS_BRAND_HEADER',
            accent     => 'STREETBEATS_BRAND_ACCENT',
            background => 'STREETBEATS_BRAND_BACKGROUND',
            surface    => 'STREETBEATS_BRAND_SURFACE',
        );
        my %brand_colors = map {
            $_ => $self->retrieve_data( $brand_setting_keys{$_} ) || $brand_defaults{$_}
        } keys %brand_defaults;
        for my $name ( keys %brand_colors ) {
            $brand_colors{$name} = $brand_defaults{$name}
                unless $brand_colors{$name} =~ /\A#[0-9A-Fa-f]{6}\z/;
            $brand_colors{$name} = uc $brand_colors{$name};
        }
        my $template = $self->get_template( { file => 'streetbeats/configure.tt' } );
        $template->param(
            install_error       => $self->retrieve_data('__STREETBEATS_INSTALL_ERROR__'),
            locations           => $locations,
            gigs                => $gigs,
            message             => $message,
            csrf_token          => $csrf_token,
            public_booking_path => '/api/v1/contrib/streetbeats/static/booking.html',
            brand_colors        => \%brand_colors,
        );
        $output = $template->output();
        1;
    };

    return $self->_output_runtime_error($@) unless $ok;
    $self->output_html($output);
}

sub _output_runtime_error {
    my ( $self, $error ) = @_;
    my $cgi = $self->{'cgi'};
    $error ||= 'Unknown StreetBeats runtime error';
    print $cgi->header( -type => 'text/html', -charset => 'utf-8' );
    print '<!doctype html><html lang="en"><head><meta charset="utf-8"><title>StreetBeats error</title></head><body>';
    print '<h1>StreetBeats encountered an error</h1><p>Share this message with your Koha administrator:</p><pre>';
    print $cgi->escapeHTML($error);
    print '</pre></body></html>';
    return;
}

sub _can_configure {
    my ($self) = @_;
    my $userenv = C4::Context->userenv;
    return 0 unless $userenv && $userenv->{id};
    return 1 if ( ( $userenv->{flags} // 0 ) & 1 );
    return haspermission( $userenv->{id}, { plugins => 'configure' } ) ? 1 : 0;
}

sub _can_manage {
    my ($self) = @_;
    my $userenv = C4::Context->userenv;
    return 0 unless $userenv && $userenv->{id};
    return 1 if ( ( $userenv->{flags} // 0 ) & 1 );
    return 1 if haspermission( $userenv->{id}, { plugins => 'manage_streetbeats' } );
    return haspermission( $userenv->{id}, { plugins => 'configure' } ) ? 1 : 0;
}

sub _is_http_url {
    my ( $self, $value ) = @_;
    return defined $value && $value =~ m{\Ahttps?://[^\s]+\z}i;
}

sub is_slot_available {
    my ( $self, $location_id, $start_time ) = @_;
    my $count = C4::Context->dbh->selectrow_array("SELECT COUNT(*) FROM streetbeats_slots WHERE location_id = ? AND start_time = ? AND status IN ('pending', 'approved')", undef, $location_id, $start_time);
    return $count == 0;
}

sub install {
    my ( $self, $args ) = @_;
    return $self->_ensure_schema;
}

sub upgrade {
    my ( $self, $args ) = @_;
    return $self->_ensure_schema;
}

sub _ensure_schema {
    my ($self) = @_;
    my $dbh = C4::Context->dbh;
    my @statements = (
        q{CREATE TABLE IF NOT EXISTS streetbeats_locations (location_id INT(11) NOT NULL AUTO_INCREMENT, location_name VARCHAR(255) NOT NULL, description TEXT, PRIMARY KEY (location_id)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4},
        q{CREATE TABLE IF NOT EXISTS streetbeats_profiles (borrowernumber INT(11) NOT NULL, band_name VARCHAR(255) NULL, genre VARCHAR(255) NULL, bio TEXT, tip_link VARCHAR(1000), social_link VARCHAR(1000), image_url VARCHAR(1000), technical_needs TEXT, PRIMARY KEY (borrowernumber), CONSTRAINT fk_sb_profile_patron FOREIGN KEY (borrowernumber) REFERENCES borrowers (borrowernumber) ON DELETE CASCADE) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4},
        q{CREATE TABLE IF NOT EXISTS streetbeats_slots (slot_id INT(11) NOT NULL AUTO_INCREMENT, borrowernumber INT(11) NOT NULL, location_id INT(11) NOT NULL, start_time DATETIME NOT NULL, gig_id INT(11) NULL, status VARCHAR(16) NOT NULL DEFAULT 'approved', staff_note TEXT NULL, PRIMARY KEY (slot_id), CONSTRAINT fk_sb_patron FOREIGN KEY (borrowernumber) REFERENCES borrowers (borrowernumber) ON DELETE CASCADE, CONSTRAINT fk_sb_location FOREIGN KEY (location_id) REFERENCES streetbeats_locations (location_id) ON DELETE CASCADE) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4},
        q{CREATE TABLE IF NOT EXISTS streetbeats_gigs (gig_id INT(11) NOT NULL AUTO_INCREMENT, location_id INT(11) NOT NULL, title VARCHAR(255) NOT NULL, start_time DATETIME NOT NULL, duration_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 60, details TEXT, is_published TINYINT(1) NOT NULL DEFAULT 1, PRIMARY KEY (gig_id), UNIQUE KEY uq_streetbeats_gig_time (location_id, start_time), KEY ix_streetbeats_gig_public (is_published, start_time)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4},
        q{INSERT IGNORE INTO permissions (module_bit, code, description) VALUES (19, 'manage_streetbeats', 'Access to manage StreetBeats musician bookings')}
    );

    my $installed = eval {
        for my $statement (@statements) {
            my $result = $dbh->do($statement);
            die( $dbh->errstr || 'A StreetBeats installation query failed' ) unless defined $result;
        }
        my @columns = (
            [ 'streetbeats_locations', 'features',          'TEXT NULL' ],
            [ 'streetbeats_profiles',  'band_name',         'VARCHAR(255) NULL' ],
            [ 'streetbeats_profiles',  'genre',             'VARCHAR(255) NULL' ],
            [ 'streetbeats_profiles',  'technical_needs',   'TEXT NULL' ],
            [ 'streetbeats_profiles',  'social_link',       'VARCHAR(1000) NULL' ],
            [ 'streetbeats_profiles',  'image_url',         'VARCHAR(1000) NULL' ],
            [ 'streetbeats_profiles',  'tip_link',          'VARCHAR(1000) NULL' ],
            [ 'streetbeats_slots',     'gig_id',            'INT(11) NULL' ],
            [ 'streetbeats_slots',     'status',            q{VARCHAR(16) NOT NULL DEFAULT 'approved'} ],
            [ 'streetbeats_slots',     'staff_note',        'TEXT NULL' ],
        );
        for my $column (@columns) {
            my ( $table, $name, $definition ) = @{$column};
            my $exists = $dbh->selectrow_array(
                "SELECT COUNT(*) FROM information_schema.COLUMNS WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = ? AND COLUMN_NAME = ?",
                undef, $table, $name
            );
            unless ($exists) {
                my $result = $dbh->do("ALTER TABLE `$table` ADD COLUMN `$name` $definition");
                die( $dbh->errstr || "Could not add $table.$name" ) unless defined $result;
            }
        }
        my $profile_lengths = $dbh->do(
            "ALTER TABLE streetbeats_profiles MODIFY COLUMN social_link VARCHAR(1000) NULL, MODIFY COLUMN image_url VARCHAR(1000) NULL, MODIFY COLUMN tip_link VARCHAR(1000) NULL"
        );
        die( $dbh->errstr || 'Could not update artist profile link fields' ) unless defined $profile_lengths;
        1;
    };

    unless ($installed) {
        my $error = $@ || 'Unknown installation error';
        $error =~ s/\s+\z//;
        eval { $self->store_data( { '__STREETBEATS_INSTALL_ERROR__' => $error } ); };
        warn "StreetBeats plugin installation failed: $error";
        return 0;
    }

    $self->store_data( { '__STREETBEATS_INSTALL_ERROR__' => '' } );
    return 1;
}

sub uninstall {
    my ( $self, $args ) = @_;
    C4::Context->dbh->do("DELETE FROM permissions WHERE code = 'manage_streetbeats'");
    return 1;
}

1;
