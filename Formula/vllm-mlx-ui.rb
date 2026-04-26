# frozen_string_literal: true
require "json"

# Homebrew formula for vllm-mlx-ui
# Tap:  brew tap clickbrain/vllm-mlx-ui https://github.com/clickbrain/vllm-mlx-ui
# Install: brew install clickbrain/vllm-mlx-ui/vllm-mlx-ui
#
# This formula installs the vllm-mlx inference server and the browser-based
# dashboard UI into an isolated Python virtual environment managed by Homebrew.
# All entry-point commands (vllm-mlx, vllm-mlx-ui) are symlinked into
# Homebrew's bin/ directory, so they are always on PATH.

class VllmMlxUi < Formula
  desc "Apple Silicon LLM inference server with browser-based dashboard UI"
  homepage "https://github.com/clickbrain/vllm-mlx-ui"

  # Stable release — brew upgrade works normally with this URL.
  url "https://github.com/clickbrain/vllm-mlx-ui/archive/refs/tags/v0.3.41.tar.gz"
  sha256 "0f61fd2db09bec7983f78a2210b0e2f86db015357def16ed6007e72f271e21d4"
  version "0.3.41"

  # HEAD install: always gets the latest code from main branch.
  # Install with:  brew install --HEAD clickbrain/vllm-mlx-ui/vllm-mlx-ui
  head "https://github.com/clickbrain/vllm-mlx-ui.git", branch: "main"

  # Requires Apple Silicon — MLX only runs on Apple Silicon Macs
  depends_on arch: :arm64
  depends_on "python@3.11"
  # Node.js is needed at build time to compile the Vue dashboard
  depends_on "node" => :build

  # Don't let Homebrew rewrite dylib IDs inside the Python venv — the paths
  # are too long for the Mach-O header and the relinking isn't needed anyway.
  skip_clean "libexec"

  # ── Install ───────────────────────────────────────────────
  def install
    python = Formula["python@3.11"].opt_bin/"python3.11"
    venv   = libexec/"venv"

    # Build the Vue dashboard and bundle it inside the Python package.
    # The built assets land in ui/dist/, which pyproject.toml includes as
    # package-data under vllm_mlx.dashboard.ui_dist so pip bundles them.
    system "npm", "ci", "--prefix", "ui"
    system "npm", "run", "build", "--prefix", "ui"
    # Sync built dist into the Python package directory so pip picks it up
    FileUtils.rm_rf "vllm_mlx/dashboard/ui_dist"
    FileUtils.cp_r "ui/dist", "vllm_mlx/dashboard/ui_dist"

    # Create an isolated virtual environment
    system python, "-m", "venv", venv

    # Upgrade pip so it respects the build-system.requires in pyproject.toml.
    # pyproject.toml requires setuptools>=68, which includes setuptools.backends.legacy.
    # pip's build isolation downloads this automatically when building.
    system venv/"bin/pip", "install", "--upgrade", "pip"

    # Install the package (no [ui] extra needed — Streamlit dependency removed).
    system venv/"bin/pip", "install", "."

    # Upgrade key dependencies to latest compatible releases.
    # Using version bounds prevents silent breakage from incompatible upstream releases.
    # vllm-mlx must be listed explicitly — pip install . only satisfies the minimum
    # version requirement and won't upgrade an already-installed compatible release.
    system venv/"bin/pip", "install", "--upgrade",
           "vllm-mlx>=0.1.0",
           "mlx-lm>=0.31.0",
           "huggingface-hub>=0.23.0"

    # Install stable launcher scripts into Homebrew's bin.
    #
    # We deliberately DO NOT use write_env_script / write_exec_script here.
    # Those helpers hardcode the versioned Cellar path inside the script body
    # (e.g. /opt/homebrew/Cellar/vllm-mlx-ui/0.3.15/libexec/...).  Every brew
    # upgrade writes a new Cellar path, changing the file's content and hash.
    # macOS Application Firewall keyed its allow-rule on that hash, so the rule
    # silently broke after every upgrade — forcing the user to re-authorise.
    #
    # Instead we write a tiny script whose body is IDENTICAL across every
    # version: it resolves its own real path at runtime and exec's the matching
    # venv binary from a stable relative offset (../libexec/venv/bin/<cmd>).
    # The ALF hash never changes → the firewall rule persists forever.
    %w[vllm-mlx vllm-mlx-ui vllm-mlx-chat vllm-mlx-bench].each do |cmd|
      next unless (venv/"bin"/cmd).exist?

      (bin/cmd).write <<~SH
        #!/bin/bash
        _s="$(readlink -f "$0" 2>/dev/null || realpath "$0" 2>/dev/null || echo "$0")"
        exec "$(dirname "$_s")/../libexec/venv/bin/#{cmd}" "$@"
      SH
      (bin/cmd).chmod 0755
    end
  end

  # ── Post-install: download starter model & write default config ──────────
  def post_install
    venv   = libexec/"venv"
    python = venv/"bin/python3"
    model  = "mlx-community/Llama-3.2-3B-Instruct-4bit"

    # HuggingFace caches models under ~/.cache/huggingface/hub/models--<org>--<name>.
    # On upgrades the model is already present — skip the download to avoid
    # lock-file permission errors when another process holds the cache.
    model_cache_dir = Pathname("#{Dir.home}/.cache/huggingface/hub") \
                      / "models--mlx-community--Llama-3.2-3B-Instruct-4bit"

    if model_cache_dir.exist?
      ohai "Starter model already present — skipping download."
    else
      ohai "Downloading starter model: #{model} (~1.8 GB)"
      ohai "This happens once. Grab a coffee ☕ — it takes a few minutes."

      system python, "-c", <<~PY
        from huggingface_hub import snapshot_download
        snapshot_download("#{model}")
      PY

      ohai "Starter model ready! Run: vllm-mlx-ui"
    end

    # Always write the default config on first install (idempotent — won't
    # overwrite an existing config so user settings survive upgrades).
    config_dir = Pathname("#{Dir.home}/.vllm_mlx_ui")
    config_dir.mkpath
    config_file = config_dir/"server_config.json"
    unless config_file.exist?
      config_file.write(JSON.generate({
        "model"        => model,
        "port"         => 8080,
        "host"         => "127.0.0.1",
        "max_tokens"   => 4096,
        "context_size" => 8192,
      }))
    end
  end

  # ── Post-install message ──────────────────────────────────
  def caveats
    <<~EOS
      ✅  vllm-mlx is installed with a starter model ready to use.

      Start the dashboard:
          vllm-mlx-ui

      The browser opens automatically at http://127.0.0.1:8502
      Click ▶ Start Server on the Serve page — the model loads in ~30s.

      Docs & source:  https://github.com/clickbrain/vllm-mlx-ui
    EOS
  end

  # ── Smoke test ────────────────────────────────────────────
  test do
    # Verify the package is importable (fast, no GPU required)
    system Formula["python@3.11"].opt_bin/"python3.11",
           "-c", "import vllm_mlx; import vllm_mlx.dashboard.app"
  end
end
