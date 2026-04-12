#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# 0. 常量 / 标记
# ==========================================================
readonly MARKER="# [managed-by-init-script]"

# ==========================================================
# 1. Root 权限检查
# ==========================================================
if [ "$EUID" -ne 0 ]; then
    echo "错误：请以 root 权限运行此脚本！"
    echo ""
    echo "方法一：先切换到 root"
    echo "  su -"
    echo "  bash -c \"\$(curl -fsSL URL)\""
    echo ""
    echo "方法二：使用 sudo 直接执行"
    echo "  sudo bash -c \"\$(curl -fsSL URL)\""
    exit 1
fi

# ==========================================================
# 2. 交互式终端检查
# ==========================================================
if [ ! -t 0 ] || [ ! -t 1 ] || [ ! -r /dev/tty ]; then
    echo "错误：该脚本需要在交互式终端中运行" >&2
    exit 1
fi

# ==========================================================
# 3. 工具函数
# ==========================================================
detect_pkg_manager() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    else
        echo "none"
    fi
}

ensure_base_tools() {
    local need_curl=0
    local need_vim=0
    local need_tmux=0
    local pkg_mgr

    if ! command -v curl >/dev/null 2>&1; then
        need_curl=1
    fi
    if ! command -v vim >/dev/null 2>&1; then
        need_vim=1
    fi
    if ! command -v tmux >/dev/null 2>&1; then
        need_tmux=1
    fi

    if [ "$need_curl" -eq 0 ] && [ "$need_vim" -eq 0 ] && [ "$need_tmux" -eq 0 ]; then
        echo "curl、vim 和 tmux 已安装，跳过"
        return
    fi

    pkg_mgr="$(detect_pkg_manager)"

    case "$pkg_mgr" in
        apt)
            echo "检测到 apt-get，正在安装缺失软件..."
            apt-get update
            local pkgs=()
            [ "$need_curl" -eq 1 ] && pkgs+=(curl)
            [ "$need_vim" -eq 1 ] && pkgs+=(vim)
            [ "$need_tmux" -eq 1 ] && pkgs+=(tmux)
            apt-get install -y "${pkgs[@]}"
            ;;
        dnf)
            echo "检测到 dnf，正在安装缺失软件..."
            [ "$need_curl" -eq 1 ] && dnf install -y curl
            if [ "$need_vim" -eq 1 ]; then
                dnf install -y vim-enhanced || dnf install -y vim
            fi
            [ "$need_tmux" -eq 1 ] && dnf install -y tmux
            ;;
        yum)
            echo "检测到 yum，正在安装缺失软件..."
            [ "$need_curl" -eq 1 ] && yum install -y curl
            if [ "$need_vim" -eq 1 ]; then
                yum install -y vim-enhanced || yum install -y vim
            fi
            [ "$need_tmux" -eq 1 ] && yum install -y tmux
            ;;
        *)
            if [ "$need_curl" -eq 1 ]; then
                echo "错误：系统缺少 curl，且未找到受支持的包管理器，无法继续执行" >&2
                exit 1
            fi
            if [ "$need_vim" -eq 1 ]; then
                echo "警告：系统缺少 vim，且未找到受支持的包管理器，请手动安装" >&2
            fi
            if [ "$need_tmux" -eq 1 ]; then
                echo "警告：系统缺少 tmux，且未找到受支持的包管理器，请手动安装" >&2
            fi
            ;;
    esac

    if ! command -v curl >/dev/null 2>&1; then
        echo "错误：curl 安装失败，无法继续执行后续 mise 安装流程" >&2
        exit 1
    fi

    if command -v vim >/dev/null 2>&1; then
        echo "vim 已安装完成"
    else
        echo "警告：vim 仍未安装成功，请稍后手动安装" >&2
    fi

    if command -v tmux >/dev/null 2>&1; then
        echo "tmux 已安装完成"
    else
        echo "警告：tmux 仍未安装成功，请稍后手动安装" >&2
    fi
}

valid_username() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] &&
    [[ "$name" != "root" ]] &&
    [[ "${#name}" -le 32 ]]
}

# ==========================================================
# 4. 安装 curl / vim / tmux（幂等）
# ==========================================================
ensure_base_tools

# ==========================================================
# 5. 新建并配置普通用户（幂等：用户已存在则跳过创建）
# ==========================================================
echo ""
NEW_USER=""
while true; do
    read -r -p "请输入要新建的普通用户名称: " NEW_USER < /dev/tty

    if ! valid_username "$NEW_USER"; then
        echo "用户名不合法。"
        echo "要求："
        echo "  - 只能包含小写字母、数字、下划线、短横线"
        echo "  - 必须以小写字母或下划线开头"
        echo "  - 不能是 root"
        echo "  - 最长 32 个字符"
        echo ""
        continue
    fi

    break
done

if id "$NEW_USER" >/dev/null 2>&1; then
    echo "用户 $NEW_USER 已存在，将直接对其进行环境配置"
else
    useradd -m -s /bin/bash "$NEW_USER"
    echo "请为 $NEW_USER 设置密码："

    # 临时关闭 set -e，并循环重试，防止密码设置失败导致脚本中断
    set +e
    while true; do
        passwd "$NEW_USER" < /dev/tty
        if [ $? -eq 0 ]; then
            break
        fi
        echo "密码设置失败，请重新输入！"
    done
    set -e
fi

# ---- 确保 sudo / wheel 组 ----
if getent group sudo >/dev/null 2>&1; then
    if ! id -nG "$NEW_USER" | grep -qw sudo; then
        usermod -aG sudo "$NEW_USER"
        echo "已将 $NEW_USER 加入 sudo 组"
    fi
elif getent group wheel >/dev/null 2>&1; then
    if ! id -nG "$NEW_USER" | grep -qw wheel; then
        usermod -aG wheel "$NEW_USER"
        echo "已将 $NEW_USER 加入 wheel 组"
    fi
else
    echo "警告：未找到 sudo 或 wheel 组，可能需要手动赋予管理员权限"
fi

# ==========================================================
# 6. 在普通用户上下文中执行环境配置
# ==========================================================
echo "正在为 $NEW_USER 配置..."

su - "$NEW_USER" -c "bash -s -- '$MARKER'" << 'OUTER_EOF'
set -euo pipefail

MARKER="$1"

EARLY_PATH_BEGIN="${MARKER} BEGIN early-path"
EARLY_PATH_END="${MARKER} END early-path"

MISE_BEGIN="${MARKER} BEGIN bashrc-mise"
MISE_END="${MARKER} END bashrc-mise"

ALIAS_BEGIN="${MARKER} BEGIN bashrc-aliases"
ALIAS_END="${MARKER} END bashrc-aliases"

pick_login_file() {
    if [ -f "$HOME/.bash_profile" ]; then
        printf '%s\n' "$HOME/.bash_profile"
    elif [ -f "$HOME/.bash_login" ]; then
        printf '%s\n' "$HOME/.bash_login"
    else
        printf '%s\n' "$HOME/.profile"
    fi
}

append_managed_block_once() {
    local file="$1"
    local begin_marker="$2"
    local end_marker="$3"
    local body="$4"

    touch "$file"

    if grep -qF "$begin_marker" "$file"; then
        echo "$file 中的托管块已存在，跳过"
        return
    fi

    {
        printf '\n%s\n' "$begin_marker"
        printf '%s\n' "$body"
        printf '%s\n' "$end_marker"
    } >> "$file"

    echo "已追加托管块到 $file"
}

prepend_managed_block_once() {
    local file="$1"
    local begin_marker="$2"
    local end_marker="$3"
    local body="$4"
    local tmp_file

    touch "$file"

    if grep -qF "$begin_marker" "$file"; then
        echo "$file 中的托管块已存在，跳过"
        return
    fi

    tmp_file="$(mktemp)"
    
    # 设置陷阱（trap），在函数返回/退出时自动清理临时文件
    trap 'rm -f "$tmp_file"' RETURN

    {
        printf '%s\n' "$begin_marker"
        printf '%s\n' "$body"
        printf '%s\n\n' "$end_marker"
        cat "$file"
    } > "$tmp_file"

    cat "$tmp_file" > "$file"

    echo "已在 $file 顶部插入托管块"
}

EARLY_PATH_BLOCK=$(cat <<'EOF'
# 提前准备 PATH，避免 login shell 在读取 .bashrc 前找不到 mise
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
EOF
)

MISE_BLOCK=$(cat <<'EOF'
# mise 环境
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

if command -v mise >/dev/null 2>&1; then
  eval "$(mise activate bash)"
fi
EOF
)

ALIAS_BLOCK=$(cat <<'EOF'
# 自定义快捷别名
alias ll='ls -al'
alias la='ls -ACF'
alias h='cd ~ && ls -ACF'
EOF
)

# ----------------------------------------------------------
# 6a. 在 login 文件顶部插入 early PATH（安全，不重排原结构）
# ----------------------------------------------------------
LOGIN_FILE="$(pick_login_file)"
prepend_managed_block_once "$LOGIN_FILE" "$EARLY_PATH_BEGIN" "$EARLY_PATH_END" "$EARLY_PATH_BLOCK"

# 当前 shell 也先补 PATH，避免后续安装时 command not found
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# ----------------------------------------------------------
# 6b. 安装 mise（幂等：已有则跳过下载）
# ----------------------------------------------------------
if command -v mise >/dev/null 2>&1; then
    echo "mise 已安装，跳过下载"
else
    echo "正在下载并安装 mise..."
    curl --connect-timeout 10 --max-time 60 -fsSL https://mise.run | sh
fi

if ! command -v mise >/dev/null 2>&1; then
    echo "错误：mise 安装失败！" >&2
    exit 1
fi

# ----------------------------------------------------------
# 6c. 配置 .bashrc - mise 激活（块级 marker）
# ----------------------------------------------------------
BASHRC_FILE="$HOME/.bashrc"
touch "$BASHRC_FILE"

append_managed_block_once "$BASHRC_FILE" "$MISE_BEGIN" "$MISE_END" "$MISE_BLOCK"
append_managed_block_once "$BASHRC_FILE" "$ALIAS_BEGIN" "$ALIAS_END" "$ALIAS_BLOCK"

# 让当前 shell 立即生效
eval "$(mise activate bash)"

# ----------------------------------------------------------
# 6d. 使用 mise 安装 uv（幂等：已安装则跳过）
# ----------------------------------------------------------
if command -v uv >/dev/null 2>&1; then
    echo "uv 已安装 ($(uv --version))，跳过"
else
    echo "使用 mise 安装 uv..."
    mise use -g uv@latest
    hash -r
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "错误：uv 安装失败！" >&2
    exit 1
fi

# ----------------------------------------------------------
# 6e. 使用 uv 安装 tldr（幂等：已安装则跳过）
# ----------------------------------------------------------
if command -v tldr >/dev/null 2>&1; then
    echo "tldr 已安装，跳过"
else
    echo "使用 uv 安装 tldr..."
    uv tool install tldr
    hash -r
fi

echo "环境依赖和别名配置完成！"
OUTER_EOF

# ==========================================================
# 7. 切换到普通用户
# ==========================================================
echo ""
echo "======================================="
echo " 系统初始化和环境部署全部完成！"
echo " ✓ vim  ✓ tmux  ✓ curl  ✓ mise  ✓ uv  ✓ tldr"
echo "======================================="
echo "正在切换到 $NEW_USER 用户..."
sleep 1

exec su - "$NEW_USER"