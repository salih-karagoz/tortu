# Contributing to Tortu

## The open core model, stated plainly

Tortu is open source under Apache-2.0. There is also a paid build, and the
capabilities it adds are listed here in full rather than summarised: history
charts, growth charts, background monitoring and its threshold notifications,
scheduled profiles, the duplicate finder, the application uninstaller, rule
sync, and the live activity instrument. Contributions to this repository may
end up in that build, and you should know that before you send one.

What is *not* sold, by policy: the scanner, the rules engine, every rule that
deletes files, and the privileged helper. Code that runs as root or removes a
file stays readable by anyone. A pull request that moves one of those behind a
paid capability will be declined.

## Sign your commits off

Use the Developer Certificate of Origin. Add a sign-off line:

```sh
git commit -s -m "Add a rule for the SwiftPM build cache"
```

There is no separate contributor licence agreement. Apache-2.0 section 5
already places your contribution under the project's licence.

## Adding a cleanup rule

Most contributions are rules, and a rule is a JSON file. A good one:

- Names a directory that genuinely regenerates. If losing it costs the user
  work, it is not a cleanup rule.
- States the real cost in `cost`. "The next build is slower" is useful;
  "safe to delete" is not.
- Lists bundle identifiers in `blockedByProcesses` when an open application
  would be damaged, or when deleting an open file frees nothing because the
  kernel holds the blocks until the process exits.
- Uses `keepNewest` rather than `deleteAll` when a tool accumulates
  per-configuration directories.

`requiresRoot` rules can only ship in the bundled, signed set, because the
privileged helper resolves identifiers against its own copy and will refuse
anything else.

## Security

The helper is the part worth attacking. It accepts rule identifiers, never
paths and never rule definitions, and it validates the calling client's code
signature. If you find a way around either, please report it privately rather
than opening an issue.

## Running the tests

```sh
for package in Packages/*/; do (cd "$package" && swift test); done
```
