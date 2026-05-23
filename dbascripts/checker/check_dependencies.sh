#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/../const/error_code.sh"

check_command() {
    local cmd=$1
    local required=${2:-false}

    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    else
        if [ "$required" = true ]; then
            log_error "必需命令 '$cmd' 未找到"
            return 1
        else
            log_warning "可选命令 '$cmd' 未找到"
            return 2
        fi
    fi
}

check_mysql_client() {
    log_info "检查MySQL客户端..."

    if check_command "mysql" true; then
        local mysql_version=$(mysql --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        log_success "MySQL客户端已安装: 版本 ${mysql_version}"
        return 0
    else
        log_error "MySQL客户端检查失败"
        return $ERR_DEPENDENCY_CHECK
    fi
}

check_ssh_client() {
    log_info "检查SSH客户端..."

    if check_command "ssh" true; then
        local ssh_version=$(ssh -V 2>&1 | grep -oP 'OpenSSH[\w.-]+')
        log_success "SSH客户端已安装: ${ssh_version}"
        return 0
    else
        log_error "SSH客户端检查失败"
        return $ERR_DEPENDENCY_CHECK
    fi
}

check_expect() {
    log_info "检查Expect工具..."

    if check_command "expect" false; then
        log_success "Expect工具已安装"
        return 0
    else
        log_warning "Expect工具未安装，部分功能可能受限"
        return 0
    fi
}

check_sshpass() {
    log_info "检查sshpass工具..."

    if check_command "sshpass" false; then
        log_success "sshpass工具已安装"
        return 0
    else
        log_warning "sshpass工具未安装，将使用密钥认证"
        return 0
    fi
}

check_all_dependencies() {
    log_info "开始检查所有依赖..."

    local all_ok=true

    if ! check_mysql_client >/dev/null 2>&1; then
        all_ok=false
    fi

    if ! check_ssh_client >/dev/null 2>&1; then
        all_ok=false
    fi

    check_expect >/dev/null 2>&1
    check_sshpass >/dev/null 2>&1

    if [ "$all_ok" = true ]; then
        log_success "所有必需依赖检查通过"
        return 0
    else
        log_error "依赖检查失败，请安装缺失的组件"
        return $ERR_DEPENDENCY_CHECK
    fi
}

print_dependency_status() {
    echo "依赖检查状态:"
    echo "============="

    local mysql_status="✗ 未安装"
    local ssh_status="✗ 未安装"

    if check_command "mysql" >/dev/null 2>&1; then
        mysql_status="✓ 已安装"
    fi

    if check_command "ssh" >/dev/null 2>&1; then
        ssh_status="✓ 已安装"
    fi

    printf "%-20s %s\n" "MySQL客户端:" "$mysql_status"
    printf "%-20s %s\n" "SSH客户端:" "$ssh_status"

    echo "============="
}
