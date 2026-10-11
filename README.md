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
| type, then **Return** | add a task |
| **⌘A** | select all the text you have typed |
| **↓** | move focus into the list |
| **↑ ↓** | move the selection |
| **Tab** | open or close a task's sub-tasks |
| **⇧Return** | add a sub-task under whatever is highlighted |
| **⇧↑ ⇧↓** | extend the selection to the next task |
| **⌘A** | select every task on screen, sub-tasks included |
| **Space** | tick the selected task off (or back on) |
| **Delete** / **⌫** | remove the selected task |
| **⌘Z** | undo — bring back a deleted task, or untick a ticked one |
| **⇧⌘Z** or **⌘Y** | redo |
| **Return** or **Esc** | back to the input field |
| **Esc** | close the panel |
| **⌥Space** | close the panel from anywhere |

**Tab** opens and closes a task's sub-tasks. On a task with nothing under it
yet it opens the branch and drops you into a blank row to type a sub-task. On a
task that already has some, it opens the branch and highlights the first
sub-task instead — re-opening something should show you what is in it, not
throw you past all of it to an empty prompt. The `>` at the right of a task
points down while it is open.

**⇧Return** is how you add a sub-task without going through Tab. With any task
highlighted it opens that task's branch and puts a blank `> add a sub task` row
under it, caret and all. That matters because the blank row now only appears
when you ask for it: it used to sit under every open branch, which is clutter
to read past.

Once you are in one:

- **Return** saves the sub-task and hands the caret back to the add-a-task bar.
  The blank row goes with it.
- **⇧Return** saves it and leaves a fresh blank row underneath, for writing
  several in a row.
- **↑ ↓** step through the list from that row, and moving away takes an unused
  blank row with it. One you have typed into stays.
- **Delete** on it takes the row away; the sub-tasks and the branch stay.
- Clicking it puts the caret in it.

The list is a loop you can walk out of at either end: **↑** off the top task and
**↓** off the bottom task both return to the add-a-task bar, which is what Tab
used to do.

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
with **⇧Return** appending into whatever is highlighted, one more level is one
more thing to think about while writing, and one more indent eating the width a
long title has to wrap into.

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
always tells you which keys are live right now — and spells "sub task" as two
words, which is the same as the placeholders.

Clicking `todo` in Spotlight while it is already running re-opens the panel
rather than doing nothing.

The panel belongs to every Space, so **⌥Space** works the same over a fullscreen
app as on the desktop, and it is raised well above the normal window level so
apps that raise their own window to go fullscreen cannot cover it.

## With the mouse

- **Click a task** — selects it and hands the keyboard to the list, so Space
  and Delete then act on whatever you just picked
- **⌘-click** — add or remove that one task and its sub-tasks from the
  selection, leaving the others alone
- **⇧-click** — select everything between the last pick and this one
- **Click the `[]` / `[x]`** — ticks that task off, and leaves the selection
  where it was
- **Right-click a task** — mark done, or delete
- **The gear** — opens the settings screen

The selection is the row with a green edge. It follows the task around: tick one
off and the highlight travels down with it rather than jumping to whatever takes
its place. That is also why several tasks can be selected at once without the
highlight wandering onto the wrong one when the list re-sorts underneath it.

Clicking does not steal the keyboard while you are part-way through typing a
task — the hand-off only happens when the prompt is empty, so clicking a task
mid-sentence will not swallow the next keypress.

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
delete, the depth limit, a sub-task whose parent has gone missing, and a list
file written before sub-tasks existed. `verify.sh` runs it first, so a
failure there is reported before anything is installed.

It lives inside the executable rather than in a test target on purpose. This
machine has the Command Line Tools and no full Xcode, so there is no XCTest to
link against — and a test suite that cannot run is worse than none, because it
looks like coverage while checking nothing.

`todo --show` opens the panel at launch, which is what makes scripted testing
possible — otherwise the only way in is the hotkey. `todo --settings` opens the
settings popover on launch, for the same reason.

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