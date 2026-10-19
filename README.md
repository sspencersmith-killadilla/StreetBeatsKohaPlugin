# StreetBeats Koha plugin

## Staff setup

1. Install or replace the plugin package in Koha, then open **Plugins → StreetBeats → Configure**.
2. Optionally set the public page's primary, header, accent, page background, and card colors in **Public page branding** using the color pickers or pasted six-digit hex codes. Use **Restore defaults** to return to the StreetBeats palette.
3. Add each performance venue. Include practical details such as indoor/outdoor setting, power, seating, parking, accessibility, and sound limits.
4. Publish a specific dated performance slot with a title, venue, start time, duration, and patron-facing details.
5. Share `/api/v1/contrib/streetbeats/static/booking.html` through OPAC navigation or custom OPAC content.
6. Open the plugin's **running page** to review pending requests. The patron's Koha account and artist profile appear together. Approve or reject each request there; an optional staff note is visible to that patron in their booking portal.

## Patron booking and profile

Anyone can browse future published gigs without signing in. Open slots can be requested by a patron signed in with their Koha account after they save an artist profile. Approved bookings appear publicly as confirmed shows, together with the artist name, genre, bio, image, social link, and optional tip link. Pending requests are not shown on the public schedule; setup and technical needs remain staff-only.

The public schedule appears before patron tools. When signed in, patrons can open the collapsed **Artist profile** section below the shows; the profile link on an open slot expands it automatically.

Public branding colors are saved in Koha's plugin settings and served to the schedule through the public `/api/v1/contrib/streetbeats/branding` endpoint. Only six-digit hex colors are accepted; the public page falls back to the built-in palette if the endpoint is unavailable.

The image field accepts a link to an externally hosted photo or logo; it does not upload image files. Links must use `http://` or `https://`.

Booking requests are **pending staff approval**. A pending request temporarily holds the slot; approval confirms it and publishes the show with the artist's public profile, while rejection reopens it for other patrons. Patrons can see pending, approved, rejected, or cancelled status under **My booking requests**.

## Editing and cancelling gigs

Staff can edit a gig's title, duration, details, visibility, venue, and time. If a gig has an active request or approved reservation, its venue and time are locked to preserve the booking; review or cancel the booking first. Use **Cancel gig** to unpublish a gig and mark any pending or approved bookings as cancelled. The optional cancellation note is shown to affected patrons.

## Koha 26.05 notes

The public page and reservation/profile endpoints use Koha's plugin REST API routes. If the public booking page returns 404 immediately after the plugin is upgraded, ask the Koha administrator to restart the Koha web/API application so it reloads plugin routes.

The upgrade adds profile fields and booking-review status while preserving existing venues, profiles, gigs, and reservations. Existing reservations are retained as approved bookings so they continue to block the slot.
