# Launch kit

Assets for launching fast-mempalace.

- **`show-hn.md`** — the launch post (Show HN / r/LocalLLaMA / r/mcp). Builder voice,
  reproducible numbers, no superlatives. Includes title options.
- **`demo.tape`** — [VHS](https://github.com/charmbracelet/vhs) script that renders
  `../../assets/demo.gif`. Run from the repo root:

  ```bash
  brew install vhs                 # needs ttyd + ffmpeg (pulled in)
  curl -fsSL .../install.sh | bash # the demo uses the installed binary + model
  vhs docs/launch/demo.tape
  ```

- **`demo/sample-project/`** — the tiny project the demo mines (clear, recall-worthy
  decisions). Self-contained and reproducible.

## Launch sequence (from the strategy)

1. Publish `show-hn.md` as a post on your own domain (the benchmark/demo *is* the launch).
2. **Show HN**, Tue–Thu 9–11am ET. First comment = problem → why Zig → reproduce-it link. Camp the thread.
3. Same day: **r/LocalLLaMA** + **r/mcp** (lead with the GIF, builder voice).
4. Timed **X/Twitter** thread: GIF first, benchmark image second.
5. PRs into **awesome-mcp-servers** ("Knowledge & Memory"), **awesome-claude-code**, **awesome-zig**.
6. Newsletter pitches: Latent Space, TLDR AI, Simon Willison.

Top 3 things that would sink it: unreproducible benchmarks, corporate/superlative voice,
a broken `curl | sh` on a clean box during the spike. Test the installer on a fresh VM first.
