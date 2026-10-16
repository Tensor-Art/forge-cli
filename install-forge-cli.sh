#!/bin/bash
# 通过明确的 HTTPS 发布清单安装完整 Forge CLI；不读取浏览器凭证，不触发生成。
set +x
set -euo pipefail
umask 077

manifest_url=''
github_repo=''
release_tag=''
github_mode=0
access_token=''
# 即使调用者恰好导出了同名变量，Access Key 也不得被后续 gh/curl 子进程继承。
export -n access_token
environment='tensor'
skills_dir=''
install_root="${HOME}/.local/share/tensor-forge"
bin_dir="${HOME}/.local/bin"
task_directory=''
stage_directory=''
lock_directory=''
pending_link=''

# 失败时只清理本次临时产物，已有版本和当前版本链接保持原状。
cleanup() {
  access_token=''
  if [ -n "$pending_link" ]; then rm -f "$pending_link"; fi
  if [ -n "$stage_directory" ]; then rm -rf "$stage_directory"; fi
  if [ -n "$task_directory" ]; then rm -rf "$task_directory"; fi
  if [ -n "$lock_directory" ]; then rmdir "$lock_directory" 2>/dev/null || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 错误只描述阶段，不拼接下载地址、凭证或子进程原始输出。
fail() { printf 'Forge CLI installer: %s\n' "$2" >&2; exit "$1"; }

# 帮助中的参数均为安装配置；Access Key 只交给 CLI 的受保护标准输入。
usage() {
  cat <<'HELP'
Usage: bash install-forge-cli.sh --manifest-url HTTPS_URL [options]
   or: bash install-forge-cli.sh --github-repo Tensor-Art/forge-cli --release-tag VERSION_TAG [options]
  --token ACCESS_KEY             Verify, securely store, and select an environment.
  --environment ENV              tensor (default), tusi, or tensor-test.
  --install-root ABSOLUTE_PATH    Default: ~/.local/share/tensor-forge.
  --bin-dir ABSOLUTE_PATH         Default: ~/.local/bin.
  --skills-dir ABSOLUTE_PATH      Optional explicit Skill host; omitted by default.
  --help                         Show this help.

Supports verified macOS arm64/x64 tar.gz artifacts only. No sudo or existing Node.js
is required. Prints the installed absolute binary path; it works immediately in
the current shell. Without --token, installs the CLI without changing credentials.
HELP
}

# 所有选项在下载或更改安装目录之前完成校验。
while [ "$#" -gt 0 ]; do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --manifest-url|--github-repo|--release-tag|--token|--environment|--install-root|--bin-dir|--skills-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || fail 2 'An option is missing its value.'
      case "$1" in
        --manifest-url) manifest_url=$2 ;;
        --github-repo) github_repo=$2 ;;
        --release-tag) release_tag=$2 ;;
        --token) access_token=$2 ;;
        --environment) environment=$2 ;;
        --install-root) install_root=$2 ;;
        --bin-dir) bin_dir=$2 ;;
        --skills-dir) skills_dir=$2 ;;
      esac
      shift 2 ;;
    *) fail 2 'Unknown installer option; use --help.' ;;
  esac
done

# 下载地址不能携带 Access Key，也不接受可被误当凭证的查询串或用户信息。
validate_https_url() {
  case "$1" in https://*) ;; *) fail 2 'Distribution URLs must use HTTPS.' ;; esac
  local remainder=${1#https://}
  case "$remainder" in ''|/*|*'@'*|*'?'*|*'#'*|*' '*|*$'\n'*|*$'\r'*|*$'\t'*) fail 2 'Distribution URLs must omit credentials, query strings, fragments, and whitespace.' ;; esac
}

if [ -n "$github_repo" ] || [ -n "$release_tag" ]; then
  [ -z "$manifest_url" ] || fail 2 'Choose either --manifest-url or --github-repo with --release-tag, not both.'
  [ "$github_repo" = 'Tensor-Art/forge-cli' ] || fail 2 'The GitHub source must be the authorized Tensor-Art/forge-cli repository.'
  [[ "$release_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]] || fail 2 'The GitHub source requires a safe explicit v-prefixed release tag.'
  github_mode=1
else
  [ -n "$manifest_url" ] || fail 2 'No distribution source was supplied; use --manifest-url or --github-repo with --release-tag. The current installation was not changed.'
  validate_https_url "$manifest_url"
fi
case "$environment" in tensor|tusi|tensor-test) ;; *) fail 2 'Environment must be tensor, tusi, or tensor-test.' ;; esac
case "$install_root" in /*) ;; *) fail 2 'install-root must be an absolute user directory.' ;; esac
case "$bin_dir" in /*) ;; *) fail 2 'bin-dir must be an absolute user directory.' ;; esac
if [ -n "$skills_dir" ]; then case "$skills_dir" in /*) ;; *) fail 2 'skills-dir must be an absolute directory.' ;; esac; fi

case "$(uname -s)" in Darwin) platform='darwin' ;; *) fail 12 'This installer currently supports verified macOS artifacts only.' ;; esac
case "$(uname -m)" in arm64|aarch64) architecture='arm64' ;; x86_64|amd64) architecture='x64' ;; *) fail 12 'This macOS architecture has no supported artifact.' ;; esac
for tool in shasum tar mktemp; do command -v "$tool" >/dev/null 2>&1 || fail 12 'A required macOS archive tool is unavailable.'; done
if [ "$github_mode" -eq 1 ]; then
  command -v gh >/dev/null 2>&1 || fail 12 'Private release installation requires the GitHub CLI and an existing authorized GitHub login.'
else
  command -v curl >/dev/null 2>&1 || fail 12 'The HTTPS download tool is unavailable.'
fi
[ -x /usr/bin/plutil ] || fail 12 'The macOS JSON parser is unavailable.'
task_directory=$(mktemp -d "${TMPDIR:-/tmp}/tensor-forge-install.XXXXXX")

# 下载器只允许 HTTPS 及 HTTPS 重定向，不执行返回内容。
download() {
  local maximum=$3
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --connect-timeout 20 --max-time 300 --max-filesize "$maximum" --output "$2" "$1" 2>"$task_directory/download.error" || fail 6 'A distribution download failed; the current installation was not changed.'
}

# 私有发行只使用现有 gh 身份下载指定 release asset，不传递 Forge 凭证或拼接 API 请求。
download_github_asset() {
  GH_HOST=github.com gh release download "$release_tag" -R "$github_repo" -p "$1" -O "$2" >"$task_directory/github-download.output" 2>"$task_directory/github-download.error" || fail 6 'The authorized GitHub release asset could not be downloaded; the current installation was not changed.'
  [ -f "$2" ] && [ "$(wc -c < "$2")" -le "$3" ] || fail 7 'The GitHub release asset is missing or exceeds the allowed download size.'
}

# 由系统 JSON 工具读取已下载清单，不依赖预装 Node、Python 或远端脚本。
manifest_string() { /usr/bin/plutil -extract "$1" raw -expect string -o - "$task_directory/manifest.json" 2>/dev/null; }

# 登录失败只转述明确白名单分类，并指向尚未切换的候选二进制恢复，绝不回显底层消息。
login_failure() {
  local reported_code safe_code failure_class
  reported_code=$(/usr/bin/plutil -extract error.code raw -expect string -o - "$task_directory/auth.error" 2>/dev/null || true)
  safe_code='UNKNOWN_LOGIN_FAILURE'
  failure_class='unknown'
  case "$reported_code" in
    API_TRANSPORT) safe_code=$reported_code; failure_class='network' ;;
    API_RATE_LIMITED) safe_code=$reported_code; failure_class='rate-limited' ;;
    API_AUTH|API_FORBIDDEN|AUTHENTICATION_REQUIRED|AUTH_LOGIN_FAILED) safe_code=$reported_code; failure_class='authentication' ;;
    AUTH_LOGIN_PARTIAL) safe_code=$reported_code; failure_class='partial-login' ;;
    API_NOT_FOUND|API_BUSINESS|API_INVALID_RESPONSE) safe_code=$reported_code; failure_class='remote-service' ;;
    INVALID_INPUT) safe_code=$reported_code; failure_class='invalid-input' ;;
    INTERRUPTED) safe_code=$reported_code; failure_class='interrupted' ;;
  esac
  printf 'Forge CLI installer: login failed [%s/%s]; the previous CLI version remains selected.\n' "$safe_code" "$failure_class" >&2
  printf 'Downloaded candidate CLI: %q\n' "$candidate/bin/tensor-forge" >&2
  printf 'Inspect login state: %q auth status --verify --environment %q --output json\n' "$candidate/bin/tensor-forge" "$environment" >&2
  exit 11
}
if [ "$github_mode" -eq 1 ]; then
  gh auth status --hostname github.com >"$task_directory/github-auth.output" 2>"$task_directory/github-auth.error" || fail 3 'The GitHub CLI has no usable authorized github.com login; the current installation was not changed.'
  download_github_asset channel.json "$task_directory/manifest.json" 1048576
else
  download "$manifest_url" "$task_directory/manifest.json" 1048576
fi
[ "$(manifest_string schemaVersion)" = 'forge.cli-distribution/v1' ] || fail 2 'The distribution manifest schema is unsupported.'
version=$(manifest_string version) || fail 2 'The manifest is missing a string version.'
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]] || fail 2 'The manifest version is invalid.'
if [ "$github_mode" -eq 1 ]; then
  [ "$(manifest_string github.repository)" = "$github_repo" ] && [ "$(manifest_string github.tag)" = "$release_tag" ] && [ "v$version" = "$release_tag" ] || fail 2 'The private release manifest repository, tag, or version does not match the requested release.'
  github_visibility=$(manifest_string github.visibility) || fail 2 'The private release manifest is missing its GitHub visibility.'
  case "$github_visibility" in private|public) ;; *) fail 2 'The GitHub manifest visibility must be private or public.' ;; esac
fi
[ "$(/usr/bin/plutil -type artifacts "$task_directory/manifest.json" 2>/dev/null)" = 'array' ] || fail 2 'The manifest artifacts must be an array.'
artifact_url=''
artifact_hash=''
artifact_count=0
index=0
while [ "$index" -lt 32 ]; do
  if ! /usr/bin/plutil -type "artifacts.$index" "$task_directory/manifest.json" >/dev/null 2>&1; then break; fi
  artifact_platform=$(manifest_string "artifacts.$index.platform") || fail 2 'An artifact platform is invalid.'
  artifact_arch=$(manifest_string "artifacts.$index.arch") || fail 2 'An artifact architecture is invalid.'
  if [ "$artifact_platform" = "$platform" ] && [ "$artifact_arch" = "$architecture" ]; then
    artifact_count=$((artifact_count + 1))
    artifact_format=$(manifest_string "artifacts.$index.format") || fail 2 'An artifact format is invalid.'
    [ "$artifact_format" = 'tar.gz' ] || fail 12 'This installer supports tar.gz runtime bundles only.'
    artifact_url=$(manifest_string "artifacts.$index.url") || fail 2 'The artifact URL is invalid.'
    artifact_hash=$(manifest_string "artifacts.$index.sha256") || fail 2 'The artifact SHA256 is missing.'
  fi
  index=$((index + 1))
done
if /usr/bin/plutil -type artifacts.32 "$task_directory/manifest.json" >/dev/null 2>&1; then fail 2 'The manifest contains too many artifacts.'; fi
[ "$artifact_count" -eq 1 ] || fail 12 'The manifest must contain exactly one matching macOS artifact.'
validate_https_url "$artifact_url"
if [ "$github_mode" -eq 1 ]; then
  github_prefix="https://github.com/$github_repo/releases/download/$release_tag/"
  case "$artifact_url" in "$github_prefix"*) github_asset=${artifact_url#"$github_prefix"} ;; *) fail 2 'The artifact URL does not belong to the requested GitHub repository and release.' ;; esac
  [[ "$github_asset" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail 2 'The GitHub artifact filename must not contain paths, glob characters, or escaping.'
  case "$github_asset" in *..*) fail 2 'The GitHub artifact filename must not contain parent-directory sequences.' ;; esac
fi
[[ "$artifact_hash" =~ ^[0-9a-fA-F]{64}$ ]] || fail 2 'The artifact SHA256 is invalid.'
artifact_hash=$(printf '%s' "$artifact_hash" | tr 'A-F' 'a-f')

# 切换前拒绝覆盖不属于当前安装根的现有启动器。
mkdir -p "$install_root/versions" "$bin_dir"
if [ -e "$install_root/current" ] && [ ! -L "$install_root/current" ]; then fail 5 'The current install entry is not a managed symbolic link.'; fi
launcher="$bin_dir/tensor-forge"
expected_launcher="$install_root/current/bin/tensor-forge"
if [ -e "$launcher" ] || [ -L "$launcher" ]; then
  [ -L "$launcher" ] && [ "$(readlink "$launcher")" = "$expected_launcher" ] || fail 5 'The binary path already belongs to another installation; choose a different --bin-dir.'
fi
if ! mkdir "$install_root/.install.lock" 2>/dev/null; then fail 5 'Another installer is active, or a previous installer lock needs review.'; fi
lock_directory="$install_root/.install.lock"
version_directory="$install_root/versions/$version-$artifact_hash"
candidate="$version_directory/tensor-forge"

if [ -d "$version_directory" ]; then
  [ -f "$version_directory/.archive-sha256" ] && [ "$(cat "$version_directory/.archive-sha256")" = "$artifact_hash" ] || fail 5 'The existing version directory is not a verified managed installation.'
else
  if [ "$github_mode" -eq 1 ]; then
    download_github_asset "$github_asset" "$task_directory/runtime.tar.gz" 2147483648
  else
    download "$artifact_url" "$task_directory/runtime.tar.gz" 2147483648
  fi
  downloaded_hash=$(shasum -a 256 "$task_directory/runtime.tar.gz")
  downloaded_hash=${downloaded_hash%% *}
  [ "$downloaded_hash" = "$artifact_hash" ] || fail 7 'The runtime bundle SHA256 does not match; the current installation was not changed.'
  tar -tzf "$task_directory/runtime.tar.gz" > "$task_directory/archive.list" 2>/dev/null || fail 7 'The runtime bundle is not a readable tar.gz archive.'
  while IFS= read -r entry; do
    case "$entry" in tensor-forge|tensor-forge/*) ;; *) fail 7 'The runtime bundle must contain only the tensor-forge root.' ;; esac
    case "/$entry/" in */../*|*/./*) fail 7 'The runtime bundle contains an unsafe archive path.' ;; esac
  done < "$task_directory/archive.list"
  # 自包含发布包不需要符号链接，拒绝可能越过临时解包目录的链接条目。
  tar -tvzf "$task_directory/runtime.tar.gz" > "$task_directory/archive.types" 2>/dev/null || fail 7 'The runtime archive metadata is invalid.'
  while IFS= read -r entry; do case "$entry" in -*|d*) ;; *) fail 7 'Runtime archives must contain regular files and directories only.' ;; esac; done < "$task_directory/archive.types"
  stage_directory=$(mktemp -d "$install_root/versions/.stage.XXXXXX")
  tar -xzf "$task_directory/runtime.tar.gz" -C "$stage_directory" 2>/dev/null || fail 7 'The runtime archive could not be extracted.'
  [ -x "$stage_directory/tensor-forge/bin/tensor-forge" ] && [ -x "$stage_directory/tensor-forge/runtime/bin/node" ] && [ -f "$stage_directory/tensor-forge/lib/main.js" ] || fail 7 'The runtime bundle is missing its launcher, Node runtime, or CLI entrypoint.'
  printf '%s\n' "$artifact_hash" > "$stage_directory/.archive-sha256"
  /bin/mv "$stage_directory" "$version_directory"
  stage_directory=''
fi

[ -x "$candidate/bin/tensor-forge" ] && [ -x "$candidate/runtime/bin/node" ] && [ -f "$candidate/lib/main.js" ] || fail 7 'The installed runtime bundle is incomplete.'
actual_version=$("$candidate/bin/tensor-forge" --version 2>"$task_directory/version.error") || fail 7 'The downloaded CLI could not start; the previous selected version remains active.'
[ "$actual_version" = "$version" ] || fail 7 'The downloaded CLI version does not match the manifest.'

if [ -n "$skills_dir" ]; then
  "$candidate/bin/tensor-forge" skills sync --target "$skills_dir" --output json >"$task_directory/skill.json" 2>"$task_directory/skill.error" || fail 11 'Optional Skill sync failed; user changes were not force-overwritten. The CLI bundle is available but was not selected.'
fi
if [ -n "$access_token" ]; then
  if ! printf '%s' "$access_token" | "$candidate/bin/tensor-forge" auth login --stdin --environment "$environment" --output json >"$task_directory/auth.json" 2>"$task_directory/auth.error"; then
    access_token=''
    login_failure
  fi
  access_token=''
else
  # 没有 Key 仍可完成安装；已有凭证验证失败仅报告，绝不发起浏览器登录。
  if ! "$candidate/bin/tensor-forge" auth status --verify --environment "$environment" --output json >"$task_directory/auth.json" 2>"$task_directory/auth.error"; then
    printf 'Forge CLI installed without a verified credential; use auth login when ready.\n' >&2
  fi
fi

# macOS mv -h 替换链接本身，不会跟随旧 current 指向的版本目录。
if [ ! -L "$launcher" ]; then
  pending_link="$bin_dir/.tensor-forge-install-$$"
  ln -s "$expected_launcher" "$pending_link"
  /bin/mv -fh "$pending_link" "$launcher"
  pending_link=''
fi
pending_link="$install_root/.current-install-$$"
ln -s "$candidate" "$pending_link"
/bin/mv -fh "$pending_link" "$install_root/current"
pending_link=''
printf 'Forge CLI is available now: %q --version\n' "$launcher" >&2
case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) printf 'For commands in this shell: export PATH=%q:"$PATH"\n' "$bin_dir" >&2 ;;
esac
printf '%s\n' "$launcher"
