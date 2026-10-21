# Forge CLI

Forge CLI (`tensor-forge`) operates Forge canvases, nodes, media and generation runs from a terminal or a terminal-capable Agent. This repository distributes installers and release packages; development source is maintained separately.

Version **0.1.0-dev.30** is available for:

| System | Architecture | Installer |
| --- | --- | --- |
| macOS | Apple Silicon (arm64) | Shell |
| macOS | Intel (x64) | Shell |
| Windows | x64 | PowerShell |

The installer automatically reuses a compatible Node.js 22 or 24 when available, or downloads a compact Node.js 22 runtime. **You do not need to install Node.js yourself.** Downloads require no GitHub account, GitHub CLI or npm. Installation uses your user directory and needs no administrator privileges.

## Install on macOS

Run this in Terminal. The installer selects the package for your Mac's processor.

```bash
(
  set -eu
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    https://github.com/Tensor-Art/forge-cli/releases/download/v0.1.0-dev.30/install-forge-cli.sh \
    -o "$installer"
  printf '%s  %s\n' 4df428045361f8ac92dfd2ed7e36faf1ea130003cbdc0f55b89083c0c83c25e5 "$installer" \
    | shasum -a 256 -c -
  bash "$installer" --manifest-url \
    https://github.com/Tensor-Art/forge-cli/releases/download/v0.1.0-dev.30/channel.json \
    --skip-auth-check
) && export PATH="$HOME/.local/bin:$PATH"
```

The PATH change applies to this terminal session. For future sessions, add `$HOME/.local/bin` to your shell's PATH if it is not already present.

## Install on Windows

Run this in PowerShell on Windows x64:

```powershell
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$installer = Join-Path ([IO.Path]::GetTempPath()) ('forge-cli-' + [Guid]::NewGuid().ToString('N') + '.ps1')
try {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/Tensor-Art/forge-cli/releases/download/v0.1.0-dev.30/install-forge-cli.ps1' -OutFile $installer
    if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash.ToLowerInvariant() -ne 'bb392143ffebcb4b8ad52eef46d23effd885adf6e0eef79639f90597d6e0c592') {
        throw 'Forge CLI installer SHA256 mismatch.'
    }
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -ManifestUrl 'https://github.com/Tensor-Art/forge-cli/releases/download/v0.1.0-dev.30/channel.json' -SkipAuthCheck
    if ($LASTEXITCODE -ne 0) { throw "Forge CLI installation failed (exit $LASTEXITCODE)." }
    $env:PATH = (Join-Path $env:LOCALAPPDATA 'tensor-forge\bin') + ';' + $env:PATH
} finally {
    Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
}
```

The PATH change applies to this PowerShell session. For future sessions, add `%LOCALAPPDATA%\tensor-forge\bin` to your user PATH. The installer does not change your saved environment variables or machine execution policy.

Both installers verify package SHA256 and the CLI version before selecting the new installation. Login is a separate step. To always download the managed runtime, pass `--runtime managed` on macOS or `-Runtime managed` on Windows; `system` requires a compatible existing Node.js and stops if none is available.

## Install the Agent Skill

The matching `forge-cli` operational Skill is embedded in the CLI. For Codex, install or update its discoverable copy with:

```text
tensor-forge skills sync
tensor-forge skills status
tensor-forge doctor
```

The default destination is `~/.codex/skills/forge-cli`. For another Agent, use `tensor-forge skills sync --target` with the absolute path to that Agent's skills directory. Modified Skill copies are not silently overwritten.

## Log in to Forge

Run the following on either system:

```text
tensor-forge auth login --environment tensor
```

The CLI opens your browser. Sign in, compare the confirmation code and approve access. Credentials are verified and stored in macOS Keychain or Windows Credential Manager. Browser authorization requires the corresponding Forge authorization service.

Access Key login is also available. Create or select an Access Key in Forge, then provide it directly through the CLI's stdin flow:

```text
tensor-forge auth login --stdin --environment tensor
tensor-forge auth status --verify --environment tensor
tensor-forge --help
```

Use `tensor` for Tensor production, `tusi` for Tusi production, and `tensor-test` for its separate test deployment. Do not paste real Access Keys into issues or Agent conversations. Login does not approve generation charges; generation follows the CLI's cost preflight and confirmation controls.

## Updates and recovery

The CLI checks official releases after successful ordinary commands and prints an update notice when a newer compatible version is available. Updates are installed by running the installation instructions for the desired release; the CLI does not automatically replace itself. Set `TENSOR_FORGE_UPDATE_NOTIFIER=0` to disable update checks.

Download versioned assets from [Releases](https://github.com/Tensor-Art/forge-cli/releases) and verify `SHA256SUMS`. Earlier releases remain available for recovery. If a selected Node.js runtime is removed or becomes incompatible, rerun the installer to repair the installation.

For an uncertain generation result, recover using the existing operation or run identity before submitting again. When reporting a problem, include the CLI version, operating system and structured error code; omit credentials, prompts, signed links and private media. Some commands require corresponding Forge backend capabilities; the CLI's Schema describes their prerequisites.

## Licensing

Forge CLI uses the MIT license. The CLI and runtime archives include their respective license notices under `licenses/`.

## 中文说明

dev.30 提供 macOS 苹果芯片、macOS Intel 和 Windows x64 安装包。安装器优先复用兼容的 Node.js 22/24，否则自动下载精简 Node.js 22；用户无需自行安装 Node，也无需 GitHub 账号、npm 或管理员权限。

本版强化配套 Skill 的测试分流检查：请求前核对用户指定的版本，新终端、重试和任务恢复继续携带当前任务分流，不将 `test-e` 设为固定默认。升级后运行 `tensor-forge skills sync` 更新 Agent 的 Skill。

macOS 使用上方 Shell 命令，Windows 使用上方 PowerShell 命令。安装后运行 `tensor-forge skills sync` 安装配套操作 Skill，再执行 `tensor-forge auth login --environment tensor` 完成浏览器授权。Access Key 仍可通过 `--stdin` 登录，凭据保存到系统凭据库。

新版包含升级提示，实际升级由用户运行安装命令完成。安装与登录不会提交付费生成；生成继续遵循费用预检和确认流程。本仓库只提供发行文件，开发源码单独维护。
