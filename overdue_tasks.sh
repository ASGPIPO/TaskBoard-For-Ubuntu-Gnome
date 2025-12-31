#!/bin/bash
n=$(task status:pending +OVERDUE count 2>/dev/null || echo 0)

if [ "$n" -gt 0 ]; then
    echo "${color red}已逾期 ($n)${color}"
    task status:pending +OVERDUE list limit:5 \
        rc.verbose=nothing \
        rc.defaultwidth=50 \
        rc.report.list.columns=id,due.relative,description \
        rc.report.list.labels=ID,Ago,Task 2>/dev/null
    echo "${color grey}──────────────────${color}"
fi
