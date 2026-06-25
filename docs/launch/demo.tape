# VHS tape for the fast-mempalace demo GIF.
#   brew install vhs && vhs docs/launch/demo.tape    (run from repo root)
# Requires the binary + model installed at ~/.fast-mempalace (curl installer).

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
Type "export PATH=$HOME/.fast-mempalace/bin:$PATH" Enter
Type "export FAST_MEMPALACE_DB=/tmp/demo-palace.db FAST_MEMPALACE_MODEL=$HOME/.fast-mempalace/lib/minilm.gguf" Enter
Type 'ask() { fast-mempalace search "$1" 2>&1 | sed -n "1,7p"; }' Enter
Type "cd docs/launch/demo && rm -f /tmp/demo-palace.db* && fast-mempalace init >/dev/null 2>&1 && clear" Enter
Show

# ── mine a project ──
Type "# Your AI agent forgets your project between sessions. Give it a memory:" Enter
Sleep 1200ms
Type "fast-mempalace mine ./sample-project my-app" Enter
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
Type "# In Claude Code: /plugin install fast-mempalace  →  memory_search, hooks, auto-save." Enter
Sleep 3s
