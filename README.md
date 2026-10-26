# todo

A to-do list on your Mac that lives in the background and answers to one
keystroke.

- **⌥Space** — show the list, or put it away if it is already up
- **⌃⌥⌘Q** — quit

No Dock icon. No menu bar icon. Nothing to click. It runs, it costs about 8 MB,
and it gets out of the way.

## Install

```bash
./build-app.sh --install
```

That compiles it, assembles `/Applications/todo.app`, ad-hoc signs it and
registers it with Spotlight. No Xcode required — only the Command Line Tools
(`xcode-select --install`) and a Swift 5.9+ toolchain, both of which you
already have.

**To run it:** press ⌘Space, type `todo`, press Return.

**To remove it:** `./uninstall.sh` (add `--purge` to delete your list too).

## Using it

The panel opens centred on whichever screen your pointer is on, with the caret
already in the input.

**Every time you open it, it comes back to a blank prompt** — never to the
settings screen, and never with a task still selected. Resuming where you left
off is the wrong default: the first keypress lands somewhere you did not
expect, and Space would tick a task you had forgotten about instead of doing the
thing you opened the panel for.

A half-typed draft is deliberately *kept*, though. Reopening the panel is no
reason to throw away something you already typed.

| Key | Does |
|---|---|
| type, then **Return** | add a task, and stay in the bar for the next one |
| **⌘A** | select all the text you have typed |
| **↓** | move focus into the list |
| **↑** | from the prompt, jump to the bottom of the list |
| **↑ ↓** | move the selection |
| **Return** | add a sub-task under whatever is highlighted |
| **⇧Return** | edit the highlighted task's title, caret at the end |
| **← →** | edit the highlighted task's title, caret at the start / end |
| **Tab** | on a task with sub-tasks, open or close them; on one with none, turn it into a list |
| **⇧↑ ⇧↓** | extend the selection to the next task |
| **⌘A** | select every task on screen, sub-tasks included |
| **Space** | tick the selected task off (or back on), then move to the next |
| **Delete** / **⌫** | remove the selected task |
| **⇧⌫** | throw away everything already finished |
| **⌘Z** | undo — bring back a deleted task, or untick a ticked one |
| **⇧⌘Z** or **⌘Y** | redo |
| **Esc** | back to the input field |
| **Esc** | close the panel |
| **⌥Space** | close the panel from anywhere |

**Space** moves on to the next task afterwards. Ticking is the action you repeat
most — working down a day's list, Space, Space, Space — and a ticked task sinks
to the finished group at the bottom, so leaving the highlight on it would throw
you to the bottom of the list once per task and then throw you straight back.
The highlight goes to whatever row took its place instead, which is also what
deleting already did. Tick several at once with **⌘A** and the selection stays
put, because after a mass tick there is no "next".

**⇧⌫** clears the finished tasks in one go. Without it the list fills with
struck-through rows and the work still to do gets pushed off the bottom of the
panel; the only other route was picking each finished task out one at a time.
It appears in the footer as soon as there is anything to clear.

**Tab** opens and closes a task's sub-tasks. On a task that already has some it
opens the branch and closes it again on the next press. On a task with nothing
under it there is no branch to open or close, so it turns the task into a list:
branch open, blank `> add a sub task` row under it, caret in the row. That is
what **Return** does too — two roads to one place, rather than one key doing
two unrelated jobs and the only way to tell which had happened being to look at
the screen. The `>` at the right of a task points down while it is open, and
only appears on a task that has something under it: a task nobody has put a
sub-task under is just a task, and a column of arrows down a flat list of
reminders says otherwise.

**Return** at the top prompt adds a task and leaves the caret where it is. It
used to add the task *and* open it *and* drop you into a sub-task row beneath
it, so writing three reminders left three opened branches with nothing in them,
an arrow on every row, and the keyboard somewhere nobody had asked it to be.
Return is "one more thing", so the next Return is the next thing.

**Return** in the list adds a sub-task: it opens the highlighted task's branch
and puts a blank row under it, caret and all. On a sub-task it resolves through
to the parent, so it adds a *sibling*. The blank row only appears when you ask
for it — it used to sit under every open branch, which is clutter to read past
— and a row you look at and then leave without typing in is taken away
completely, leaving nothing behind for **⌘Z** to undo.

**⇧Return**, and **←** and **→**, correct the highlighted task's title where it
stands. ⇧Return puts the caret at the end, ← or → at whichever end you point at,
because that is the decision you are making: a word missing from the end, or a
misspelling at the front. **Return** keeps the new title, **Esc** puts the old
one back, and the keyboard goes back to the list with the row still selected —
so fixing a spelling and carrying on with the day is one movement.

Once you are in one:

- **Return** saves the sub-task and leaves a fresh blank row underneath, for
  writing several in a row. **⇧Return** does exactly the same thing: it used to
  be the only key that kept you in the row, so it is an alias now rather than a
  second verb.
- **Return** on an *empty* row is the way out: the row is taken away and the
  caret goes back to the add-a-task bar.
- **↑ ↓** step through the list from that row, and moving away takes an unused
  blank row with it. One you have typed into stays.
- **Delete** on it takes the row away; the sub-tasks and the branch stay.
- **Esc** takes an unused row away too, and leaves one you have typed into.
- Clicking it puts the caret in it.

The list is a loop you can walk out of at either end: **↑** off the top task and
**↓** off the bottom task both return to the add-a-task bar, and so does **Esc**
from anywhere in the list.

Picking is one task at a time. **↓** onto a parent highlights that parent and
nothing else, and a plain click does the same, even when there are sub-tasks
underneath. Branches only come in when you ask: **⌘-click** adds or removes a
single row, **⇧-click** takes every row the range crosses including nested ones,
and **⌘A** selects everything on screen. Deleting a task still takes its
sub-tasks with it.

The `>` prompt markers are always green — they mark a place you can type, not a
place you currently are. The one marker that carries state is a task's `v`,
which is green while its sub-tasks are open and grey while they are closed.

Nesting is two levels: a task and its sub-tasks. A third was tried and dropped —
with **Return** appending into whatever is highlighted, one more level is one
more thing to think about while writing, and one more indent eating the width a
long title has to wrap into.

Sub-tasks are marked by an indent *and* a guide line down it. Indent alone was
not enough: by the third sub-task the parent is off the top of what you are
looking at, and the rows read as loose items that happen to sit a little
further right. The line is continuous, so membership is read from the line
rather than measured off the text.

A task only grows a `v` once it has something under it, and loses it again
when the last of that goes. Adding a task used to open it as well, so the caret
could drop straight into a sub-task row beneath it, and that state stuck: every
task ever added kept a permanent green arrow and an `"expanded": true` in the
file, including the great majority that never had a sub-task, so a plain list of
reminders looked like a tree.

Sub-tasks are listed oldest first, the opposite of the top level, so a list you
write down reads back in the order you wrote it.

More than one task can be picked at once, so Space and Delete apply to all of
them and a mass delete is undone by a single **⌘Z**. Picking a task picks its
sub-tasks with it, so a delete takes a whole branch. **Space** is the
exception: it ticks the task and leaves what is under it alone, because a
parent can be finished while something beneath it is still outstanding.

**⌘Z** picks its target by what you are touching. With the caret in the input
field it undoes your typing, because losing the characters you just typed is
worse than pressing it twice. With the field empty, or the keyboard in the
list, it undoes the last thing you did to the tasks.

Open tasks sit at the top, ticked-off ones sink to the bottom. The footer
counts top-level tasks only — a sub-task is a step *inside* a task, so
counting them made the number disagree with the rows on screen — and it spells
"sub task" as two words, which is the same as the placeholders. Once anything
is finished it adds "· N done": the same number **⇧⌫** is about to throw away.
The footer always tells you which keys are live right now.

Clicking `todo` in Spotlight while it is already running re-opens the panel
rather than doing nothing.

The panel belongs to every Space, so **⌥Space** works the same over a fullscreen
app as on the desktop, and it is raised well above the normal window level so
apps that raise their own window to go fullscreen cannot cover it.

## With the mouse

- **Click a task** — selects it and hands the keyboard to the list, so Space
  and Delete then act on whatever you just picked. Clicking never scrolls the
  list: the pointer has already put the row in front of you
- **⌘-click** — add or remove that one task and its sub-tasks from the
  selection, leaving the others alone
- **⇧-click** — select everything between the last pick and this one
- **Click the `[]` / `[x]`** — ticks that task off, and leaves the selection
  where it was
- **Click a highlighted task** — edits its title in place, caret at the end
- **Right-click a task** — mark done, edit title, or delete
- **The gear** — opens the settings screen

Editing a title in place is the fix for a typo. The only way to correct one
used to be deleting the task and typing it again, which lost its place in the
list *and* every sub-task under it over one wrong letter. It is on the row you
already have highlighted rather than behind a double-click: a second click on a
selected row is one movement, and a double-click is not something a trackpad
offers by accident. **Return** keeps the
new title, **Esc** puts the old one back, and the keyboard goes back to the
list with the row still selected — so fixing a spelling and carrying on with
the day is one movement. Clicking elsewhere or closing the panel keeps what
you typed, the same as a half-written task.

The selection is the row with a green edge, and it is always the row the next
keystroke will act on. Ticking one off hands the highlight to whatever slid into
the gap — a ticked task sinks to the bottom, so staying on it would throw you
there once and then, on the next Space, straight back. Deleting does the same.
Several tasks can be picked at once, and the highlight cannot wander onto the
wrong one when the list re-sorts underneath it, because the selection is a set
of tasks rather than a row number.

Clicking does not steal the keyboard while you are part-way through typing —
in the add-a-task bar or in a sub-task row. The hand-off only happens when the
field you are in is empty, so clicking a task mid-sentence will not swallow the
next keypress.

Your list is plain JSON at
`~/Library/Application Support/todo/todos.json` — readable, hand-editable, and
safe to delete. A copy of the run log lives beside it at `todo.log`.

## Settings

The gear in the bottom-right of the footer opens:

- **start at login** — via `SMAppService`, so it appears as a normal switch in
  System Settings ▸ General ▸ Login Items that you can also turn off there.
  Enabled automatically the first time the app runs.
- **open todo** / **quit todo** — click a box and press any combination you
  like. It registers immediately, so you can try one and feel it straight away.
  `Esc` cancels. A combination needs at least one modifier, otherwise it would
  swallow that key system-wide — a global shortcut for bare Space would break
  typing in every app. If the combination is already owned by something else,
  the old one is restored and the box says so.

## The shortcut works when the app is closed

⌥Space starts todo whether or not it is already running. macOS only delivers a
global hotkey to a process that registered it, and those registrations die with
the process — so a running-out-of-hotkey is the default behaviour of any app
that quits itself.

`todo-keep` fixes that. It is a small watcher bundled inside
`todo.app/Contents/Library/LoginItems/`, and it holds the shortcut **only while
the app is closed**. The two hand off in both directions:

- todo quits → it starts `todo-keep`
- `todo-keep` sees todo running → it exits
- ⌥Space while closed → `todo-keep` releases the shortcut, starts todo with
  `--show`, and exits

Releasing the shortcut *before* starting todo is deliberate. If both held it,
one keystroke would arrive twice and the panel would open and shut again.

Because exactly one of the two is alive at any moment, this costs nothing while
you are using the app, and while the app is closed you are paying for the
watcher instead of it.

One gap: a **force-quit** (⌘⌥Esc, or "Quit" from Activity Monitor) kills todo
without `applicationWillTerminate` running, so no watcher is started and the
shortcut stays dead until todo is launched once more. Quitting with **⌃⌥⌘Q**,
or Spotlight ▸ Quit, is the path that hands over properly.

If the shortcut ever stops working, `todo-keep.log` next to `todo.log` says why.

## How heavy is it

Measured on this Mac with `footprint(1)`, which is what macOS itself uses for
memory pressure:

| | Physical footprint |
|---|---|
| App closed, `todo-keep` holding the shortcut | **8.5 MB** |
| App running, panel closed | **8.4 MB** |
| Panel open | **19 MB** |

Activity Monitor will show something closer to 80 MB. That number counts
framework pages this app shares with every other SwiftUI app on your machine
and is not what the app actually occupies — `phys_footprint` is the one that
decides whether your machine feels slow.

## Rebuilding after a change

```bash
./build-app.sh --install   # compile, bundle, sign, install
./verify.sh                # self-test, then smoke test: launch, hotkeys, memory, stop
./verify.sh --screenshot   # ...and write build/panel.png
swift Tools/make-icon.swift && iconutil -c icns Resources/todo.iconset -o Resources/todo.icns
```

`todo --selftest` checks the rules that are easy to break quietly and cannot be
confirmed by looking at the screen: undo and redo, mass tick and mass delete,
every way of selecting more than one task, and the sub-task tree — cascade
delete, the depth limit, where the blank sub-task row lands in the tree, a
sub-task whose parent has gone missing, and a list file written before
sub-tasks existed. It also covers which field the caret is
in, where the caret lands when a title opens (counted in characters, not UTF-16
units), correcting a title and abandoning the correction, where the highlight
lands after a tick or a delete, an action that changes nothing not costing a
⌘Z, and opening a branch to type into it not costing one either. `verify.sh` runs it first, so a failure there is reported before
anything is installed.

It lives inside the executable rather than in a test target on purpose. This
machine has the Command Line Tools and no full Xcode, so there is no XCTest to
link against — and a test suite that cannot run is worse than none, because it
looks like coverage while checking nothing.

`todo --show` opens the panel at launch, which is what makes scripted testing
possible — otherwise the only way in is the hotkey. `todo --settings` opens the
settings popover on launch, for the same reason.

## Working on this

See [CONTRIBUTING.md](CONTRIBUTING.md) for the checks to run, the git
convention, and how a release is cut.

## Layout

```
Sources/todo/
├── main.swift                 AppKit entry point, .accessory activation policy
├── SelfTest.swift             `todo --selftest` — undo, redo, multi-select
Sources/todo-keep/
└── main.swift                 holds the shortcut while the app is closed
├── AppDelegate.swift          hotkey registration, Spotlight reopen handling
├── HotKey/GlobalHotKey.swift  Carbon RegisterEventHotKey wrapper
├── HotKey/Shortcut.swift      a shortcut, its display string, persistence
├── HotKey/HotKeyCenter.swift  registration + re-registering on change
├── Models/TodoItem.swift      Codable task, with its parent and whether it is open
├── Models/UUID+DraftRow.swift a stable identity for a blank sub-task row
├── Store/TodoStore.swift      JSON persistence, undo history, the task tree
├── Helpers/KeyWindow.swift    window that can take focus while an agent app
├── Helpers/PanelController.swift  show / hide / centre, and the ⌘A ⌘Z ⌘Y monitor
├── Helpers/HotKeyKeeper.swift  hand-off to todo-keep on quit
├── Helpers/Diag.swift         run log
├── Services/LoginItem.swift   SMAppService launch at login
└── Views/                     panel, prompt field, key catcher, recorder, theme
```

## Licence

GPL-3.0, inherited from Medo. See `LICENSE` and `NOTICE.md`.