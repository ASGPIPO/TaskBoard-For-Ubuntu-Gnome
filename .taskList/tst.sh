#!/bin/bash

TODAY=$(date +%y-%m-%d)

# 关键点：
# 1. columns请求了4列：id, due(用于判断), due.relative(用于展示), description
# 2. labels把第二列标记为 HIDDEN，方便我们肉眼调试（实际awk会处理掉它）
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
