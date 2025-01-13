#!/usr/bin/env bash
#
# SUI (MystenLabs) installer, updater, uninstaller script
#
# 功能概述:
#   1. 从 GitHub Release 获取 sui 的预编译打包文件 (.tgz) 并进行安装 (install)
#   2. 支持更新 (update) 功能，更新前做备份，存储在 /opt/sui/backup 下
#   3. 支持卸载 (uninstall) 功能
#   4. 参数可配置: 环境 (mainnet, testnet, devnet)，版本，平台(ubuntu, macos, windows)，架构(x86_64, aarch64, arm64)
#   5. 第一版主要针对 Ubuntu + x86_64 流程做了实现
#   6. 备份目录: /opt/sui/backup/<打包文件名>
#   7. 安装目录: /opt/sui
#   8. 符号链接 (示例): /usr/local/bin/sui  (可根据需要进行修改)
#
# 用法:
#   sudo bash sui_installer.sh install
#   sudo bash sui_installer.sh update
#   sudo bash sui_installer.sh uninstall
#
# 脚本参数 (可选):
#   --env <environment>        指定环境，可选: mainnet, testnet(默认), devnet
#   --version <version>        指定版本，默认为最新
#   --platform <platform>      指定平台，可选: ubuntu, macos, windows (当前仅实现 ubuntu)
#   --arch <architecture>      指定架构，可选: x86_64, aarch64 (ubuntu), arm64 (macos)
#   --list                     列出最新的 5 个可用版本 (根据环境过滤)
#
# 依赖:
#   需要安装 curl, tar, (可选: jq)
#
# 注意:
#   - devnet 更新最频繁，testnet 次之，mainnet 最慢；因此当指定 --env devnet 时，可能会出现某个版本只存在 devnet，而其他环境没有。
#   - 无 jq 的情况下也可以简单 grep/awk，但这里推荐安装 jq，方便解析 GitHub API 的 JSON 数据。
#

################################################################################
# 全局变量设置
################################################################################

# 安装目录
SUI_INSTALL_DIR="/opt/sui"
# 备份目录
SUI_BACKUP_DIR="${SUI_INSTALL_DIR}/backup"
# GitHub 仓库/Release API
GITHUB_REPO="MystenLabs/sui"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases"

# 默认参数
DEFAULT_ENV="testnet"
DEFAULT_PLATFORM="ubuntu"
DEFAULT_ARCH="x86_64"

# 脚本运行的功能选项: install / update / uninstall
ACTION=""

# 用户可在命令行传入参数来自定义
USER_ENV=""
USER_VERSION=""
USER_PLATFORM=""
USER_ARCH=""
USER_LIST="false"


################################################################################
# 帮助/用法说明
################################################################################
function usage() {
  echo "用法: $0 <command> [options]"
  echo ""
  echo "可用命令:"
  echo "  install        安装 sui"
  echo "  update         更新 sui"
  echo "  uninstall      卸载 sui"
  echo ""
  echo "可选参数 (在 install/update 时生效):"
  echo "  --env <environment>       指定环境, 可选: mainnet, testnet(默认), devnet"
  echo "  --version <version>       指定版本, 默认拉取最新版本"
  echo "  --platform <platform>     指定平台, 可选: ubuntu, macos, windows (默认 ubuntu)"
  echo "  --arch <architecture>     指定架构, 可选: x86_64, aarch64 (ubuntu), arm64 (macos)"
  echo "  --list                    列出最新 5 个版本 (与 --env 联动)"
  echo ""
  echo "示例:"
  echo "  sudo bash $0 install --env testnet --version v1.40.1"
  echo "  sudo bash $0 update  --env devnet"
  echo "  sudo bash $0 uninstall"
  echo ""
  exit 1
}


################################################################################
# 解析命令行参数
################################################################################
function parse_args() {
  # 第一个参数通常是 action (install|update|uninstall)
  if [[ $# -lt 1 ]]; then
    usage
  fi

  ACTION="$1"
  shift

  # 解析后续选项
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env)
        USER_ENV="$2"
        shift 2
        ;;
      --version)
        USER_VERSION="$2"
        shift 2
        ;;
      --platform)
        USER_PLATFORM="$2"
        shift 2
        ;;
      --arch)
        USER_ARCH="$2"
        shift 2
        ;;
      --list)
        USER_LIST="true"
        shift
        ;;
      *)
        echo "未知选项: $1"
        usage
        ;;
    esac
  done

  # 对 ACTION 做基础校验
  if [[ "${ACTION}" != "install" && "${ACTION}" != "update" && "${ACTION}" != "uninstall" ]]; then
    echo "错误: 不支持的命令: ${ACTION}"
    usage
  fi

  # 若没有显式指定环境/平台/架构，则使用默认值
  [[ -z "$USER_ENV" ]] && USER_ENV="$DEFAULT_ENV"
  [[ -z "$USER_PLATFORM" ]] && USER_PLATFORM="$DEFAULT_PLATFORM"
  [[ -z "$USER_ARCH" ]] && USER_ARCH="$DEFAULT_ARCH"
}


################################################################################
# 从 GitHub API 获取 Release 信息 (并通过 jq 或 grep/awk 进行简单筛选)
# 返回: 会输出满足环境关键字的 tag_name 列表 (最新在前)
################################################################################
function fetch_releases_by_env() {
  local env="$1"

  # 判断是否安装 jq, 根据情况使用不同的方式提取 tag_name
  if command -v jq >/dev/null 2>&1; then
    # 有 jq 的情况
    curl -s "${GITHUB_API_URL}" \
      | jq -r '.[].tag_name' \
      | grep -E "^${env}-"
  else
    # 没有 jq，简单用 grep 解析
    curl -s "${GITHUB_API_URL}" \
      | grep -oP '"tag_name":\s*"\K[^"]+' \
      | grep -E "^${env}-"
  fi
}

################################################################################
# 列出最近的 5 个可用版本 (根据用户指定的 environment)
################################################################################
function list_top_5_versions() {
  local env="$1"

  echo "获取 ${env} 环境下最新的 5 个版本:"
  releases=$(fetch_releases_by_env "$env")

  if [[ -z "$releases" ]]; then
    echo "没有获取到任何符合环境(${env})的版本信息."
    exit 0
  fi

  # 只取前5行，并展示
  echo "$releases" | head -n 5
}


################################################################################
# 获取最新版本 (取 fetch_releases_by_env 的第一行)
################################################################################
function get_latest_version() {
  local env="$1"
  local latest=""

  releases=$(fetch_releases_by_env "$env")
  if [[ -z "$releases" ]]; then
    echo "未获取到 ${env} 环境下的任何版本信息，无法获取最新版本." >&2
    exit 1
  fi

  # 第一行即是最新 (GitHub API 通常是按时间顺序返回)
  latest=$(echo "$releases" | head -n 1)
  echo "$latest"
}


################################################################################
# 拼接下载的 .tgz 文件名 + URL
# - tag_name: 比如 testnet-v1.40.1
# - 得到文件名: sui-testnet-v1.40.1-ubuntu-x86_64.tgz
################################################################################
function compose_download_url() {
  local tag="$1"
  local platform="$2"
  local arch="$3"

  # 形如: sui-testnet-v1.40.1-ubuntu-x86_64.tgz
  local file_name="sui-${tag}-${platform}-${arch}.tgz"
  # Release 下载 URL 通常格式:
  # https://github.com/MystenLabs/sui/releases/download/<tag>/<file_name>
  local download_url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${file_name}"

  echo "$download_url"
}


################################################################################
# 下载与解压
# 参数: download_url, 目标安装目录, 保存的文件名(备份时也用这个)
################################################################################
function download_and_extract() {
  local url="$1"
  local install_dir="$2"
  local file_name="$3"

  echo "开始下载: ${url}"
  # 先下载到临时目录
  curl -L -o "/tmp/${file_name}" "$url"
  if [[ $? -ne 0 ]]; then
    echo "下载失败: $url"
    exit 1
  fi

  echo "下载成功, 开始解压到: ${install_dir}"
  mkdir -p "$install_dir"
  tar -xzf "/tmp/${file_name}" -C "$install_dir"

  # 下载完的临时文件可在需要时删除
  rm -f "/tmp/${file_name}"
}


################################################################################
# 备份当前安装 (若存在)
################################################################################
function backup_current_install() {
  local backup_dir="$1"
  local backup_name="$2"

  if [[ -d "$SUI_INSTALL_DIR" ]]; then
    echo "当前检测到已安装版本，进行备份到: ${backup_dir}/${backup_name}"
    mkdir -p "${backup_dir}/${backup_name}"

    # 这里简单地直接复制整个目录；也可只备份可执行文件
    cp -r "${SUI_INSTALL_DIR}/." "${backup_dir}/${backup_name}/"

    echo "备份完成."
  fi
}


################################################################################
# 创建/更新 符号链接 (示例: 把 /opt/sui 下的 sui 二进制链接到 /usr/local/bin/sui)
################################################################################
function create_symlinks() {
  # 假设 tar 解压后在 /opt/sui 下能找到执行文件(sui, sui-tool等)。这里简单举例 sui
  if [[ -f "${SUI_INSTALL_DIR}/sui" ]]; then
    ln -sf "${SUI_INSTALL_DIR}/sui" /usr/local/bin/sui
    echo "已创建/更新符号链接 /usr/local/bin/sui -> ${SUI_INSTALL_DIR}/sui"
  fi

  # 如果有其他可执行文件，同理处理
  # ln -sf "${SUI_INSTALL_DIR}/sui-tool" /usr/local/bin/sui-tool
}


################################################################################
# 安装流程
################################################################################
function install_sui() {
  echo "=== 开始安装 SUI ==="
  local env="$USER_ENV"
  local version="$USER_VERSION"
  local platform="$USER_PLATFORM"
  local arch="$USER_ARCH"

  # 如果用户没有指定版本，则取最新
  if [[ -z "$version" ]]; then
    echo "未指定版本号, 正在获取 ${env} 环境下最新版本..."
    version="$(get_latest_version "$env")"
    echo "使用的版本: $version"
  fi

  # devnet / testnet / mainnet + 版本 => tag_name 形如 testnet-v1.40.1
  local tag_name="$version"
  # 若用户输入的版本里本来就包含了 testnet-，则直接用；否则可以简单拼接
  # 这里示例假设用户输入的 "$version" 已经包含 "testnet-vX" 或 "devnet-vX" 等字样
  # 如果想做更严格的检查，可以在这里判断一下
  if [[ "$version" != *"${env}-"* ]]; then
    # 如果 version 里不包含环境前缀，就自己拼
    tag_name="${env}-${version}"
  fi

  # 组装下载 URL
  local download_url
  download_url="$(compose_download_url "$tag_name" "$platform" "$arch")"

  # 备份
  mkdir -p "${SUI_BACKUP_DIR}"
  local backup_name="sui-${tag_name}-${platform}-${arch}"
  backup_current_install "${SUI_BACKUP_DIR}" "${backup_name}"

  # 下载 & 解压
  download_and_extract "$download_url" "$SUI_INSTALL_DIR" "sui-${tag_name}-${platform}-${arch}.tgz"

  # 创建符号链接
  create_symlinks

  echo "SUI 安装完成, 版本: $tag_name"
}


################################################################################
# 更新流程 (本质和安装类似，只是名称上区分一下)
################################################################################
function update_sui() {
  echo "=== 开始更新 SUI ==="
  # 跟安装共用函数即可
  install_sui
  echo "=== 更新完成 ==="
}


################################################################################
# 卸载流程
################################################################################
function uninstall_sui() {
  echo "=== 开始卸载 SUI ==="

  # 删除安装目录
  if [[ -d "$SUI_INSTALL_DIR" ]]; then
    rm -rf "$SUI_INSTALL_DIR"
    echo "已删除安装目录: $SUI_INSTALL_DIR"
  else
    echo "未发现 $SUI_INSTALL_DIR, 无需删除."
  fi

  # 删除符号链接 (示例: /usr/local/bin/sui)
  if [[ -L "/usr/local/bin/sui" ]]; then
    rm -f "/usr/local/bin/sui"
    echo "已删除符号链接 /usr/local/bin/sui"
  fi

  echo "=== SUI 卸载完成 ==="
}


################################################################################
# 主流程
################################################################################
function main() {
  # 先解析参数
  parse_args "$@"

  # 如果用户仅仅想查看版本列表
  if [[ "$USER_LIST" == "true" && "$ACTION" != "uninstall" ]]; then
    list_top_5_versions "$USER_ENV"
  fi

  case "$ACTION" in
    install)
      install_sui
      ;;
    update)
      update_sui
      ;;
    uninstall)
      uninstall_sui
      ;;
    *)
      usage
      ;;
  esac
}


# 入口
main "$@"
