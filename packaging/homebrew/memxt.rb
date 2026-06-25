# Homebrew formula for memxt.
# Lives in the tap repo (Yupcha/homebrew-memxt); this copy is kept
# in-tree for reference. Binary sha256s are filled from the release .sha256
# artifacts by scripts/update-tap.sh.
class Memxt < Formula
  desc "Local-first long-term memory for AI coding agents"
  homepage "https://github.com/Yupcha/memxt"
  version "0.2.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/Yupcha/memxt/releases/download/v0.2.0/memxt-darwin-aarch64.tar.gz"
      sha256 "REPLACE_DARWIN_AARCH64"
    end
    on_intel do
      url "https://github.com/Yupcha/memxt/releases/download/v0.2.0/memxt-darwin-x86_64.tar.gz"
      sha256 "REPLACE_DARWIN_X86_64"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/Yupcha/memxt/releases/download/v0.2.0/memxt-linux-aarch64.tar.gz"
      sha256 "REPLACE_LINUX_AARCH64"
    end
    on_intel do
      url "https://github.com/Yupcha/memxt/releases/download/v0.2.0/memxt-linux-x86_64.tar.gz"
      sha256 "REPLACE_LINUX_X86_64"
    end
  end

  # MiniLM-L6-v2, 384-dim embedding model (must match the float[384] schema).
  resource "model" do
    url "https://huggingface.co/leliuga/all-MiniLM-L6-v2-GGUF/resolve/main/all-MiniLM-L6-v2.F16.gguf"
    sha256 "797b70c4edf85907fe0a49eb85811256f65fa0f7bf52166b147fd16be2be4662"
  end

  def install
    libexec.install "memxt"
    resource("model").stage do
      libexec.install "all-MiniLM-L6-v2.F16.gguf" => "minilm.gguf"
    end
    # Wrapper pins the bundled model so the binary works with zero config.
    (bin/"memxt").write <<~SH
      #!/bin/bash
      export MEMXT_MODEL="${MEMXT_MODEL:-#{libexec}/minilm.gguf}"
      exec "#{libexec}/memxt" "$@"
    SH
  end

  def caveats
    <<~EOS
      Add persistent memory to Claude Code:
        /plugin marketplace add Yupcha/memxt
        /plugin install memxt

      Memory lives in a single local palace; nothing leaves your machine.
    EOS
  end

  test do
    system bin/"memxt", "init"
    assert_match "memxt", shell_output("#{bin}/memxt stats")
  end
end
