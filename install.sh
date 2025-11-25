#!/bin/bash

# 1. 更新并静默安装软件
echo "正在安装 Taskwarrior 和 Conky..."
sudo apt-get update
sudo apt-get install -y taskwarrior conky-all

# 2. 创建目录 (使用 -p 防止已存在报错)
mkdir -p ~/.config/conky

# 3. 创建逾期检测脚本

cat << 'EOF' > ~/.config/conky/overdue_tasks.sh
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

# 赋予脚本执行权限
chmod +x ~/.config/conky/overdue_tasks.sh

# 4. 创建 Conky 配置文件
cat << 'EOF' > ~/.conkyrc
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

# 5. 设置开机自启
mkdir -p ~/.config/autostart
cat << 'EOF' > ~/.config/autostart/conky.desktop
[Desktop Entry]
Type=Application
Name=Conky
Exec=/usr/bin/conky
StartupNotify=false
Terminal=false
X-GNOME-Autostart-Delay=5
EOF

echo "安装完成！"
echo "请注意：如果你是第一次使用 taskwarrior，请先在终端运行一次 'task' 命令来初始化配置。"
echo "然后运行 'conky' 即可看到效果。"
