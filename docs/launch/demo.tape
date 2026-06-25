# VHS tape for the memxt demo GIF.
#   brew install vhs && vhs docs/launch/demo.tape    (run from repo root)
# Requires the binary + model installed at ~/.memxt (curl installer).

Output assets/demo.gif

Set Shell "bash"
Set FontSize 20
Set Width 1180
Set Height 680
Set Padding 26
Set Theme "Catppuccin Mocha"
Set TypingSpeed 35ms

# ── setup (hidden) ──
Hide
Type "export PATH=$HOME/.memxt/bin:$PATH" Enter
Type "export MEMXT_DB=/tmp/demo-palace.db MEMXT_MODEL=$HOME/.memxt/lib/minilm.gguf" Enter
Type 'ask() { memxt search "$1" 2>&1 | sed -n "1,7p"; }' Enter
Type "cd docs/launch/demo && rm -f /tmp/demo-palace.db* && memxt init >/dev/null 2>&1 && clear" Enter
Show

# ── mine a project ──
Type "# Your AI agent forgets your project between sessions. Give it a memory:" Enter
Sleep 1200ms
Type "memxt mine ./sample-project my-app" Enter
Sleep 3s

Hide
Type "clear" Enter
Show

# ── semantic recall #1 ──
Type "# Ask in plain English — semantic recall, not grep:" Enter
Sleep 900ms
Type "ask 'why is the file upload size limited?'" Enter
Sleep 3500ms

Hide
Type "clear" Enter
Show

# ── semantic recall #2 ──
Type "ask 'how do users sign in?'" Enter
Sleep 3500ms

Hide
Type "clear" Enter
Show

# ── the pitch ──
Type "# One static binary. Fully local. Nothing leaves your machine." Enter
Sleep 800ms
Type "# In Claude Code: /plugin install memxt  →  memory_search, hooks, auto-save." Enter
Sleep 3s
