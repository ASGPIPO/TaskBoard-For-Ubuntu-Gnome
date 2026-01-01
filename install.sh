#!/bin/bash
#=============================================================================
# TaskBoard Pro - 安装脚本
#
# 支持单文件下载安装：
# curl -SLf https://raw.githubusercontent.com/ASGPIPO/TaskBoard-or-Ubuntu-Gnome/main/install.sh | bash
#=============================================================================

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

# 检测系统
detect_system() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
        ID=$ID
        ID_LIKE=$ID_LIKE
    else
        log_error "无法检测系统类型"
        exit 1
    fi

    log_info "检测到系统: $OS $VERSION"

    # 检查是否为支持的系统
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "$ID" != "linuxmint" && "$ID_LIKE" != "ubuntu" && "$ID_LIKE" != "debian" ]]; then
        log_warning "检测到非标准Ubuntu/Debian系统，安装可能需要手动处理依赖"
    fi
}

# 检查是否为root用户
check_root() {
    if [[ $EUID -eq 0 ]]; then
        log_error "请不要使用root用户运行此脚本"
        exit 1
    fi
}

# 检查并安装依赖
install_dependencies() {
    log_info "检查并安装必要的依赖..."

    # 检查包管理器
    if command -v apt-get &>/dev/null; then
        PACKAGE_MANAGER="apt-get"
    elif command -v dnf &>/dev/null; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum &>/dev/null; then
        PACKAGE_MANAGER="yum"
    else
        log_error "未找到支持的包管理器 (apt/dnf/yum)"
        exit 1
    fi

    log_info "使用包管理器: $PACKAGE_MANAGER"

    # 更新包列表
    log_info "更新软件包列表..."
    if [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
        sudo $PACKAGE_MANAGER update -qq
    else
        sudo $PACKAGE_MANAGER update -y
    fi

    # 安装基础依赖
    local packages=("taskwarrior" "conky-all")

    # 根据包管理器添加额外依赖
    if [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
        packages+=("python3-pyqt6" "zenity")
    else
        packages+=("python3-qt6" "zenity")
    fi

    # 检查是否已安装
    local missing_packages=()
    for package in "${packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package " 2>/dev/null && ! rpm -q "$package" &>/dev/null; then
            missing_packages+=("$package")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log_info "需要安装的包: ${missing_packages[*]}"
        if [[ "$PACKAGE_MANAGER" == "apt-get" ]]; then
            sudo $PACKAGE_MANAGER install -y "${missing_packages[@]}"
        else
            sudo $PACKAGE_MANAGER install -y "${missing_packages[@]}"
        fi
        log_success "依赖安装完成"
    else
        log_info "所有依赖已安装"
    fi

    # 检查其他必要命令
    for cmd in task conky python3; do
        if ! command -v "$cmd" &>/dev/null; then
            log_error "缺少必要命令: $cmd"
            exit 1
        fi
    done
}

# 获取用户主目录
get_user_home() {
    echo "${HOME:-$(getent passwd $USER | cut -d: -f6)}"
}

# 创建目录结构
create_directories() {
    local user_home=$(get_user_home)
    local config_dir="$user_home/.config/conky"
    local tasklist_dir="$user_home/.taskList"
    local autostart_dir="$user_home/.config/autostart"

    log_info "创建目录结构..."

    # 创建配置目录
    mkdir -p "$config_dir"
    mkdir -p "$tasklist_dir"
    mkdir -p "$autostart_dir"

    log_success "目录创建完成"
    log_info "配置目录: $config_dir"
    log_info "TaskList目录: $tasklist_dir"
    log_info "自启动目录: $autostart_dir"
}

# 创建 overdue_tasks.sh
create_overdue_tasks() {
    local config_dir="$HOME/.config/conky"

    log_info "创建 overdue_tasks.sh..."

    cat << 'EOF' > "$config_dir/overdue_tasks.sh"
#!/bin/bash
n=$(task status:pending +OVERDUE count 2>/dev/null || echo 0)

if [ "$n" -gt 0 ]; then
    echo "\${color red}已逾期 ($n)\${color}"
    task status:pending +OVERDUE list limit:5 \
        rc.verbose=nothing \
        rc.defaultwidth=50 \
        rc.report.list.columns=id,due.relative,description \
        rc.report.list.labels=ID,Ago,Task 2>/dev/null
    echo "\${color grey}──────────────────\${color}"
fi
EOF

    chmod +x "$config_dir/overdue_tasks.sh"
    log_success "overdue_tasks.sh 创建完成"
}

# 创建 today_table.sh
create_today_table() {
    local tasklist_dir="$HOME/.taskList"

    log_info "创建 today_table.sh..."

    cat << 'EOF' > "$tasklist_dir/today_table.sh"
#!/bin/bash

TODAY=$(date +%y-%m-%d)


task status:pending -OVERDUE list \
  rc.verbose=nothing \
  rc.defaultwidth=50 \
  rc.report.list.columns=id,due,due.relative,description \
  rc.report.list.labels=ID,HIDDEN,Due,Task \
  rc.dateformat=y-M-D | \
awk -v today="$TODAY" '
{
    # --- 处理表头 (第一行) ---
    if (NR == 1) {
        # 重新打印表头，跳过第2列(HIDDEN)，只显示 ID, Due, Task
        # %-5s 表示左对齐占5格，%-10s 占10格

        next
    }

    # --- 处理数据行 ---
    # $1=ID, $2=Due(绝对), $3=Due(相对), $4及以后=Description

    # 核心判断逻辑：依然比对 $2 (YY-MM-DD) 和 today
    if ($2 > today) {

        # 保存 ID 和 相对时间
        id = $1
        rel_due = $3

        # 处理 Description (因为描述可能有空格，它分布在 $4 到 $NF)
        # 下面这段代码把 $1 $2 $3 清空，只保留描述文本
        $1=""; $2=""; $3="";
        # $0 现在变为空格开头的描述了，用 sub 去掉前导空格
        sub(/^[ \t]+/, "", $0);

        # 格式化输出：显示 ID, 相对时间, 描述
        printf "%-5s %-12s %s\n", id, rel_due, $0
    }
}'
EOF

    chmod +x "$tasklist_dir/today_table.sh"
    log_success "today_table.sh 创建完成"
}

# 创建 task_monitor_daemon.sh
create_task_monitor_daemon() {
    local tasklist_dir="$HOME/.taskList"

    log_info "创建 task_monitor_daemon.sh..."

    cat << 'EOF' > "$tasklist_dir/task_monitor_daemon.sh"
#!/bin/bash
#=============================================================================
# Task Monitor Daemon
#
# Ensures there is always at least one pending task due within 23 hours.
# Shows a persistent modal dialog when no such tasks exist.
#
# Features:
# - Checks every 5 minutes (configurable via CHECK_INTERVAL)
# - Dialog covers 70% of screen and cannot be closed without adding a valid task
# - Dialog is always on top (GNOME)
# - Dialog follows workspace changes
# - Avoids duplicate dialogs within 5 minutes
#=============================================================================

set -u

# Configuration
CHECK_INTERVAL=${CHECK_INTERVAL:-300}     # 5 minutes in seconds
TASK_HORIZON="now+23h"                     # Task due time horizon
WINDOW_TITLE="⚠️ 任务提醒"
WORKSPACE_CHECK_INTERVAL=1                 # Check workspace every 1 second

# State
STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}/task_monitor_daemon"
LOCK_FILE="${STATE_DIR}/daemon.lock"
DIALOG_START_FILE="${STATE_DIR}/dialog_start"
ZENITY_PID=""
DIALOG_WIDTH=1000
DIALOG_HEIGHT=700

#-----------------------------------------------------------------------------
# Initialization
#-----------------------------------------------------------------------------

init() {
    mkdir -p "$STATE_DIR"

    # Check for existing instance
    if [[ -f "$LOCK_FILE" ]]; then
        local old_pid
        old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
            echo "Daemon already running (PID: $old_pid)"
            exit 1
        fi
    fi

    echo $$ > "$LOCK_FILE"
}

#-----------------------------------------------------------------------------
# Logging
#-----------------------------------------------------------------------------

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

#-----------------------------------------------------------------------------
# Screen & Window Functions
#-----------------------------------------------------------------------------

get_dialog_dimensions() {
    local dims
    if command -v xdpyinfo &>/dev/null; then
        dims=$(xdpyinfo 2>/dev/null | grep -E '^\s*dimensions:' | head -1 | awk '{print $2}')
        if [[ -n "$dims" ]]; then
            local w h
            w=${dims%x*}
            h=${dims#*x}
            DIALOG_WIDTH=$((w * 70 / 100))
            DIALOG_HEIGHT=$((h * 70 / 100))
        fi
    fi
    log "Dialog dimensions: ${DIALOG_WIDTH}x${DIALOG_HEIGHT}"
}

get_current_workspace() {
    if command -v wmctrl &>/dev/null; then
        wmctrl -d 2>/dev/null | awk '/\*/{print $1; exit}' || echo "0"
    else
        echo "0"
    fi
}


set_window_always_on_top() {
    local max_attempts=10
    local attempt=0

    # -------- Wayland (GNOME) --------
    if [[ "${XDG_SESSION_TYPE:-}" == "wayland" ]] && \
       [[ "${XDG_CURRENT_DESKTOP:-}" =~ GNOME ]]; then

        # GNOME Shell Eval is best-effort only
        if command -v gdbus >/dev/null 2>&1; then
            log "Wayland/GNOME detected, trying GNOME Shell (best-effort)"

            # Try once or twice only — retries won't bypass Mutter policy
            while (( attempt < 2 )); do
                if gdbus call --session \
                    --dest org.gnome.Shell \
                    --object-path /org/gnome/Shell \
                    --method org.gnome.Shell.Eval \
                    "try {
                        let w = global.display.focus_window;
                        if (w) {
                            w.make_above();
                            true;
                        } else {
                            false;
                        }
                     } catch (e) { false; }" \
                     2>/dev/null | grep -q true; then

                    log "Window set to always-on-top (Wayland/GNOME, best-effort)"
                    return 0
                fi
                sleep 0.3
                ((attempt++))
            done
        fi

        log "Wayland/GNOME: always-on-top not permitted (expected behavior)"
        return 1
    fi

    # -------- X11 --------
    if command -v wmctrl >/dev/null 2>&1; then
        while (( attempt < max_attempts )); do
            if wmctrl -r "$WINDOW_TITLE" -b add,above 2>/dev/null; then
                log "Window set to always-on-top (X11)"
                return 0
            fi
            sleep 0.2
            ((attempt++))
        done
    fi

    log "Warning: Could not set window always-on-top"
    return 1
}

#-----------------------------------------------------------------------------
# Task Functions
#-----------------------------------------------------------------------------

check_tasks_count() {
    local count
    count=$(task due.before:"$TASK_HORIZON" status:pending -OVERDUE -INSTANCE count 2>/dev/null || echo "0")
    # Remove non-numeric characters
    count=${count//[^0-9]/}
    echo "${count:-0}"
}

has_valid_tasks() {
    [[ $(check_tasks_count) -gt 0 ]]
}

add_task() {
    local task_input="$1"

    if [[ -z "$task_input" ]]; then
        return 1
    fi

    # Try to add the task
    if task add $task_input 2>&1; then
        log "Task command executed: $task_input"
        return 0
    else
        log "Task add failed: $task_input"
        return 1
    fi
}

#-----------------------------------------------------------------------------
# Dialog Functions
#-----------------------------------------------------------------------------

kill_zenity() {
    if [[ -n "$ZENITY_PID" ]] && kill -0 "$ZENITY_PID" 2>/dev/null; then
        kill "$ZENITY_PID" 2>/dev/null
        wait "$ZENITY_PID" 2>/dev/null || true
    fi
    ZENITY_PID=""
}

is_dialog_recently_started() {
    if [[ -f "$DIALOG_START_FILE" ]]; then
        local start_time now elapsed
        start_time=$(cat "$DIALOG_START_FILE" 2>/dev/null || echo "0")
        now=$(date +%s)
        elapsed=$((now - start_time))
        # If dialog started less than CHECK_INTERVAL ago, consider it recent
        if ((elapsed < CHECK_INTERVAL)); then
            return 0
        fi
    fi
    return 1
}

mark_dialog_started() {
    date +%s > "$DIALOG_START_FILE"
}

clear_dialog_state() {
    rm -f "$DIALOG_START_FILE"
}

show_success_notification() {
    zenity --info \
        --title="✓ 成功" \
        --text="任务已成功添加！" \
        --timeout=3 \
        --width=300 \
        2>/dev/null || true
}

show_warning_no_due_date() {
    zenity --warning \
        --title="⚠️ 提示" \
        --text="任务已添加，但到期时间不在未来 23 小时内。

请确保任务包含正确的到期时间：
  • due:today — 今天到期
  • due:tomorrow — 明天到期
  • due:2h — 2小时后到期
  • due:eod — 今天结束前

请重新添加一个在 23 小时内到期的任务。" \
        --width=450 \
        2>/dev/null || true
}

show_error_add_failed() {
    zenity --error \
        --title="❌ 错误" \
        --text="添加任务失败，请检查格式后重试。

正确格式示例：
  完成报告 due:today
  开会 due:tomorrow
  提交文档 due:eod" \
        --width=400 \
        2>/dev/null || true
}
DIALOG_SCRIPT="$HOME/.taskList/window.py"

# Enhanced dialog loop with 5-minute prevention
run_dialog_loop() {
    log "Starting dialog (PyQt6)..."
    mark_dialog_started

    # Track last user input time
    local last_input_time=$(date +%s)

    while true; do
        if has_valid_tasks; then
            log "Valid tasks found, skipping dialog"
            clear_dialog_state
            return 0
        fi

        # Check if dialog should be restarted (5-minute rule)
        local now=$(date +%s)
        local elapsed=$((now - last_input_time))

        if [[ "$elapsed" -ge 300 ]]; then  # 5 minutes
            log "More than 5 minutes since last input, not restarting dialog"
            clear_dialog_state
            return 0
        fi

        QT_QPA_PLATFORM=xcb python3 "$DIALOG_SCRIPT"

        # Check if dialog was closed by user (file exists means dialog was active)
        if [[ -f "$DIALOG_START_FILE" ]]; then
            # Update last input time
            last_input_time=$(date +%s)
        fi

        if has_valid_tasks; then
            log "Tasks found after dialog"
            clear_dialog_state
            return 0
        fi

        log "Dialog closed without valid task, reopening..."
        sleep 0.5
    done
}
#-----------------------------------------------------------------------------
# Cleanup
#-----------------------------------------------------------------------------

cleanup() {
    log "Daemon shutting down..."
    kill_zenity
    rm -f "$LOCK_FILE"
    rm -f "$DIALOG_START_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP EXIT

#-----------------------------------------------------------------------------
# Main
#-----------------------------------------------------------------------------

main() {
    log "=========================================="
    log "Task Monitor Daemon starting..."
    log "=========================================="

    init
    get_dialog_dimensions

    log "Configuration:"
    log "  CHECK_INTERVAL: ${CHECK_INTERVAL}s ($(( CHECK_INTERVAL / 60 )) minutes)"
    log "  TASK_HORIZON: ${TASK_HORIZON}"
    log "  STATE_DIR: ${STATE_DIR}"

    # Main monitoring loop
    while true; do
        local task_count
        task_count=$(check_tasks_count)
        log "Checking tasks: $task_count task(s) due within 23h (excluding overdue)"

        if [[ "$task_count" -eq 0 ]]; then
            # No valid tasks - need to show dialog
            if is_dialog_recently_started; then
                log "Dialog was recently shown, skipping (5-minute rule)"
            else
                log "No tasks within 23h horizon, showing dialog..."
                run_dialog_loop
            fi
        else
            # Tasks exist, clear any dialog state
            clear_dialog_state
            log "Tasks present, all good"
        fi

        sleep "$CHECK_INTERVAL"
    done
}

main "$@"
EOF

    chmod +x "$tasklist_dir/task_monitor_daemon.sh"
    log_success "task_monitor_daemon.sh 创建完成"
}

# 创建 window.py
create_window() {
    local tasklist_dir="$HOME/.taskList"

    log_info "创建 window.py..."

    cat << 'EOF' > "$tasklist_dir/window.py"
#!/usr/bin/env python3
"""
Task Dialog - Always-on-top dialog for task input (Wayland compatible)
"""
#!/usr/bin/env python3
"""
Task Dialog - Always-on-top dialog for task input (Wayland compatible)
"""

import sys
import subprocess
from PyQt6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QHBoxLayout,
    QLabel, QLineEdit, QPushButton, QFrame
)
from PyQt6.QtCore import Qt, QTimer, QPoint
from PyQt6.QtGui import QFont, QMouseEvent


class TaskDialog(QWidget):
    def __init__(self):
        super().__init__()
        
        # 关键：使用和你代码相同的窗口标志
        self.setWindowFlags(
            Qt.WindowType.Tool |
            Qt.WindowType.FramelessWindowHint |
            Qt.WindowType.WindowStaysOnTopHint
        )
        
        # 获取屏幕尺寸，设置70%大小
        screen = QApplication.primaryScreen()
        screen_geometry = screen.availableGeometry()
        width = int(screen_geometry.width() * 0.7)
        height = int(screen_geometry.height() * 0.7)
        
        self.setFixedSize(width, height)
        
        # 居中显示
        x = (screen_geometry.width() - width) // 2
        y = (screen_geometry.height() - height) // 2
        self.move(x, y)
        
        # 样式
        self.setStyleSheet("""
            QWidget {
                background-color: #fafafa;
                border-radius: 12px;
            }
        """)
        
        # 拖动支持
        self.dragging = False
        self.offset = QPoint()
        
        self.initUI()
        
        # 定时检查任务
        self.check_timer = QTimer()
        self.check_timer.timeout.connect(self.check_tasks_external)
        self.check_timer.start(2000)
        
        # 定时确保置顶
        self.top_timer = QTimer()
        self.top_timer.timeout.connect(self.ensure_on_top)
        self.top_timer.start(500)
    
    def initUI(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(50, 40, 50, 40)
        layout.setSpacing(20)
        
        # 标题栏（可拖动区域）
        title_bar = QHBoxLayout()
        
        title = QLabel("⚠️ 您在未来 23 小时内没有待处理的任务！")
        title_font = QFont()
        title_font.setPointSize(18)
        title_font.setBold(True)
        title.setFont(title_font)
        title.setStyleSheet("color: #c01c28;")
        title_bar.addWidget(title)
        
        title_bar.addStretch()
        
        layout.addLayout(title_bar)
        
        # 副标题
        subtitle = QLabel("请添加一个任务来关闭此窗口。")
        subtitle_font = QFont()
        subtitle_font.setPointSize(13)
        subtitle.setFont(subtitle_font)
        subtitle.setStyleSheet("color: #555;")
        subtitle.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(subtitle)
        
        # 分隔线
        line1 = QFrame()
        line1.setFrameShape(QFrame.Shape.HLine)
        line1.setStyleSheet("background-color: #ddd;")
        line1.setFixedHeight(1)
        layout.addWidget(line1)
        
        # 帮助文本
        help_text = QLabel("""<b>格式：</b>任务描述 due:到期时间<br><br>
<b>示例：</b><br>
&nbsp;&nbsp;• 完成报告 due:today<br>
&nbsp;&nbsp;• 开会讨论 due:tomorrow<br>
&nbsp;&nbsp;• 回复邮件 due:2h<br>
&nbsp;&nbsp;• 提交文档 due:eod""")
        help_text.setTextFormat(Qt.TextFormat.RichText)
        help_font = QFont()
        help_font.setPointSize(12)
        help_text.setFont(help_font)
        help_text.setStyleSheet("color: #333;")
        layout.addWidget(help_text)
        
        # 分隔线
        line2 = QFrame()
        line2.setFrameShape(QFrame.Shape.HLine)
        line2.setStyleSheet("background-color: #ddd;")
        line2.setFixedHeight(1)
        layout.addWidget(line2)
        
        # 输入区域
        input_layout = QHBoxLayout()
        
        self.entry = QLineEdit()
        self.entry.setPlaceholderText("输入任务，例如：完成报告 due:today")
        self.entry.setFont(QFont("", 13))
        self.entry.setMinimumHeight(45)
        self.entry.setStyleSheet("""
            QLineEdit {
                border: 2px solid #ccc;
                border-radius: 8px;
                padding: 8px 12px;
                background: white;
            }
            QLineEdit:focus {
                border-color: #3584e4;
            }
        """)
        self.entry.returnPressed.connect(self.on_submit)
        input_layout.addWidget(self.entry)
        
        submit_btn = QPushButton("添加任务")
        submit_btn.setFont(QFont("", 13))
        submit_btn.setMinimumHeight(45)
        submit_btn.setMinimumWidth(120)
        submit_btn.setCursor(Qt.CursorShape.PointingHandCursor)
        submit_btn.setStyleSheet("""
            QPushButton {
                background-color: #3584e4;
                color: white;
                border: none;
                border-radius: 8px;
                padding: 10px 20px;
            }
            QPushButton:hover {
                background-color: #1c71d8;
            }
            QPushButton:pressed {
                background-color: #1a5fb4;
            }
        """)
        submit_btn.clicked.connect(self.on_submit)
        input_layout.addWidget(submit_btn)
        
        layout.addLayout(input_layout)
        
        # 状态标签
        self.status_label = QLabel("提示：此窗口将保持打开直到您添加有效任务（可拖动窗口）")
        self.status_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.status_label.setFont(QFont("", 10))
        self.status_label.setStyleSheet("color: #888; font-style: italic;")
        layout.addWidget(self.status_label)
        
        layout.addStretch()
    def closeEvent(self, event):
        # 停止所有定时器（虽然 quit 会自动处理，但这样更保险）
        self.check_timer.stop()
        self.top_timer.stop()
        
        # 强制退出应用程序事件循环
        QApplication.quit()
        
        # 接受关闭事件
        event.accept()
    # 拖动支持
    def mousePressEvent(self, event: QMouseEvent):
        if event.button() == Qt.MouseButton.LeftButton:
            self.dragging = True
            self.offset = event.pos()
    
    def mouseMoveEvent(self, event: QMouseEvent):
        if self.dragging:
            self.move(event.globalPosition().toPoint() - self.offset)
    
    def mouseReleaseEvent(self, event: QMouseEvent):
        if event.button() == Qt.MouseButton.LeftButton:
            self.dragging = False
    
    def ensure_on_top(self):
        self.raise_()
        self.activateWindow()
    
    def on_submit(self):
        task_input = self.entry.text().strip()
        
        if not task_input:
            self.show_error("请输入任务内容")
            return
        
        try:
            result = subprocess.run(
                ["task", "add"] + task_input.split(),
                capture_output=True,
                text=True
            )
            
            if result.returncode != 0:
                self.show_error(f"添加失败：{result.stderr}")
                return
                
        except Exception as e:
            self.show_error(f"执行错误：{e}")
            return
        
        if self.has_valid_tasks():
            self.show_success()
            QTimer.singleShot(1000, QApplication.quit)
        else:
            self.show_warning("任务已添加，但到期时间不在未来 23 小时内")
            self.entry.clear()
    
    def has_valid_tasks(self):
        try:
            result = subprocess.run(
                ["task", "due.before:now+23h", "status:pending", "-OVERDUE", "count"],
                capture_output=True,
                text=True
            )
            return int(result.stdout.strip()) > 0
        except:
            return False
    
    def check_tasks_external(self):
        if self.has_valid_tasks():
            self.check_timer.stop()
            self.top_timer.stop()
            QApplication.quit()
    
    def show_error(self, msg):
        self.status_label.setText(f"❌ {msg}")
        self.status_label.setStyleSheet("color: #c01c28; font-weight: bold;")
    
    def show_warning(self, msg):
        self.status_label.setText(f"⚠️ {msg}")
        self.status_label.setStyleSheet("color: #e5a50a; font-weight: bold;")
    
    def show_success(self):
        self.status_label.setText("✓ 任务已成功添加！")
        self.status_label.setStyleSheet("color: #26a269; font-weight: bold;")


def main():
    # 先检查是否需要显示
    try:
        result = subprocess.run(
            ["task", "due.before:now+23h", "status:pending", "-OVERDUE", "count"],
            capture_output=True,
            text=True
        )
        if int(result.stdout.strip()) > 0:
            sys.exit(0)
    except:
        pass
    
    app = QApplication(sys.argv)
    app.setStyle("Fusion")
    
    dialog = TaskDialog()
    dialog.show()
    
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

EOF

    chmod +x "$tasklist_dir/window.py"
    log_success "window.py 创建完成"
}

# 创建 .conkyrc
create_conkyrc() {
    local user_home=$(get_user_home)

    log_info "创建 .conkyrc..."

    cat << 'EOF' > "$user_home/.conkyrc"
conky.config = {
    alignment = 'top_right',
    background = false,
    border_width = 1,
    default_color = 'white',
    default_outline_color = 'white',
    default_shade_color = 'white',
    draw_borders = false,
    draw_graph_borders = true,
    draw_outline = false,
    draw_shades = false,
    use_xft = true,
    font = 'Noto Sans CJK SC:size=14',
    gap_x = 20,
    gap_y = 50,
    minimum_width = 280,
    net_avg_samples = 2,
    no_buffers = true,
    out_to_console = false,
    own_window = true,
    own_window_class = 'Conky',
    own_window_type = 'desktop',
    own_window_transparent = true,
    own_window_argb_visual = true,
    own_window_hints = 'undecorated,below,sticky,skip_taskbar,skip_pager',
    stippled_borders = 0,
    update_interval = 10,
    uppercase = false,
    use_spacer = 'none',
    show_graph_scale = false,
    show_graph_range = false,
    double_buffer = true,
    override_utf8_locale = true,
}

conky.text = [[
${color FFA726}今日待办${color}
${color grey}──────────────────${color}
${execpi 5 bash ~/.config/conky/overdue_tasks.sh}
${color white}进行中${color}
${execi 10 task status:pending due:today -OVERDUE list limit:10 rc.verbose=nothing rc.defaultwidth=50 \
  rc.report.list.columns=id,due.relative,description \
  rc.report.list.labels=ID,Due,Task}
${color grey}──────────────────${color}
${color #88FFFF}明天及以后${color}
${execi 60 task due.after:tomorrow status:pending -OVERDUE list limit:10 rc.verbose=nothing rc.defaultwidth=50 \
  rc.report.list.columns=id,due.relative,description \
  rc.report.list.labels=ID,Due,Task}
]]
EOF

    log_success ".conkyrc 创建完成"
}

# 创建自启动文件
create_autostart() {
    local autostart_dir="$HOME/.config/autostart"
    local tasklist_dir="$HOME/.taskList"

    log_info "创建自启动文件..."

    # Conky自启动
    cat << 'EOF' > "$autostart_dir/conky.desktop"
[Desktop Entry]
Type=Application
Name=Conky
Exec=/usr/bin/conky
StartupNotify=false
Terminal=false
X-GNOME-Autostart-Delay=5
EOF

    # TaskBoard自启动
    cat << EOF > "$autostart_dir/task_board.desktop"
[Desktop Entry]
Type=Application
Name=TaskBoard Monitor
Exec=bash "$tasklist_dir/task_monitor_daemon.sh"
StartupNotify=false
Terminal=false
X-GNOME-Autostart-Delay=10
EOF

    log_success "自启动文件创建完成"
}

# 初始化Taskwarrior
initialize_taskwarrior() {
    log_info "初始化Taskwarrior..."

    # 检查是否已经初始化
    if [[ ! -d "$HOME/.task" ]]; then
        log_info "首次使用Taskwarrior，正在进行初始化..."
        task &>/dev/null || true
        log_success "Taskwarrior初始化完成"
    else
        log_info "Taskwarrior已经初始化"
    fi
}

# 主安装函数
main() {
    echo "=========================================="
    echo "    TaskBoard Pro 安装脚本"
    echo "=========================================="
    echo

    # 检查系统
    detect_system

    # 检查权限
    check_root

    # 安装依赖
    install_dependencies

    # 创建目录
    create_directories

    # 创建所有脚本文件
    create_overdue_tasks
    create_today_table
    create_task_monitor_daemon
    create_window
    create_conkyrc
    create_autostart

    # 初始化Taskwarrior
    initialize_taskwarrior

    echo
    echo "=========================================="
    log_success "安装完成！"
    echo "=========================================="
    echo
    echo "使用说明："
    echo "1. 首次使用Taskwarrior，请在终端运行一次 'task' 命令来初始化配置"
    echo "2. 运行 'conky' 启动桌面小部件"
    echo "3. 将以下命令添加到 ~/.profile 或 ~/.bashrc 以开机启动："
    echo "   conky &"
    echo "   bash $HOME/.taskList/task_monitor_daemon.sh &"
    echo
    echo "项目文件位置："
    echo "  - Conky配置: ~/.conkyrc"
    echo "  - 脚本文件: ~/.taskList/"
    echo "  - 自启动配置: ~/.config/autostart/"
    echo
    echo "卸载："
    echo "  rm -rf ~/.taskList/ ~/.conkyrc ~/.config/autostart/conky.desktop ~/.config/autostart/task_board.desktop"
    echo
    echo "项目主页：https://github.com/ASGPIPO/TaskBoard-or-Ubuntu-Gnome"
}

# 捕获中断信号
trap 'log_error "安装被中断"; exit 1' INT TERM

# 运行主函数
main "$@"
