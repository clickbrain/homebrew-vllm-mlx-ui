# frozen_string_literal: true
require "json"

class VllmMlxUi < Formula
  desc "Apple Silicon LLM inference server with browser-based dashboard UI"
  homepage "https://github.com/clickbrain/vllm-mlx-ui"

  url "https://github.com/clickbrain/vllm-mlx-ui/archive/refs/tags/v0.5.2.tar.gz"
  sha256 "d5558cd419c8d46bdc958064cb97f963d1ea793866414c025906ec15033512ed"
  version "0.5.2"

  head "https://github.com/clickbrain/vllm-mlx-ui.git", branch: "main"

  depends_on arch: :arm64
  depends_on "python@3.11"
  depends_on "node" => :build

  skip_clean "libexec"

  def install
    python = Formula["python@3.11"].opt_bin/"python3.11"
    venv   = libexec/"venv"

    system "npm", "ci", "--prefix", "ui"
    system "npm", "run", "build", "--prefix", "ui"
    FileUtils.rm_rf "vllm_mlx/dashboard/ui_dist"
    FileUtils.cp_r "ui/dist", "vllm_mlx/dashboard/ui_dist"

    FileUtils.rm_rf "vllm_mlx/dashboard/docs_dist"
    FileUtils.cp_r "docs", "vllm_mlx/dashboard/docs_dist"

    system python, "-m", "venv", venv
    system venv/"bin/pip", "install", "--upgrade", "pip"
    system venv/"bin/pip", "install", "."

    system venv/"bin/pip", "install", "--upgrade",
           "vllm-mlx>=0.1.0",
           "mlx-lm>=0.31.0",
           "huggingface-hub>=0.23.0"

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

  def post_install
    venv   = libexec/"venv"
    python = venv/"bin/python3"
    model  = "mlx-community/Llama-3.2-3B-Instruct-4bit"

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

  def caveats
    <<~EOS
      ✅  vllm-mlx is installed with a starter model ready to use.

      Start the dashboard:
          vllm-mlx-ui

      The browser opens automatically at http://127.0.0.1:8502
      Click ▶ Start Server on the Serve page — the model loads in ~30s.

      To upgrade:
          brew update && brew upgrade vllm-mlx-ui

      Note: `brew upgrade` alone may not see new releases for up to 24 hours
      due to Homebrew's auto-update throttle. Always use `brew update` first,
      or add this to your ~/.zshenv to reduce the throttle to 5 minutes:
          export HOMEBREW_AUTO_UPDATE_SECS=300

      Docs & source:  https://github.com/clickbrain/vllm-mlx-ui
    EOS
  end

  test do
    system Formula["python@3.11"].opt_bin/"python3.11",
           "-c", "import vllm_mlx; import vllm_mlx.dashboard.app"
  end
end
