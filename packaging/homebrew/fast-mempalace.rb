# Homebrew formula for fast-mempalace.
# Lives in the tap repo (debpalash/homebrew-fast-mempalace); this copy is kept
# in-tree for reference. Binary sha256s are filled from the release .sha256
# artifacts by scripts/update-tap.sh.
class FastMempalace < Formula
  desc "Local-first long-term memory for AI coding agents"
  homepage "https://github.com/debpalash/fast-mempalace"
  version "0.2.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/debpalash/fast-mempalace/releases/download/v0.2.0/fast-mempalace-darwin-aarch64.tar.gz"
      sha256 "REPLACE_DARWIN_AARCH64"
    end
    on_intel do
      url "https://github.com/debpalash/fast-mempalace/releases/download/v0.2.0/fast-mempalace-darwin-x86_64.tar.gz"
      sha256 "REPLACE_DARWIN_X86_64"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/debpalash/fast-mempalace/releases/download/v0.2.0/fast-mempalace-linux-aarch64.tar.gz"
      sha256 "REPLACE_LINUX_AARCH64"
    end
    on_intel do
      url "https://github.com/debpalash/fast-mempalace/releases/download/v0.2.0/fast-mempalace-linux-x86_64.tar.gz"
      sha256 "REPLACE_LINUX_X86_64"
    end
  end

  # MiniLM-L6-v2, 384-dim embedding model (must match the float[384] schema).
  resource "model" do
    url "https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/main/all-MiniLM-L6-v2.F16.gguf"
    sha256 "797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662"
  end

  def install
    libexec.install "fast-mempalace"
    resource("model").stage do
      libexec.install "all-MiniLM-L6-v2.F16.gguf" => "minilm.gguf"
    end
    # Wrapper pins the bundled model so the binary works with zero config.
    (bin/"fast-mempalace").write <<~SH
      #!/bin/bash
      export FAST_MEMPALACE_MODEL="${FAST_MEMPALACE_MODEL:-#{libexec}/minilm.gguf}"
      exec "#{libexec}/fast-mempalace" "$@"
    SH
  end

  def caveats
    <<~EOS
      Add persistent memory to Claude Code:
        /plugin marketplace add MemPalace/fast-mempalace
        /plugin install fast-mempalace

      Memory lives in a single local palace; nothing leaves your machine.
    EOS
  end

  test do
    system bin/"fast-mempalace", "init"
    assert_match "Memory Palace Stats", shell_output("#{bin}/fast-mempalace stats")
  end
end
