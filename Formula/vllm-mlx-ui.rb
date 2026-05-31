# frozen_string_literal: true
require "json"

# Homebrew formula for vllm-mlx-ui
# Tap:  brew tap clickbrain/homebrew-vllm-mlx-ui https://github.com/clickbrain/homebrew-vllm-mlx-ui
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
  url "https://github.com/clickbrain/vllm-mlx-ui/archive/refs/tags/v0.8.88.tar.gz"
  sha256 "02b7b9715f0a2fc93eb17cb6d0ab987f5c889b27479c2aa6e8a0b235919232d4"
  version "0.8.88"

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

    # Bundle docs so the in-app docs viewer works in the installed version
    FileUtils.rm_rf "vllm_mlx/dashboard/docs_dist"
    FileUtils.cp_r "docs", "vllm_mlx/dashboard/docs_dist"

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
    # NOTE: vllm-mlx is intentionally NOT listed here. Installing it from PyPI would
    # overwrite our bundled vllm_mlx/ upstream code with a potentially incompatible
    # version, causing ImportError crashes (rapid_mlx 0.6.68 namespace collision bug).
    # Our vllm_mlx/ package is fully self-contained and synced from upstream via git.
    system venv/"bin/pip", "install", "--upgrade",
           "mlx-lm>=0.31.0",
           "mlx-embeddings>=0.1.0",
           "huggingface-hub>=0.23.0"

    # Homebrew's relocation step rewrites @rpath install-name IDs to absolute
    # paths, but orjson's .so has no room in its Mach-O header for the long
    # absolute path (/opt/homebrew/Cellar/.../orjson.cpython-311-darwin.so).
    # Pre-patching to @loader_path-relative makes Homebrew skip it entirely —
    # the relocator only matches @rpath and @executable_path prefixes.
    # Python loads extension modules via dlopen(full_path) so this is safe.
    orjson_so = venv/"lib/python3.11/site-packages/orjson/orjson.cpython-311-darwin.so"
    if orjson_so.exist?
      system "install_name_tool", "-id",
             "@loader_path/orjson.cpython-311-darwin.so", orjson_so.to_s
    end

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

  # ── Post-install: write default config ───────────────────────────────────
  def post_install
    # No auto-download — models are managed via the dashboard or `rapid-mlx pull`.
    config_dir = Pathname("#{Dir.home}/.vllm_mlx_ui")
    config_dir.mkpath
    config_file = config_dir/"server_config.json"
    unless config_file.exist?
      config_file.write(JSON.generate({
        "config_version"           => 4,
        "engine_id"                => "rapid-mlx",
        "model"                    => "qwen3.5-9b",
        "port"                     => 8000,
        "host"                     => "127.0.0.1",
        "max_tokens"               => 32768,
        "proxy_default_max_tokens" => 32768,
        "engine_settings"          => {
          "rapid-mlx" => {
            "gpu_memory_utilization" => 0.85,
          },
        },
      }))
    end
  end

  # ── Post-install message ──────────────────────────────────
  def caveats
    <<~EOS
      ✅  vllm-mlx-ui is installed with Rapid-MLX as the inference engine.

      Start the dashboard:
          vllm-mlx-ui

      The browser opens at http://127.0.0.1:8502
      Default model: qwen3.5-9b (~5 GB). To pre-download:
          rapid-mlx pull qwen3.5-9b

      Or just click ▶ Start Server — it will download on first launch.

      To upgrade:
          brew update && brew upgrade vllm-mlx-ui

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
