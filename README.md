# A09 Studio — setup guide

This gives you a SwiftUI Mac app that (1) edits and assembles 6809 code via
a fixed build of the `a09` assembler, and (2) drives a TL866 II+/CS EPROM
programmer through the open-source `minipro` CLI. Both are run as
subprocesses (`Process`), not linked in — that keeps the original,
proven `a09.c` logic completely untouched aside from the one bug fix, and
avoids reimplementing (or GPL-encumbering the app with) the TL866's
undocumented USB protocol.

I couldn't build/run this from here (no Xcode on this machine), so build
it step by step and tell me where anything doesn't match what you see —
happy to adjust.

## What's fixed in a09.c

The assembler called `strdup()` without a visible prototype. Under strict
C99/C11 compilation this makes the compiler implicitly assume it returns
`int`. On a 64-bit system the *real* return value is a 64-bit pointer, so
that implicit `int` truncates it to 32 bits and corrupts it — GCC only
warns about this, but Apple's Clang in current Xcode treats it as a hard
error by default, so the build fails on Mac. Fixed by adding a small
always-declared `a09_strdup()` shim near the top of the file (search for
"Portable replacement for strdup") instead of relying on the system
header. I compiled this with `-Werror=implicit-function-declaration
-Werror=int-conversion` (the flags that were breaking your build) and it
now passes clean, plus ran a small test program through it to confirm
correct opcode/address output.

## 1. Install minipro (for the TL866)

```
brew install minipro
```

Verify: `minipro -v` should print a version and list supported TL866
variants.

## 2. Create the Xcode project

1. Xcode → File → New → Project → macOS → **App**.
2. Product Name: `A09Studio`. Interface: **SwiftUI**. Language: **Swift**.
   Uncheck "Use Core Data" / "Include Tests" (not needed).
3. Save it wherever you keep your other RF tool projects.
4. Delete the auto-generated `ContentView.swift` and `A09StudioApp.swift`
   that Xcode created — you'll replace them with the versions here.
5. Drag the 5 files from this package's `A09StudioApp/` folder into the
   Xcode project navigator (into the `A09Studio` group), with **"Copy
   items if needed"** checked and the `A09Studio` app target checked.

At this point the app target should build and run (⌘R) — it'll show the
editor and toolbar, but "Assemble" will fail because the `a09` tool isn't
bundled yet. That's step 3.

## 3. Add the a09 command-line tool as a second target

1. File → New → Target → macOS → **Command Line Tool**. Name it `a09`.
   Language: **C**.
2. Xcode creates a `main.c` for that target — delete it, then drag in
   this package's `a09.c` (Copy items if needed, target = `a09` only,
   **not** the app target).
3. Select the `a09` target → Build Settings → search "C Language
   Dialect" → set to **GNU C11** (or C11 — either compiles cleanly with
   the fix; GNU C11 is closest to what the code was originally written
   against).
4. Build the `a09` target alone (select it as the active scheme, ⌘B) to
   confirm it compiles with no errors. You should see only the same
   harmless style warnings noted below, nothing about `strdup` or
   int-conversion.

## 4. Bundle the a09 binary into the app

1. Select the **A09Studio** app target → Build Phases tab.
2. Click **+** → **New Copy Files Phase**.
3. Destination: **Executables**.
4. Click **+** under that phase and add the `a09` product (it'll be
   listed under Products in the file picker, as the output of the `a09`
   target).
5. Build Phases → **Target Dependencies** → add `a09`, so the tool is
   always rebuilt before the app that bundles it.
6. Build and run the app (⌘R). Paste in some 6809 source, hit **Assemble**
   (⌘B in-app) — you should get a listing on the right and, for the
   sample program that's pre-loaded, "Build OK".

## 5. Sandboxing

Leave **App Sandbox turned off** (Signing & Capabilities tab) for now —
both `Process` subprocess launching and raw USB access via `minipro`
need it off. If you later want to distribute this outside your own Mac,
sandboxing + subprocess launching is solvable but needs its own pass
(XPC service or the newer network/USB entitlements); not worth doing
until the tool itself is proven out.

## 6. Using the programmer panel

Click **Programmer…** in the toolbar. Enter the chip's minipro device
name (e.g. `AT28C256`, `27C256`, `M27C512` — `minipro -L` in Terminal
lists everything minipro supports) and use Identify/Read/Write/Verify/
Erase. Write/Verify default to whatever you last successfully assembled;
"Choose…" lets you point at any other binary file instead.

## Known rough edges / good next steps

- Syntax highlighting is regex-based and simple (mnemonics, pseudo-ops,
  numbers, strings, comments) — fine to read code by, not a real
  tokenizer.
- Diagnostic line numbers are parsed from a09's own text output, which
  varies a little by error type; a few messages may show without a line
  number.
- No project/multi-file (INCLUDE) browsing yet — single source file only.
- No persisted app preferences yet (e.g. remembered device name, minipro
  path override) — trivial to add with @AppStorage once the basics feel
  right.

Let me know how far you get through the steps above and what Xcode shows
at each point — easiest to fix things one step at a time rather than
guessing at what might be different in your setup.
