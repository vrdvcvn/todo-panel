# Contributing

## Before you change anything

Run the checks. `verify.sh` builds, installs, self-tests and smoke-tests the
real app, and it takes under a minute:

```bash
./verify.sh
```

`todo --selftest` is the part that matters most. Undo, multi-select and the
sub-task tree are easy to break quietly and hard to confirm by looking at the
screen, so they are covered by 71 assertions run directly against the store and
the panel model.

There is no XCTest here: this machine has the Command Line Tools and no full
Xcode, so there is nothing to link. The checks live in the executable instead,
run by `verify.sh` before it installs anything.

## Never drive the GUI to test

Synthetic keystrokes and clicks go to the **frontmost application**, which is
whatever the user is actually using. Sending them during a test means fighting
whatever they are typing, and it corrupts both: a task created during a test run
came out as `olgo markt` because the two interleaved. Worse, a test that
interferes with the person using the machine is not a test, it is a bug.

So: **the self-test is the only thing that verifies behaviour.** `verify.sh` is
also safe — it quits the app by Apple event and reads the log, and sends no
keystrokes at all.

If something genuinely cannot be covered that way, it does not belong in an
automated check. Put it in front of the user as a question instead.

The reason this rule exists: the key rules used to live inside the SwiftUI
`PanelView`, and a `View` cannot be constructed in a command-line test without a
window server. So the only way to check them was to drive the real app on a
real desktop — and a bug got through exactly that way, in
`parentForNewSubtask`, where Shift+Return on a sub-task did nothing. That rule
is in the store now and has a test.

When a rule is worth getting right, it belongs in `TodoStore` or `PanelModel`
where a test can reach it, not in a view.

## Version control

The repository is the safety net. Work on `main`, commit in small pieces, and
each commit should leave the app building and passing `./verify.sh`.

**Ask before pushing to GitHub.** Version it, update the version notes, tag it
and push only when told to.

The one exception: if a change is big enough that getting half of it wrong
would be expensive to unpick, push first as a checkpoint and say so. That is a
judgement call, and it should be a deliberate one — push on `main` if the work
is already in a known-good state, or on a branch if it is not.

Before any push, check the working tree is what you think it is:

```bash
git status
git diff --stat
```

Build output, `.DS_Store` and the assembled `.app` are ignored. If something
generated ever gets committed by accident, say so rather than quietly rewriting
history.

## Releasing

1. `./verify.sh` — green, from a clean tree.
2. Bump `VERSION` in `build-app.sh` and `CFBundleShortVersionString` follows it.
3. Update `README.md` if behaviour changed.
4. Commit, tag, push:
   ```bash
   git commit -am "..."
   git tag -a v1.1.0 -m "..."
   git push origin main --follow-tags
   gh release create v1.1.0 --title "v1.1.0 — ..." --notes "..."
   ```

Version numbers are plain `MAJOR.MINOR.PATCH`, no `v` in the string itself.

## Style

Comments explain *why*, not *what*. The non-obvious decisions in here are
mostly AppKit behaviours that took a bug to find — Tab being swallowed by
key-view traversal, a field that cannot take first responder before it is in a
window, `NSWindow.isVisible` answering for every Space at once. Those are worth
a comment and a line of history, because the next person will otherwise "clean
them up" and reintroduce the bug.

Do not add a dependency without saying why. The whole point of this app is
sitting at 19 MB with no Xcode, and that is easy to give away quietly.
