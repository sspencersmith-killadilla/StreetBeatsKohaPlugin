package Koha::Plugin::Com::McKinney::StreetBeats::BookingController;

use Modern::Perl;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON ();

use C4::Auth qw(haspermission);
use C4::Context;
use Koha::Token;

sub list_gigs {
    my $c = shift;
    $c->openapi->valid_input or return;

    my $gigs = C4::Context->dbh->selectall_arrayref(
        q{
            SELECT
                g.gig_id,
                g.title,
                g.start_time,
                g.duration_minutes,
                COALESCE(g.details, '') AS details,
                l.location_name,
                COALESCE(l.description, '') AS description,
                COALESCE(l.features, '') AS features,
                CASE WHEN booked.slot_id IS NULL THEN 'open' ELSE 'approved' END AS booking_status,
                COALESCE(p.band_name, '') AS artist_name,
                COALESCE(p.genre, '') AS artist_genre,
                COALESCE(p.bio, '') AS artist_bio,
                COALESCE(p.image_url, '') AS artist_image_url,
                COALESCE(p.social_link, '') AS artist_social_link,
                COALESCE(p.tip_link, '') AS artist_tip_link
            FROM streetbeats_gigs g
            JOIN streetbeats_locations l ON l.location_id = g.location_id
            LEFT JOIN streetbeats_slots booked
                ON booked.slot_id = (
                    SELECT s.slot_id
                    FROM streetbeats_slots s
                    WHERE (s.gig_id = g.gig_id
                           OR (s.gig_id IS NULL AND s.location_id = g.location_id AND s.start_time = g.start_time))
                      AND s.status = 'approved'
                    ORDER BY s.slot_id DESC
                    LIMIT 1
                )
            LEFT JOIN streetbeats_profiles p ON p.borrowernumber = booked.borrowernumber
            WHERE g.is_published = 1
              AND g.start_time > NOW()
              AND (
                  booked.slot_id IS NOT NULL
                  OR NOT EXISTS (
                      SELECT 1
                      FROM streetbeats_slots s
                      WHERE (s.gig_id = g.gig_id
                             OR (s.gig_id IS NULL AND s.location_id = g.location_id AND s.start_time = g.start_time))
                        AND s.status IN ('pending', 'approved')
                  )
              )
            ORDER BY g.start_time ASC
        },
        { Slice => {} }
    );

    return $c->render( status => 200, openapi => $gigs );
}

sub get_branding {
    my $c = shift;
    $c->openapi->valid_input or return;

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
    my $rows = C4::Context->dbh->selectall_arrayref(
        "SELECT plugin_key, plugin_value FROM plugin_data WHERE plugin_class = ? AND plugin_key IN (?, ?, ?, ?, ?)",
        { Slice => {} },
        'Koha::Plugin::Com::McKinney::StreetBeats',
        @setting_keys{qw(primary header accent background surface)}
    );
    my %stored_keys = reverse %setting_keys;
    for my $row ( @{$rows} ) {
        my $name = $stored_keys{ $row->{plugin_key} // '' };
        next unless $name && ( $row->{plugin_value} // '' ) =~ /\A#[0-9A-Fa-f]{6}\z/;
        $defaults{$name} = uc $row->{plugin_value};
    }
    return $c->render( status => 200, openapi => \%defaults );
}

sub get_profile {
    my $c = shift;
    $c->openapi->valid_input or return;
    my $patron = $c->stash('koha.user');
    return $c->render( status => 401, openapi => { error => 'Sign in to view your artist profile.' } )
        unless $patron;

    my $profile = C4::Context->dbh->selectrow_hashref(
        "SELECT band_name, genre, bio, social_link, image_url, tip_link, technical_needs FROM streetbeats_profiles WHERE borrowernumber = ?",
        undef, $patron->borrowernumber
    ) || {};
    for my $field (qw(band_name genre bio social_link image_url tip_link technical_needs)) {
        $profile->{$field} //= '';
    }
    return $c->render( status => 200, openapi => $profile );
}

sub save_profile {
    my $c = shift;
    $c->openapi->valid_input or return;
    my $patron = $c->stash('koha.user');
    return $c->render( status => 401, openapi => { error => 'Sign in to save your artist profile.' } )
        unless $patron;

    my $body = $c->req->json || {};
    my %profile = map { $_ => ( $body->{$_} // '' ) }
        qw(band_name genre bio social_link image_url tip_link technical_needs);
    $profile{band_name} =~ s/^\s+|\s+$//g;
    return $c->render( status => 400, openapi => { error => 'Enter a band or performer name.' } )
        unless length $profile{band_name};
    return $c->render( status => 400, openapi => { error => 'One or more profile fields are too long.' } )
        if length( $profile{band_name} ) > 255
        || length( $profile{genre} ) > 255
        || length( $profile{bio} ) > 4000
        || length( $profile{social_link} ) > 1000
        || length( $profile{image_url} ) > 1000
        || length( $profile{tip_link} ) > 1000
        || length( $profile{technical_needs} ) > 4000;
    for my $field (qw(social_link image_url tip_link)) {
        return $c->render( status => 400, openapi => { error => 'Social, image, and tip links must begin with http:// or https://.' } )
            if $profile{$field} ne '' && $profile{$field} !~ m{\Ahttps?://[^\s]+\z}i;
    }

    my $dbh = C4::Context->dbh;
    my $saved = $dbh->do(
        q{
            INSERT INTO streetbeats_profiles
                (borrowernumber, band_name, genre, bio, social_link, image_url, tip_link, technical_needs)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE
                band_name = VALUES(band_name),
                genre = VALUES(genre),
                bio = VALUES(bio),
                social_link = VALUES(social_link),
                image_url = VALUES(image_url),
                tip_link = VALUES(tip_link),
                technical_needs = VALUES(technical_needs)
        },
        undef,
        $patron->borrowernumber,
        @profile{qw(band_name genre bio social_link image_url tip_link technical_needs)}
    );
    return $c->render( status => 500, openapi => { error => 'The artist profile could not be saved. Please try again.' } )
        unless defined $saved;
    return $c->render( status => 200, openapi => { %profile } );
}

sub my_bookings {
    my $c = shift;
    $c->openapi->valid_input or return;
    my $patron = $c->stash('koha.user');
    return $c->render( status => 401, openapi => { error => 'Sign in to view your bookings.' } )
        unless $patron;

    my $bookings = C4::Context->dbh->selectall_arrayref(
        q{
            SELECT
                s.slot_id,
                s.status,
                COALESCE(s.staff_note, '') AS staff_note,
                s.start_time,
                l.location_name,
                COALESCE(g.title, 'StreetBeats performance') AS title
            FROM streetbeats_slots s
            JOIN streetbeats_locations l ON l.location_id = s.location_id
            LEFT JOIN streetbeats_gigs g
                ON g.gig_id = s.gig_id
                OR (s.gig_id IS NULL AND g.location_id = s.location_id AND g.start_time = s.start_time)
            WHERE s.borrowernumber = ?
            ORDER BY s.start_time DESC
        },
        { Slice => {} },
        $patron->borrowernumber
    );
    return $c->render( status => 200, openapi => $bookings );
}

sub session_info {
    my $c = shift;
    $c->openapi->valid_input or return;

    my $patron = $c->stash('koha.user');
    my $cookie = $c->cookie('CGISESSID');
    my $session_id = ref($cookie) && $cookie->can('value') ? $cookie->value : $cookie;
    my $token  = $patron && $session_id
        ? Koha::Token->new->generate_csrf( { session_id => $session_id } )
        : '';

    return $c->render(
        status  => 200,
        openapi => {
            logged_in  => $patron ? Mojo::JSON->true : Mojo::JSON->false,
            csrf_token => $token,
        }
    );
}

sub create_booking {
    my $c = shift;
    my $response;
    my $ok = eval {
        $response = _create_booking($c);
        1;
    };
    return $response if $ok;

    my $error  = $@ || 'Unknown booking error';
    my $patron = $c->stash('koha.user');
    warn "StreetBeats booking controller exception: $error";
    return $c->render(
        status  => 500,
        openapi => { error => _error_for_user( $patron, $error ) },
    );
}

sub _create_booking {
    my $c = shift;
    $c->openapi->valid_input or return;

    my $patron = $c->stash('koha.user');
    return $c->render( status => 401, openapi => { error => 'Sign in to your Koha account before reserving a gig.' } )
        unless $patron;
    my $has_profile = C4::Context->dbh->selectrow_array(
        "SELECT COUNT(*) FROM streetbeats_profiles WHERE borrowernumber = ? AND TRIM(COALESCE(band_name, '')) <> ''",
        undef, $patron->borrowernumber
    );
    return $c->render( status => 400, openapi => { error => 'Save your artist profile, including your band or performer name, before requesting a gig.' } )
        unless $has_profile;

    my $body   = $c->req->json || {};
    my $gig_id = $body->{gig_id} // '';
    return $c->render( status => 400, openapi => { error => 'A valid gig_id is required.' } )
        unless $gig_id =~ /\A\d+\z/;

    my $dbh          = C4::Context->dbh;
    my $failure_kind = '';
    my $ok           = eval {
        $dbh->begin_work;
        my $gig = $dbh->selectrow_hashref(
            "SELECT location_id, start_time FROM streetbeats_gigs WHERE gig_id = ? AND is_published = 1 AND start_time > NOW() FOR UPDATE",
            undef, $gig_id
        );
        unless ($gig) {
            $failure_kind = 'unavailable';
            die "StreetBeats gig is no longer available\n";
        }

        my $existing = $dbh->selectrow_array(
            "SELECT COUNT(*) FROM streetbeats_slots WHERE location_id = ? AND start_time = ? AND status IN ('pending', 'approved')",
            undef, $gig->{location_id}, $gig->{start_time}
        );
        if ($existing) {
            $failure_kind = 'reserved';
            die "StreetBeats gig is already reserved\n";
        }

        my $inserted = $dbh->do(
            "INSERT INTO streetbeats_slots (borrowernumber, location_id, start_time, gig_id, status) VALUES (?, ?, ?, ?, 'pending')",
            undef, $patron->borrowernumber, $gig->{location_id}, $gig->{start_time}, $gig_id
        );
        die( $dbh->errstr || "StreetBeats reservation insert failed\n" ) unless defined $inserted;
        $dbh->commit;
        1;
    };

    unless ($ok) {
        my $error = $@ || 'Unknown reservation error';
        eval { $dbh->rollback; };
        return $c->render( status => 404, openapi => { error => 'That gig is no longer available.' } )
            if $failure_kind eq 'unavailable';
        return $c->render( status => 409, openapi => { error => 'That gig has already been reserved.' } )
            if $failure_kind eq 'reserved';
        warn "StreetBeats booking failed: $error";
        return $c->render(
            status  => 500,
            openapi => { error => _error_for_user( $patron, $error ) },
        );
    }

    return $c->render(
        status  => 201,
        openapi => {
            gig_id  => 0 + $gig_id,
            message => 'Your request has been sent to staff for approval.',
        }
    );
}

sub _error_for_user {
    my ( $patron, $error ) = @_;
    my $is_staff = eval { $patron && haspermission( $patron->userid, { plugins => 'configure' } ) };
    return 'The reservation could not be completed. Please try again or contact library staff.'
        unless $is_staff;

    $error //= 'Unknown booking error';
    $error =~ s/[\r\n\t]+/ /g;
    $error =~ s/\s+/ /g;
    $error =~ s/^\s+|\s+$//g;
    $error =~ s/\b(password|secret|token)\b\s*[:=]\s*\S+/$1=[redacted]/ig;
    $error = substr( $error, 0, 240 );
    return "Reservation failed: $error";
}

1;
