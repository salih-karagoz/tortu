# Contributing to Tortu

## The open core model, stated plainly

Tortu is open source under Apache-2.0, and there is nothing else. No paid
build, no Pro tier, no licence to buy: the application you download is this
repository compiled, with every capability in it.

That is a decision rather than a promise, so here is how it would change if it
ever did. It would be announced before it happened, it would never take away a
capability that already worked, and it would never cover the scanner, the rules
engine, a rule that deletes files, or the privileged helper — code that runs as
root or removes a file stays readable by anyone. A pull request that gates one
of those will be declined.

## Sign your commits off

Use the Developer Certificate of Origin. Add a sign-off line:

```sh
git commit -s -m "Add a rule for the SwiftPM build cache"
```

CI checks every commit in a pull request for a sign-off line matching that
commit's own author, and says which commit is missing one. `git rebase
--signoff main` fixes a branch that was written without it.

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
