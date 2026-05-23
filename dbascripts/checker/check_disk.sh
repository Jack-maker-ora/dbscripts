#!/bin/bash

check_disk_space() {
    local path=${1:-"/"}
    local required_mb=${2:-100}

    local available_kb=$(df -k "$path" | tail -1 | awk '{print $4}')
    local available_mb=$((available_kb / 1024))

    if [ $available_mb -lt $required_mb ]; then
        log_warning "磁盘空间不足: 需要 ${required_mb}MB，实际可用 ${available_mb}MB (路径: $path)"
        return 1
    fi

    log_info "磁盘空间检查通过: 可用 ${available_mb}MB (路径: $path)"
    return 0
}

check_disk_space_for_path() {
    local path=$1
    local required_mb=${2:-100}

    if [ ! -d "$path" ]; then
        log_warning "路径不存在: $path"
        return 1
    fi

    check_disk_space "$path" $required_mb
}

print_disk_usage() {
    local path=${1:-"/"}

    echo "磁盘使用情况 (路径: $path):"
    echo "==========================="

    df -h "$path" | tail -1 | awk '{
        printf "文件系统: %s\n", $1
        printf "总大小: %s\n", $2
        printf "已使用: %s (%.0f%%)\n", $3, $5
        printf "可用: %s\n", $4
    }'

    echo "==========================="
}

check_multiple_paths() {
    local paths=("$@")
    local all_ok=true

    for path in "${paths[@]}"; do
        if ! check_disk_space_for_path "$path" >/dev/null 2>&1; then
            all_ok=false
        fi
    done

    if [ "$all_ok" = true ]; then
        log_success "所有路径磁盘空间检查通过"
        return 0
    else
        log_error "部分路径磁盘空间不足"
        return 1
    fi
}
