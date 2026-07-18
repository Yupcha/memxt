# VHS tape for the `memxt demo` tour GIF.
#   brew install vhs && vhs docs/launch/demo-tour.tape    (run from repo root)
# Records the built-in 60-second tour: paraphrase recall + live repo mine.
# Uses the repo-local binary (zig-out/bin) so the tape always records the
# code in the working tree, not whatever version is installed.

Output assets/demo-tour.gif

Set Shell "bash"
Set FontSize 17
Set Width 1240
Set Height 640
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms
Set Framerate 10

# ── setup (hidden): repo-local binary, staged (slide) mode ──
Hide
Type "export PATH=$PWD/zig-out/bin:$PATH MEMXT_DEMO_STAGED=1 && clear" Enter
Show

# ── one command, the whole story ──
Type "memxt demo" Enter
Sleep 22s

# hold the closing frame (token math + CTA) long enough to read
Sleep 5s
