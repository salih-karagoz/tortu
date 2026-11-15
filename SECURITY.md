# Security

Tortu deletes files, and one part of it does so as root. That is the whole
reason to look at it closely.

## Reporting a vulnerability

Use GitHub's private reporting:
[**Report a vulnerability**](https://github.com/salih-karagoz/tortu/security/advisories/new).
It opens a thread only you and the maintainer can read, which is the right
place for anything that would be harmful to publish first. Please do not open
a public issue for it.

Expect an acknowledgement within a week. If a report is confirmed, the fix and
the advisory are published together, and you are credited unless you ask not
to be.

## What is worth attacking

**The privileged helper** (`TortuHelper/`) is the part that runs as root. It is
built so that the client cannot tell it what to delete:

- It accepts a rule *identifier*, never a path and never a rule definition, and
  resolves that identifier against its own bundled copy of the rules. A client
  that asks for something not in that copy is refused.
- It validates the calling client's code signature before answering
  (`HelperIdentity`).
- `requiresRoot` rules therefore cannot be added by a pull request, an edited
  configuration file, or anything a user can write to.

A way around either check is the most serious thing you could find.

**Path safety** (`Packages/SafetyKit/`) is the second layer. `PathSafety`
refuses a target that is too shallow, resolves symlinks before deciding, and
refuses to leave the roots a rule declares. A rule or a crafted directory tree
that gets a deletion outside those bounds is a vulnerability even if no helper
is involved, because the unprivileged app can still delete anything the user
can.

## What is not a vulnerability

- A rule whose `cost` understates how annoying the loss is. That is a bug, and
  an issue is the right place for it.
- The app reading the user's own home directory, process list, battery and
  network counters. It is a disk and activity instrument; that is what it
  measures, it stays on the machine, and nothing is sent anywhere.
- `docs/screenshots/` showing real process names. Those are deliberate.

## Supported versions

The latest release, and `main`. There are no maintained older branches.
