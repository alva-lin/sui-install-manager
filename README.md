# Sui Install Manager

一个用于简化 Sui 和 Move 开发环境安装与管理的 Shell 脚本工具。支持快速安装、更新、切换和管理不同环境(mainnet/testnet/devnet)下的 Sui 二进制版本。

## 功能特性

- 支持 mainnet、testnet、devnet 三种环境
- 支持安装指定版本或最新版本
- 自动备份和版本管理
- 支持在不同版本间快速切换
- 提供交互式和命令行两种使用方式
- 自动处理依赖和权限问题

## 系统要求

- Linux/macOS 操作系统
- root/sudo 权限
- 基础依赖：curl, tar
- 推荐安装：jq (用于更好的 JSON 解析)

## 使用方法

### 安装准备

```bash
# 克隆仓库
git clone https://github.com/alva-lin/sui-install-manager.git
cd sui-install-manager

# 设置脚本执行权限
chmod +x sui_manager.sh

# 注意：所有命令需要 root 权限执行
# 可以使用 sudo 运行，或切换到 root 用户
```

### 基础命令

```bash
# 安装
sudo bash sui_manager.sh install

# 更新
sudo bash sui_manager.sh update

# 卸载
sudo bash sui_manager.sh uninstall

# 切换版本
sudo bash sui_manager.sh switch

# 查看当前版本和备份
sudo bash sui_manager.sh list

# 清理旧备份
sudo bash sui_manager.sh clean
```

### 更新脚本

1. 如果是通过 git clone 安装的,直接用 git pull 更新
2. 如果是直接下载的脚本,可以重新下载最新版本覆盖

## 贡献指南

欢迎提交 Issue 和 Pull Request！

## 开源协议

本项目采用 MIT 协议开源。详见 [LICENSE](LICENSE) 文件。

## 致谢

感谢所有为本项目做出贡献的开发者。
