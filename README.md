# Forge CLI

Forge CLI (`tensor-forge`) operates Forge canvases, nodes, media and generation runs from a terminal or a terminal-capable Agent. This repository contains distribution files only; development source is maintained separately.

## Install

The current prerelease supports macOS Apple Silicon. It includes Node.js and the macOS credential adapter. Downloads do not require a GitHub account, GitHub CLI, npm or sudo.

Run in your terminal:

```bash
(
  set -eu
  installer=$(mktemp)
  trap 'rm -f "$installer"' EXIT
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    https://github.com/Tensor-Art/forge-cli/releases/download/v0.1.0-dev.28/install-forge-cli.sh \
    -o "$installer"
  printf '%s  %s\n' f410ca5b74fc4e6ac01628306a15b871cf5f3bf37471082c370bf220c0f86f05 "$installer" \
    | shasum -a 256 -c -
  bash "$installer" --manifest-url \
    https://github.com/Tensor-Art/forge-cli/releases/download/v0.1.0-dev.28/channel.json
) && export PATH="$HOME/.local/bin:$PATH"
```

The installer verifies the version and SHA256, preserves the old version on failure, and installs under your user directory. It does not modify shell profiles, enable automatic generation, or run billable tasks.

## Log in to Forge

Version `0.1.0-dev.28` supports browser authorization on Forge deployments with the matching authorization service enabled. The CLI opens your browser; sign in, compare the confirmation code, and approve access. Credentials are then verified and saved in macOS Keychain.

```bash
tensor-forge auth login --environment tensor
```

For the separate Tensor test-b deployment, use:

```bash
TENSOR_FORGE_TEST_VERSION=test-b tensor-forge auth login --environment tensor-test
TENSOR_FORGE_TEST_VERSION=test-b tensor-forge auth status --verify --environment tensor-test
```

Access Key login remains available, including on deployments without browser authorization:

Create or select an Access Key in Forge, then supply it directly to the CLI's stdin flow. Do not paste it into an issue or Agent conversation.

```bash
tensor-forge auth login --stdin --environment tensor
tensor-forge auth status --verify --environment tensor
tensor-forge --help
```

Use `tensor` for Tensor production, `tusi` for Tusi production, and `tensor-test` only for its separate test deployment. Credentials are stored in macOS Keychain after verification. Login does not approve generation charges.

On macOS, the CLI can use your existing enabled HTTP/HTTPS proxy for its own process. It does not change system proxy settings, DNS, or shell profiles. Explicit proxy environment variables take precedence.

## Versions and recovery

Download versioned assets from [Releases](https://github.com/Tensor-Art/forge-cli/releases) and verify `SHA256SUMS`. The historical dev.27 assets are preserved byte for byte. Use the HTTPS installation method above for anonymous downloads.

For uncertain generation, recover using the existing operation/run identity instead of submitting again. Report only the CLI version, operating system and structured error code; omit credentials, prompts, signed links and private media.

Intel Mac, Windows and Linux release acceptance is pending. Some commands require matching backend extensions; runtime Schema reports their prerequisites.

## Licensing

Forge CLI uses the MIT license. Packaged Node.js and the credential adapter include their notices under `licenses/` in the archive.

## 中文说明

本仓库只分发 Forge CLI 安装器、校验文件和安装包。用户无需 GitHub 账号即可下载安装，开发源码单独维护。

当前 dev.28 支持 macOS Apple Silicon，自带 Node；在配套授权服务已启用的 Forge 环境中，执行登录命令即可打开浏览器，核对确认码并授权。Access Key 登录继续作为备用方式。测试环境 test-b 使用上方带环境变量的命令，与生产环境凭据隔离。

CLI 只在自身进程内使用已有 HTTP/HTTPS 代理，不修改系统代理、DNS 或终端配置。安装和 Forge 登录是两个独立步骤，GitHub 下载不需要 Forge Key。请勿把真实 Key、提示词或私人素材提交到仓库或 issue。
