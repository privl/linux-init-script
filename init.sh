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
have() { command -v "$1" >/dev/null 2>&1; }

detect_pkg_manager() {
    if have apt-get; then echo apt
    elif have dnf; then echo dnf
    elif have pacman; then echo pacman
    else echo none
    fi
}

# 安装缺失的 curl / sudo / vim / tmux（幂等）。curl 缺失为致命错误，其余仅警告
ensure_base_tools() {
    local pkg_mgr vim_pkg pkgs=()
    pkg_mgr="$(detect_pkg_manager)"

    # 各发行版中"完整功能、无 GUI"的 vim 包名不同
    case "$pkg_mgr" in
        apt) vim_pkg=vim-nox ;;
        dnf) vim_pkg=vim-enhanced ;;
        *)   vim_pkg=vim ;;
    esac

    have curl || pkgs+=(curl)
    have sudo || pkgs+=(sudo)
    have vim  || pkgs+=("$vim_pkg")
    have tmux || pkgs+=(tmux)

    if [ ${#pkgs[@]} -eq 0 ]; then
        echo "curl、sudo、vim 和 tmux 已安装，跳过"
        return
    fi

    echo "缺失软件：${pkgs[*]}"
    case "$pkg_mgr" in
        apt)    apt-get update
                apt-get install -y "${pkgs[@]}" ;;
        dnf)    dnf install -y "${pkgs[@]}" ;;
        # Arch 不支持部分升级（-Sy 后直接装包可能撞库），按官方建议用 -Syu
        pacman) pacman -Syu --needed --noconfirm "${pkgs[@]}" ;;
        *)      echo "警告：未找到受支持的包管理器（apt/dnf/pacman），无法自动安装" >&2 ;;
    esac

    have curl || { echo "错误：缺少 curl，无法继续执行后续 mise 安装流程" >&2; exit 1; }
    have sudo || echo "警告：sudo 未安装成功，新用户将没有管理员权限，请稍后手动安装" >&2
    have vim  || echo "警告：vim 未安装成功，请稍后手动安装" >&2
    have tmux || echo "警告：tmux 未安装成功，请稍后手动安装" >&2
}

# 确保 sudoers 已授权指定组（幂等）。优先写 /etc/sudoers.d/ 独立文件，不改主配置
ensure_sudoers_rule() {
    local group="$1"
    local rule="%${group} ALL=(ALL:ALL) ALL"
    local file="/etc/sudoers.d/init-script-${group}"
    local tmp

    have sudo || { echo "警告：sudo 未安装，跳过 sudoers 配置" >&2; return; }

    # 主配置已启用该组（如 Debian 的 %sudo、Fedora 的 %wheel）则无需再加
    if grep -qE "^[[:space:]]*%${group}[[:space:]]" /etc/sudoers 2>/dev/null; then
        echo "/etc/sudoers 已授权 %${group}，跳过"
        return
    fi
    if [ -f "$file" ] && [ "$(cat "$file")" = "$rule" ]; then
        echo "$file 已存在，跳过"
        return
    fi
    if ! grep -qE '^[@#]includedir[[:space:]]+/etc/sudoers\.d' /etc/sudoers 2>/dev/null; then
        echo "警告：/etc/sudoers 未包含 /etc/sudoers.d，无法自动授权 %${group}，请手动 visudo" >&2
        return
    fi

    tmp="$(mktemp)"
    printf '%s\n' "$rule" > "$tmp"
    # 先用 visudo 校验语法，避免写坏 sudoers 导致 sudo 整体失效
    if ! visudo -cf "$tmp" >/dev/null; then
        rm -f "$tmp"
        echo "错误：sudoers 规则校验失败，未写入" >&2
        exit 1
    fi
    install -d -m 0750 /etc/sudoers.d
    install -m 0440 -o root -g root "$tmp" "$file"
    rm -f "$tmp"
    echo "已写入 $file：$rule"
}

valid_username() {
    local name="$1"
    [[ "$name" =~ ^[a-z_][a-z0-9_-]*$ ]] &&
    [[ "$name" != "root" ]] &&
    [[ "${#name}" -le 32 ]]
}

# 交互式设置密码，失败则重试（until 的条件不受 set -e 影响）
set_password_interactive() {
    echo "请为 $1 设置密码："
    until passwd "$1" < /dev/tty; do
        echo "密码设置失败，请重新输入！"
    done
}

# 是否已有可用密码。passwd -S 第二列：P/PS = 可用，L/LK = 锁定，NP = 无密码
has_usable_password() {
    [[ "$(passwd -S "$1" 2>/dev/null | awk '{print $2}')" == P* ]]
}

# 校验已存在用户是否适合配置：必须是普通用户、有可登录 shell、有家目录
validate_existing_user() {
    local user="$1" entry uid uid_min home shell
    # 先抓输出再 read：让 IFS=: 只作用于 read，不泄漏给 getent
    entry="$(getent passwd "$user")"
    IFS=: read -r _ _ uid _ _ home shell <<< "$entry"
    uid_min="$(awk '$1=="UID_MIN"{print $2}' /etc/login.defs 2>/dev/null || true)"
    uid_min="${uid_min:-1000}"

    if [ "$uid" -lt "$uid_min" ]; then
        echo "错误：$user 是系统账号（UID $uid < $uid_min），拒绝为其配置环境或授予 sudo 权限" >&2
        exit 1
    fi

    case "$shell" in
        */nologin|*/false|"")
            echo "错误：$user 的登录 shell 为 '${shell:-空}'，无法登录，拒绝配置" >&2
            exit 1 ;;
    esac
    if [ -f /etc/shells ] && ! grep -qxF "$shell" /etc/shells; then
        echo "错误：$user 的登录 shell '$shell' 不在 /etc/shells 中，拒绝配置" >&2
        exit 1
    fi
    [[ "$shell" == */bash ]] || echo "警告：$user 的登录 shell 是 $shell 而非 bash，本脚本写入的 .bashrc 在该 shell 下不会生效" >&2

    if [ ! -d "$home" ]; then
        echo "错误：$user 的家目录 '${home:-空}' 不存在，拒绝配置" >&2
        exit 1
    fi
}

# 结尾汇总用：命令存在则 ✓，否则 ✗
status_mark() { have "$1" && echo "✓" || echo "✗"; }

# ==========================================================
# 4. 安装 curl / sudo / vim / tmux（幂等）
# ==========================================================
ensure_base_tools

# ==========================================================
# 5. 新建并配置普通用户（幂等：用户已存在则跳过创建）
# ==========================================================
echo ""
while true; do
    read -r -p "请输入要新建的普通用户名称: " NEW_USER < /dev/tty
    valid_username "$NEW_USER" && break
    echo "用户名不合法。"
    echo "要求："
    echo "  - 只能包含小写字母、数字、下划线、短横线"
    echo "  - 必须以小写字母或下划线开头"
    echo "  - 不能是 root"
    echo "  - 最长 32 个字符"
    echo ""
done

if id "$NEW_USER" >/dev/null 2>&1; then
    validate_existing_user "$NEW_USER"
    echo "用户 $NEW_USER 已存在，将直接对其进行环境配置"
    # 上次运行若在 passwd 阶段中断，用户会处于"已创建但密码锁定"状态，这里补救
    if ! has_usable_password "$NEW_USER"; then
        echo "检测到 $NEW_USER 尚未设置可用密码（可能是上次运行中断）"
        set_password_interactive "$NEW_USER"
    fi
else
    useradd -m -s /bin/bash "$NEW_USER"
    set_password_interactive "$NEW_USER"
fi

# ---- 管理员权限：加入 sudo/wheel 组（usermod -aG 幂等）+ 确保 sudoers 授权该组 ----
ADMIN_GROUP="$(getent group sudo wheel | head -n1 | cut -d: -f1 || true)"
if [ -n "$ADMIN_GROUP" ]; then
    usermod -aG "$ADMIN_GROUP" "$NEW_USER"
    echo "已确保 $NEW_USER 属于 $ADMIN_GROUP 组"
    ensure_sudoers_rule "$ADMIN_GROUP"
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

have() { command -v "$1" >/dev/null 2>&1; }

# 向文件追加一个带 marker 的托管块（幂等：已存在则跳过）
append_managed_block_once() {
    local file="$1" name="$2" body="$3"
    local begin="${MARKER} BEGIN ${name}"
    local end="${MARKER} END ${name}"

    touch "$file"
    if grep -qF "$begin" "$file"; then
        echo "$file 中的托管块 $name 已存在，跳过"
        return
    fi
    printf '\n%s\n%s\n%s\n' "$begin" "$body" "$end" >> "$file"
    echo "已追加托管块 $name 到 $file"
}

# 非交互 shell 没有 prompt 钩子，`mise activate` 装完工具后不会刷新 PATH；
# 这里直接用 `mise env` 导出已配置工具的 PATH，每次装完工具后重新调用
refresh_mise_env() {
    eval "$(mise env -s bash)"
    hash -r
}

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
# 6a. 当前 shell 先补 PATH（mise 安装到 ~/.local/bin）
# ----------------------------------------------------------
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

# ----------------------------------------------------------
# 6b. 安装 mise（幂等：已有则跳过下载）
# ----------------------------------------------------------
if have mise; then
    echo "mise 已安装，跳过下载"
else
    echo "正在下载并安装 mise..."
    curl --connect-timeout 10 --max-time 60 -fsSL https://mise.run | sh
    have mise || { echo "错误：mise 安装失败！" >&2; exit 1; }
fi

# ----------------------------------------------------------
# 6c. 配置 .bashrc（块级 marker，幂等）
# ----------------------------------------------------------
append_managed_block_once "$HOME/.bashrc" bashrc-mise "$MISE_BLOCK"
append_managed_block_once "$HOME/.bashrc" bashrc-aliases "$ALIAS_BLOCK"
refresh_mise_env

# ----------------------------------------------------------
# 6d. 使用 mise 安装 uv（幂等：已安装则跳过）
# ----------------------------------------------------------
if have uv; then
    echo "uv 已安装 ($(uv --version))，跳过"
else
    echo "使用 mise 安装 uv..."
    mise use -g uv@latest
    refresh_mise_env
    have uv || { echo "错误：uv 安装失败！" >&2; exit 1; }
fi

# ----------------------------------------------------------
# 6e. 使用 uv 安装 tldr（幂等：已安装则跳过）
# ----------------------------------------------------------
if have tldr; then
    echo "tldr 已安装，跳过"
else
    echo "使用 uv 安装 tldr..."
    uv tool install tldr
fi

echo "环境依赖和别名配置完成！"
OUTER_EOF

# ==========================================================
# 7. 切换到普通用户
# ==========================================================
echo ""
echo "======================================="
echo " 系统初始化和环境部署完成！"
# curl/mise/uv 缺失会直接中止脚本，能走到这里必然存在；sudo/vim/tmux 只是警告，需如实反映
echo " $(status_mark sudo) sudo  $(status_mark vim) vim  $(status_mark tmux) tmux  ✓ curl  ✓ mise  ✓ uv  ✓ tldr"
have sudo && have vim && have tmux || echo " (✗ 项未安装成功，请稍后手动安装)"
echo "======================================="
echo "正在切换到 $NEW_USER 用户..."

exec su - "$NEW_USER"
