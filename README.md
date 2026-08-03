# koha-plugin-late-payment-claiming

A Koha plugin that automates the dunning ("claiming") process for outstanding patron fees, with configurable escalation levels, letter templates, and follow-up actions.

## Overview

The plugin lets libraries define one or more escalation levels per branch and patron category. Each level specifies an outstanding-fee threshold, criteria for selecting which patrons are affected (patron category, patron attributes, restriction types, etc.), and actions to apply (e.g. account restrictions/bans). A nightly cron job checks a configurable schedule and, once a run is due, automatically identifies matching patrons, charges a dunning fee, and sends a letter (email and print templates are included) for the appropriate claim level.

Each dunning case is tracked as a "claim" with its own status (open, paused, closed) and a full history of every action taken against it (level, action, timestamp, staff member or automated run, applied restrictions). Optionally, the plugin can automatically close a claim once a patron's balance drops back below a configured threshold after a payment, reversing the associated restrictions at the same time.

## Features

- Configurable multi-level dunning rules per branch and patron category, each with its own fee threshold, patron selection criteria, and restriction/ban actions.
- Cron-style scheduling (month days, months, weekdays) for the automated nightly run, including handling of library closing days (skip, delay, or ignore).
- Interactive, on-demand claim run from the staff interface, in addition to the automated nightly run.
- Email and print letter templates for dunning notices, with the claim level and outstanding balance available as placeholders.
- Full claim history and an overview of currently open/paused/closed claims, filterable by branch and patron category.
- Optional automatic closing of a claim (and reversal of restrictions) once the outstanding balance falls below a configured amount after a payment.
- A warning banner on the patron's page in the staff interface when an open claim exists, linking to the claim details.
- A REST API endpoint (`/api/v1/contrib/latepaymentclaiming/...`) used by the staff interface to display claim information.

## Requirements

- Koha 22.11 or later.
- The Perl module **`DateTime::Event::Cron`**, which is used to evaluate the cron-style execution schedule (month days, months, weekdays) for the nightly claim run.

  This module is **not** bundled with Koha and must be installed on the server **before** installing the plugin. On Debian/Ubuntu systems, install it via the distribution package:

  ```bash
  sudo apt-get install libdatetime-event-cron-perl
  ```

  See the [Debian package tracker page](https://tracker.debian.org/pkg/libdatetime-event-cron-perl) for details. Alternatively, the module can be installed via CPAN (`cpanm DateTime::Event::Cron`), but the Debian package is the recommended and tested installation path.

## Installation

1. Install the `libdatetime-event-cron-perl` package on the Koha server as described above.
2. Download the plugin `.kpz` release (or build it from source) and upload it via *Administration → Manage plugins* in the Koha staff interface, or install it directly on the server following the standard Koha plugin installation process.
3. Enable the plugin and open its configuration page to define escalation levels, patron selection criteria, and the execution schedule.

## Configuration

From the plugin's configuration page you can set:

- Whether the automated nightly run is active, and its execution schedule (month days, months, weekdays, and whether/how library closing days are taken into account).
- A balance threshold below which an open claim is automatically closed after a payment, and whether this automatic closing is enabled.
- Per branch/category dunning rules: the fee threshold that triggers each level, the patron selection criteria, and the restriction/ban actions to apply.
- The letter templates and default texts used for the dunning charge and notice.

## License

GPL-3.0, see [LICENSE](LICENSE).
