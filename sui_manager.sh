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
  echo "  switch         切换到已备份的版本"
  echo "  list          显示当前版本和可用的备份版本"
  echo "  clean          清理旧的备份版本（每个环境保留最新版本）"
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
  echo "  sudo bash $0 clean"
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
  if [[ "${ACTION}" != "install" && \
        "${ACTION}" != "update" && \
        "${ACTION}" != "uninstall" && \
        "${ACTION}" != "switch" && \
        "${ACTION}" != "list" && \
        "${ACTION}" != "clean" ]]; then
    echo "错误: 不支持的命令: ${ACTION}"
    usage
  fi

  # 若没有显式指定环境/平台/架构，则使用默认值
  [[ -z "$USER_ENV" ]] && USER_ENV="$DEFAULT_ENV"
  [[ -z "$USER_PLATFORM" ]] && USER_PLATFORM="$DEFAULT_PLATFORM"
  [[ -z "$USER_ARCH" ]] && USER_ARCH="$DEFAULT_ARCH"
}


################################################################################
# 从 GitHub API 获取 Release 信息
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
# 列出最近的 5 个可用版本
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
# 获取最新版本
################################################################################
function get_latest_version() {
  local env="$1"
  local latest=""

  releases=$(fetch_releases_by_env "$env")
  if [[ -z "$releases" ]]; then
    echo "未获取到 ${env} 环境下的任何版本信息，无法获取最新版本." >&2
    exit 1
  fi

  # 第一行即是最新
  latest=$(echo "$releases" | head -n 1)
  echo "$latest"
}

################################################################################
# 拼接下载的 .tgz 文件名 + URL
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

  # 保存版本信息
  save_version_info "$env" "${version#*v}"  # 去掉版本号前面的 v

  echo "SUI 安装完成, 版本: $tag_name"
  get_current_version_info
}


################################################################################
# 更新流程
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
# 检查脚本运行环境和依赖
################################################################################
function check_environment() {
  # 检查是否以 root 权限运行
  if [[ $EUID -ne 0 ]]; then
    echo "错误: 此脚本需要 root 权限运行"
    echo "请使用: sudo $0 $*"
    exit 1
  fi

  # 检查必要的命令是否存在
  local required_commands=("curl" "tar")
  for cmd in "${required_commands[@]}"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo "错误: 未找到必要的命令: $cmd"
      echo "请先安装: sudo apt-get install $cmd"
      exit 1
    fi
  done

  # 检查 jq（可选但推荐）
  if ! command -v jq >/dev/null 2>&1; then
    echo "警告: 未安装 jq，这会影响 JSON 解析效率"
    echo "建议安装: sudo apt-get install jq"
    echo "继续使用备用解析方式..."
  fi

  # 检查目录权限
  if [[ ! -w "/opt" ]]; then
    echo "错误: 没有 /opt 目录的写入权限"
    exit 1
  fi
}


################################################################################
# 交互式引导安装
################################################################################
function interactive_install() {
  echo "=== SUI 安装引导 ==="

  # 选择环境
  echo "请选择环境:"
  echo "1) testnet (默认/推荐)"
  echo "2) devnet (更新最频繁)"
  echo "3) mainnet (正式网络)"
  read -p "请输入选择 [1-3] (默认: 1): " env_choice
  case "$env_choice" in
    2) USER_ENV="devnet" ;;
    3) USER_ENV="mainnet" ;;
    *) USER_ENV="testnet" ;;
  esac
  echo "已选择环境: $USER_ENV"

  # 显示最新版本
  echo -e "\n获取最新版本信息..."
  list_top_5_versions "$USER_ENV"

  # 选择版本
  read -p "请输入要安装的版本 (直接回车使用最新版本): " version_choice
  if [[ -n "$version_choice" ]]; then
    USER_VERSION="$version_choice"
  fi

  # 确认安装
  echo -e "\n=== 安装确认 ==="
  echo "环境: $USER_ENV"
  echo "版本: ${USER_VERSION:-"最新版本"}"
  echo "平台: $USER_PLATFORM"
  echo "架构: $USER_ARCH"

  read -p "确认安装? (Y/n): " confirm
  if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "已取消安装"
    exit 0
  fi

  # 执行安装
  install_sui
}

################################################################################
# 交互式引导更新
################################################################################
function interactive_update() {
  echo "=== SUI 更新引导 ==="

  # 检查当前安装
  if [[ ! -d "$SUI_INSTALL_DIR" ]]; then
    echo "未检测到已安装的 SUI，请先安装"
    exit 1
  fi

  # 显示最新版本信息
  echo "获取最新版本信息..."
  list_top_5_versions "$USER_ENV"

  read -p "请输入要更新到的版本 (直接回车使用最新版本): " version_choice
  if [[ -n "$version_choice" ]]; then
    USER_VERSION="$version_choice"
  fi

  # 确认更新
  echo -e "\n=== 更新确认 ==="
  echo "环境: $USER_ENV"
  echo "版本: ${USER_VERSION:-"最新版本"}"

  read -p "确认更新? (Y/n): " confirm
  if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "已取消更新"
    exit 0
  fi

  # 执行更新
  update_sui
}

################################################################################
# 交互式引导卸载
################################################################################
function interactive_uninstall() {
  echo "=== SUI 卸载确认 ==="

  if [[ ! -d "$SUI_INSTALL_DIR" ]]; then
    echo "未检测到已安装的 SUI"
    exit 0
  fi

  read -p "确认要卸载 SUI? 这将删除所有相关文件 (y/N): " confirm
  if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "已取消卸载"
    exit 0
  fi

  uninstall_sui
}

################################################################################
# 版本信息记录与读取
################################################################################
function save_version_info() {
    local env="$1"
    local version="$2"
    local info_file="${SUI_INSTALL_DIR}/.version_info"

    echo "environment=${env}" > "$info_file"
    echo "version=${version}" >> "$info_file"
}

function get_current_version_info() {
    local info_file="${SUI_INSTALL_DIR}/.version_info"
    if [[ -f "$info_file" ]]; then
        source "$info_file"
        echo "当前环境: ${environment}"
        echo "当前版本: ${version}"
    else
        echo "未找到版本信息"
    fi
}

################################################################################
# 列出所有可用的备份
################################################################################
function list_backups() {
    echo "=== 可用的备份版本 ==="
    if [[ ! -d "$SUI_BACKUP_DIR" ]]; then
        echo "未找到任何备份"
        return
    fi

    # 列出所有备份目录并提取版本信息
    local i=1
    while IFS= read -r backup_dir; do
        local backup_name=$(basename "$backup_dir")
        echo "$i) $backup_name"
        ((i++))
    done < <(find "$SUI_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)
}

################################################################################
# 切换到指定的备份版本
################################################################################
function switch_version() {
    local target_backup="$1"
    local backup_path="${SUI_BACKUP_DIR}/${target_backup}"

    if [[ ! -d "$backup_path" ]]; then
        echo "未找到备份: ${target_backup}"

        # 从备份名称中提取环境和版本信息
        local env=$(echo "$target_backup" | grep -oP '(?<=sui-)(mainnet|testnet|devnet)')
        local version=$(echo "$target_backup" | grep -oP '(?<=-)(v[\d\.]+)(?=-)')

        if [[ -n "$env" && -n "$version" ]]; then
            echo "是否要下载并安装此版本？"
            echo "环境: $env"
            echo "版本: $version"
            read -p "确认下载并安装? (Y/n): " confirm
            if [[ ! "$confirm" =~ ^[Nn] ]]; then
                # 设置全局变量供 install_sui 使用
                USER_ENV="$env"
                USER_VERSION="$version"
                install_sui
                return $?
            else
                echo "已取消安装"
                return 1
            fi
        else
            echo "无法从备份名称中提取有效的环境和版本信息"
            return 1
        fi
    fi

    echo "切换到版本: ${target_backup}"

    # 删除当前的可执行文件
    if [[ -d "$SUI_INSTALL_DIR" ]]; then
        echo "删除当前版本的可执行文件..."
        find "$SUI_INSTALL_DIR" -maxdepth 1 -type f \( -name "sui*" -o -name "move*" \) -delete
    else
        mkdir -p "$SUI_INSTALL_DIR"
    fi

    # 从备份复制新版本的文件
    echo "复制新版本文件..."
    cp "$backup_path"/sui* "$SUI_INSTALL_DIR/" 2>/dev/null || true
    cp "$backup_path"/move* "$SUI_INSTALL_DIR/" 2>/dev/null || true

    # 提取环境和版本信息
    local env=$(echo "$target_backup" | grep -oP '(?<=sui-)(mainnet|testnet|devnet)')
    local version=$(echo "$target_backup" | grep -oP 'v[\d\.]+')

    # 保存版本信息
    save_version_info "$env" "$version"

    # 重新创建符号链接
    create_symlinks

    echo "版本切换完成"
    get_current_version_info
}

################################################################################
# 交互式版本切换
################################################################################
function interactive_switch() {
    echo "=== SUI 版本切换 ==="

    # 显示当前版本
    echo "当前版本信息:"
    get_current_version_info
    echo ""

    # 显示可用的备份版本
    list_backups

    # 获取备份列表
    local backups=()
    while IFS= read -r backup_dir; do
        backups+=("$(basename "$backup_dir")")
    done < <(find "$SUI_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d | sort -r)

    echo ""
    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "没有可用的备份版本"
        echo "您可以安装新版本:"
    else
        echo "请选择操作:"
        echo "1-${#backups[@]}) 切换到已有的备份版本"
        echo "$((${#backups[@]}+1))) 安装新版本"
    fi

    if [[ ${#backups[@]} -eq 0 ]]; then
        echo "1) 安装新版本"
        echo "2) 退出"
        read -p "请选择 [1-2]: " choice
        if [[ "$choice" != "1" ]]; then
            echo "已取消操作"
            return 0
        fi
        choice=1  # 为后续安装流程设置
    else
        read -p "请选择 [1-$((${#backups[@]}+1))]: " choice
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        if [[ "$choice" -le ${#backups[@]} ]]; then
            # 切换到已有备份
            local selected_backup="${backups[$((choice-1))]}"
            echo "将切换到版本: $selected_backup"
            read -p "确认切换? (Y/n): " confirm
            if [[ "$confirm" =~ ^[Nn] ]]; then
                echo "已取消切换"
                return 0
            fi
            switch_version "$selected_backup"
        elif [[ "$choice" -eq $((${#backups[@]}+1)) ]] || [[ ${#backups[@]} -eq 0 ]]; then
            # 安装新版本
            # 先选择环境
            echo -e "\n请选择目标环境:"
            echo "1) testnet (默认/推荐)"
            echo "2) devnet (更新最频繁)"
            echo "3) mainnet (正式网络)"
            read -p "请输入选择 [1-3] (默认: 1): " env_choice

            local target_env
            case "$env_choice" in
                2) target_env="devnet" ;;
                3) target_env="mainnet" ;;
                *) target_env="testnet" ;;
            esac

            # 显示所选环境的可用版本
            echo -e "\n获取 ${target_env} 环境下的可用版本:"
            list_top_5_versions "$target_env"
            echo ""

            # 选择版本
            read -p "请输入要安装的版本 (格式如 ${target_env}-v1.40.1): " version_input
            if [[ -n "$version_input" ]]; then
                # 检查版本格式
                if [[ ! "$version_input" =~ ^${target_env}-v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                    echo "版本格式不正确，应该类似: ${target_env}-v1.40.1"
                    return 1
                fi
                switch_version "sui-${version_input}-${DEFAULT_PLATFORM}-${DEFAULT_ARCH}"
            else
                echo "未指定版本，退出"
                return 1
            fi
        else
            echo "无效的选择"
            return 1
        fi
    else
        echo "无效的输入"
        return 1
    fi
}

################################################################################
# 清理备份
################################################################################
function clean_backups() {
    echo "=== 清理备份 ==="

    # 检查备份目录是否存在
    if [[ ! -d "$SUI_BACKUP_DIR" ]]; then
        echo "未找到备份目录"
        return 0
    fi

    # 获取当前版本信息
    local current_env=""
    local current_version=""
    local info_file="${SUI_INSTALL_DIR}/.version_info"
    if [[ -f "$info_file" ]]; then
        source "$info_file"
        current_env="$environment"
        current_version="v$version"
    fi

    # 获取所有备份，按环境分组
    local mainnet_backups=()
    local testnet_backups=()
    local devnet_backups=()

    while IFS= read -r backup_dir; do
        local backup_name=$(basename "$backup_dir")
        if [[ "$backup_name" == *"mainnet"* ]]; then
            mainnet_backups+=("$backup_name")
        elif [[ "$backup_name" == *"testnet"* ]]; then
            testnet_backups+=("$backup_name")
        elif [[ "$backup_name" == *"devnet"* ]]; then
            devnet_backups+=("$backup_name")
        fi
    done < <(find "$SUI_BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d)

    # 定义一个函数来比较版本号
    function version_gt() {
        local v1=$(echo "$1" | grep -oP 'v\K[\d\.]+')
        local v2=$(echo "$2" | grep -oP 'v\K[\d\.]+')
        if [[ "$(printf '%s\n' "$v1" "$v2" | sort -V | tail -n 1)" == "$v1" ]]; then
            return 0
        else
            return 1
        fi
    }

    # 定义一个函数来分析每个环境的备份（不执行删除）
    function analyze_env_backups() {
        local env="$1"
        shift
        local -a backups=("$@")
        local -a to_delete=()
        local latest=""
        local current=""

        if [[ ${#backups[@]} -le 1 ]]; then
            return
        fi

        # 找出最新版本
        for backup in "${backups[@]}"; do
            if [[ -z "$latest" ]] || version_gt "$backup" "$latest"; then
                latest="$backup"
            fi
            # 检查是否为当前使用的版本
            if [[ -n "$current_env" && "$current_env" == "$env" && \
                  "$backup" == *"${current_env}-${current_version}"* ]]; then
                current="$backup"
            fi
        done

        # 收集要删除的版本
        for backup in "${backups[@]}"; do
            if [[ "$backup" != "$latest" && "$backup" != "$current" ]]; then
                to_delete+=("$backup")
            fi
        done

        # 输出分析结果
        if [[ -n "$latest" ]]; then
            echo "- ${env} 环境最新版本 (将保留): $latest"
        fi
        if [[ -n "$current" && "$current" != "$latest" ]]; then
            echo "- ${env} 环境当前使用版本 (将保留): $current"
        fi
        if [[ ${#to_delete[@]} -gt 0 ]]; then
            echo "- ${env} 环境将删除的版本:"
            for backup in "${to_delete[@]}"; do
                echo "  * $backup"
            done
        fi
        echo ""
    }

    # 先显示预计的清理结果
    echo -e "\n清理预览:"
    echo "----------------------------------------"
    if [[ -n "$current_env" && -n "$current_version" ]]; then
        echo "当前使用的版本: ${current_env}-${current_version}"
    fi
    echo ""

    if [[ ${#mainnet_backups[@]} -gt 0 ]]; then
        analyze_env_backups "mainnet" "${mainnet_backups[@]}"
    fi
    if [[ ${#testnet_backups[@]} -gt 0 ]]; then
        analyze_env_backups "testnet" "${testnet_backups[@]}"
    fi
    if [[ ${#devnet_backups[@]} -gt 0 ]]; then
        analyze_env_backups "devnet" "${devnet_backups[@]}"
    fi
    echo "----------------------------------------"

    # 询问用户是否继续
    read -p "确认执行以上清理操作? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy] ]]; then
        echo "已取消清理操作"
        return 0
    fi

    # 执行清理
    echo -e "\n开始执行清理..."
    function clean_env_backups() {
        local env="$1"
        shift
        local -a backups=("$@")
        local latest=""
        local current=""

        if [[ ${#backups[@]} -le 1 ]]; then
            return
        fi

        # 找出最新版本和当前版本
        for backup in "${backups[@]}"; do
            if [[ -z "$latest" ]] || version_gt "$backup" "$latest"; then
                latest="$backup"
            fi
            if [[ -n "$current_env" && "$current_env" == "$env" && \
                  "$backup" == *"${current_env}-${current_version}"* ]]; then
                current="$backup"
            fi
        done

        # 删除其他版本
        for backup in "${backups[@]}"; do
            if [[ "$backup" != "$latest" && "$backup" != "$current" ]]; then
                echo "删除: $backup"
                rm -rf "${SUI_BACKUP_DIR}/$backup"
            fi
        done
    }

    # 执行实际的清理操作
    if [[ ${#mainnet_backups[@]} -gt 0 ]]; then
        clean_env_backups "mainnet" "${mainnet_backups[@]}"
    fi
    if [[ ${#testnet_backups[@]} -gt 0 ]]; then
        clean_env_backups "testnet" "${testnet_backups[@]}"
    fi
    if [[ ${#devnet_backups[@]} -gt 0 ]]; then
        clean_env_backups "devnet" "${devnet_backups[@]}"
    fi

    echo -e "\n清理完成。备份文件位于: ${SUI_BACKUP_DIR}"
    echo "如需手动管理备份，可以直接访问该目录"
    echo -e "\n当前剩余备份:"
    list_backups
}

################################################################################
# 交互式备份清理
################################################################################
function interactive_clean() {
    echo "将为每个环境保留最新版本的备份..."
    clean_backups
}

################################################################################
# 主流程
################################################################################
function main() {
  # 检查和设置文件权限
  if [[ ! -x "$0" ]]; then
    chmod +x "$0"
  fi

  # 环境检查
  check_environment "$@"

  # 解析参数
  parse_args "$@"

  # 判断是否为交互式模式
  # 如果没有提供任何参数（除了动作），则进入交互模式
  local is_interactive=false
  if [[ $# -eq 1 ]]; then
    is_interactive=true
  fi

  if [[ "$is_interactive" == "true" ]]; then
    case "$ACTION" in
      install)
        interactive_install
        ;;
      update)
        interactive_update
        ;;
      uninstall)
        interactive_uninstall
        ;;
      switch)
        interactive_switch
        ;;
      list)
        get_current_version_info
        echo ""
        list_backups
        ;;
      clean)
        clean_backups
        ;;
      *)
        usage
        ;;
    esac
  else
    # 非交互模式
    # 如果用户仅想查看版本列表
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
      switch)
        interactive_switch  # switch 命令总是交互式的
        ;;
      list)
        get_current_version_info
        echo ""
        list_backups
        ;;
      clean)
        clean_backups
        ;;
      *)
        usage
        ;;
    esac
  fi
}


# 入口
main "$@"
