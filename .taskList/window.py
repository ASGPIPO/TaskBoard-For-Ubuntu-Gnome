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
