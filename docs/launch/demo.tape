# VHS tape for the memxt demo GIF.
#   brew install vhs && vhs docs/launch/demo.tape    (run from repo root)
# Requires the memxt binary + MiniLM model installed at ~/.memxt (curl installer).

Output assets/demo.gif

Set Shell "bash"
Set FontSize 20
Set Width 1180
Set Height 720
Set Padding 26
Set Theme "Catppuccin Mocha"
Set TypingSpeed 30ms

# ── setup (hidden) ──
Hide
Type "export PATH=$HOME/.memxt/bin:$PATH" Enter
Type "export MEMXT_DB=/tmp/demo-palace.db MEMXT_MODEL=$HOME/.memxt/lib/minilm.gguf MEMXT_WING=my-app" Enter
Type 'ask() { memxt search "$1" --limit 1 2>&1 | grep -vE "^(Id:|─|Searching|$)"; echo; }' Enter
Type "cd docs/launch/demo && rm -f /tmp/demo-palace.db* && memxt init >/dev/null 2>&1 && clear" Enter
Show

# ── the problem + give it memory ──
Type "# Your coding agent forgets everything between sessions." Enter
Sleep 1300ms
Type "# Give it a memory palace — 100% local, nothing leaves your machine:" Enter
Sleep 900ms
Type "memxt mine ./sample-project my-app" Enter
Sleep 3500ms

Hide
Type "clear" Enter
Show

# ── plain-English recall (semantic + keyword, verbatim) ──
Type "# Now just ask, in plain English — no grep, no re-reading files:" Enter
Sleep 1100ms
Type "ask 'how do users sign in?'" Enter
Sleep 3200ms
Type "ask 'why are file uploads capped at 25 MB?'" Enter
Sleep 3200ms
Type "ask 'why Redis instead of Memcached?'" Enter
Sleep 3500ms

Hide
Type "clear" Enter
Show

# ── the pitch ──
Type "# Verbatim decisions. Semantic + keyword. All on your own disk." Enter
Sleep 1000ms
Type "# In Claude Code:  /plugin install memxt  ->  auto-save + recall, every session." Enter
Sleep 3200ms
