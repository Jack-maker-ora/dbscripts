#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/../const/error_code.sh"
source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

SSH_TIMEOUT="${SSH_TIMEOUT:-30}"
SSH_OPTIONS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=${SSH_TIMEOUT} -o BatchMode=yes"

ssh_connect_test() {
    local host=$1
    local user=$2
    local password=${3:-""}

    log_info "测试SSH连接: ${user}@${host}"

    local cmd="ssh ${SSH_OPTIONS} ${user}@${host} 'echo ok'"

    if [ -n "$password" ]; then
        if command -v sshpass >/dev/null 2>&1; then
            result=$(sshpass -p "$password" ssh ${SSH_OPTIONS} -o PreferredAuthentications=password -o PubkeyAuthentication=no ${user}@${host} 'echo ok' 2>&1)
        else
            log_warning "sshpass未安装，使用密钥认证"
            result=$(eval $cmd 2>&1)
        fi
    else
        result=$(eval $cmd 2>&1)
    fi

    if [ "$result" = "ok" ]; then
        log_success "SSH连接成功: ${user}@${host}"
        return 0
    else
        log_error "SSH连接失败: ${user}@${host} - $result"
        return $ERR_SSH_CONNECTION
    fi
}

ssh_exec_remote() {
    local host=$1
    local user=$2
    local password=$3
    local remote_cmd=$4

    log_debug "远程执行命令: ${host} - ${remote_cmd}"

    local ssh_cmd="ssh ${SSH_OPTIONS} ${user}@${host}"

    local result

    if [ -n "$password" ]; then
        if command -v sshpass >/dev/null 2>&1; then
            result=$(sshpass -p "$password" ssh ${SSH_OPTIONS} -o PreferredAuthentications=password -o PubkeyAuthentication=no ${user}@${host} "$remote_cmd" 2>&1)
        else
            log_warning "sshpass未安装，使用密钥认证"
            result=$(eval $ssh_cmd "$remote_cmd" 2>&1)
        fi
    else
        result=$(eval $ssh_cmd "$remote_cmd" 2>&1)
    fi

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_debug "命令执行成功: ${host} - exit_code=0"
    else
        log_error "命令执行失败: ${host} - exit_code=${exit_code} - $result"
    fi

    echo "$result"
    return $exit_code
}

ssh_check_file_exists() {
    local host=$1
    local user=$2
    local password=$3
    local file_path=$4

    local cmd="test -e ${file_path} && echo 'exists' || echo 'not_exists'"

    local result
    result=$(ssh_exec_remote "$host" "$user" "$password" "$cmd")

    if [ "$result" = "exists" ]; then
        return 0
    else
        return 1
    fi
}

ssh_backup_file() {
    local host=$1
    local user=$2
    local password=$3
    local file_path=$4

    log_info "备份文件: ${host}:${file_path}"

    local backup_path="${file_path}.backup.$(date '+%Y%m%d_%H%M%S')"

    local cmd="cp ${file_path} ${backup_path}"

    local result
    result=$(ssh_exec_remote "$host" "$user" "$password" "$cmd")

    if [ $? -eq 0 ]; then
        log_success "文件备份成功: ${backup_path}"
        echo "$backup_path"
        return 0
    else
        log_error "文件备份失败: $result"
        return 1
    fi
}

ssh_find_mysql_config_file() {
    local host=$1
    local user=$2
    local password=$3

    log_info "查找MySQL配置文件: ${host}"

    local search_paths="/etc/my.cnf /etc/mysql/my.cnf /etc/my.cnf.d/my.cnf /var/lib/mysql/my.cnf ~/.my.cnf"

    for config_file in $search_paths; do
        local cmd="test -f ${config_file} && echo '${config_file}'"

        local result
        result=$(ssh_exec_remote "$host" "$user" "$password" "$cmd")

        if [ -n "$result" ]; then
            log_success "找到MySQL配置文件: ${result}"
            echo "$result"
            return 0
        fi
    done

    log_warning "未找到MySQL配置文件"
    return 1
}

ssh_modify_mycnf() {
    local host=$1
    local user=$2
    local password=$3
    local config_file=$4
    local parameter=$5
    local value=$6

    log_info "修改MySQL配置: ${host}:${config_file} - ${parameter}=${value}"

    if ! ssh_check_file_exists "$host" "$user" "$password" "$config_file"; then
        log_error "配置文件不存在: ${config_file}"
        return 1
    fi

    local backup_path
    backup_path=$(ssh_backup_file "$host" "$user" "$password" "$config_file")

    if [ $? -ne 0 ]; then
        log_error "配置文件备份失败"
        return 1
    fi

    local check_param_cmd="grep -q '^${parameter}' ${config_file} && echo 'exists' || echo 'not_exists'"
    local param_exists

    param_exists=$(ssh_exec_remote "$host" "$user" "$password" "$check_param_cmd")

    local modify_cmd

    if [ "$param_exists" = "exists" ]; then
        log_info "参数已存在，修改参数值"
        modify_cmd="sed -i 's/^${parameter}.*/${parameter} = ${value}/' ${config_file}"
    else
        log_info "参数不存在，添加新参数"

        local section_check_cmd="grep -q '^\[mysqld\]' ${config_file} && echo 'in_section' || echo 'not_in_section'"
        local section_exists

        section_exists=$(ssh_exec_remote "$host" "$user" "$password" "$section_check_cmd")

        if [ "$section_exists" = "in_section" ]; then
            modify_cmd="sed -i '/^\[mysqld\]/a ${parameter} = ${value}' ${config_file}"
        else
            modify_cmd="echo -e '[mysqld]\n${parameter} = ${value}' >> ${config_file}"
        fi
    fi

    local result
    result=$(ssh_exec_remote "$host" "$user" "$password" "$modify_cmd")

    if [ $? -eq 0 ]; then
        log_success "配置修改成功: ${parameter}=${value}"

        local verify_cmd="grep '^${parameter}' ${config_file}"
        local verify_result

        verify_result=$(ssh_exec_remote "$host" "$user" "$password" "$verify_cmd")

        log_info "验证配置: ${verify_result}"

        return 0
    else
        log_error "配置修改失败: $result"
        log_error "尝试恢复备份: ${backup_path}"

        ssh_exec_remote "$host" "$user" "$password" "cp ${backup_path} ${config_file}"

        return 1
    fi
}

ssh_restart_mysql() {
    local host=$1
    local user=$2
    local password=$3

    log_info "重启MySQL服务: ${host}"

    local service_name="mysqld"

    local check_systemd_cmd="which systemctl >/dev/null 2>&1 && echo 'systemd' || echo 'sysv'"
    local init_system

    init_system=$(ssh_exec_remote "$host" "$user" "$password" "$check_systemd_cmd")

    local restart_cmd

    if [ "$init_system" = "systemd" ]; then
        restart_cmd="systemctl restart ${service_name}"
    else
        restart_cmd="service ${service_name} restart"
    fi

    local result
    result=$(ssh_exec_remote "$host" "$user" "$password" "$restart_cmd")

    if [ $? -eq 0 ]; then
        log_success "MySQL服务重启成功"

        sleep 3

        local status_cmd
        if [ "$init_system" = "systemd" ]; then
            status_cmd="systemctl status ${service_name}"
        else
            status_cmd="service ${service_name} status"
        fi

        ssh_exec_remote "$host" "$user" "$password" "$status_cmd"

        return 0
    else
        log_error "MySQL服务重启失败: $result"
        return 1
    fi
}

ssh_get_mysql_config_value() {
    local host=$1
    local user=$2
    local password=$3
    local config_file=$4
    local parameter=$5

    local cmd="grep '^${parameter}' ${config_file} | sed 's/.*=\s*//' | tr -d ' '"

    local result
    result=$(ssh_exec_remote "$host" "$user" "$password" "$cmd")

    if [ -n "$result" ]; then
        echo "$result"
        return 0
    else
        return 1
    fi
}

ssh_execute_with_retry() {
    local host=$1
    local user=$2
    local password=$3
    local remote_cmd=$4
    local max_retries=${5:-3}
    local retry_interval=${6:-5}

    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        log_info "尝试执行命令 (${retry_count}/${max_retries}): ${host}"

        local result
        result=$(ssh_exec_remote "$host" "$user" "$password" "$remote_cmd")

        if [ $? -eq 0 ]; then
            log_success "命令执行成功"
            echo "$result"
            return 0
        fi

        retry_count=$((retry_count + 1))

        if [ $retry_count -lt $max_retries ]; then
            log_warning "命令执行失败，${retry_interval}秒后重试..."
            sleep $retry_interval
        fi
    done

    log_error "命令执行失败，已重试 ${max_retries} 次"
    return 1
}

ssh_transfer_file() {
    local local_file=$1
    local remote_host=$2
    local remote_user=$3
    local remote_path=$4
    local password=${5:-""}

    log_info "传输文件: ${local_file} -> ${remote_user}@${remote_host}:${remote_path}"

    local scp_cmd="scp ${SSH_OPTIONS} ${local_file} ${remote_user}@${remote_host}:${remote_path}"

    local result

    if [ -n "$password" ]; then
        if command -v sshpass >/dev/null 2>&1; then
            result=$(sshpass -p "$password" scp ${SSH_OPTIONS} -o PreferredAuthentications=password -o PubkeyAuthentication=no "${local_file}" "${remote_user}@${remote_host}:${remote_path}" 2>&1)
        else
            log_warning "sshpass未安装，使用密钥认证"
            result=$(eval $scp_cmd 2>&1)
        fi
    else
        result=$(eval $scp_cmd 2>&1)
    fi

    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "文件传输成功"
        return 0
    else
        log_error "文件传输失败: $result"
        return 1
    fi
}

ssh_get_file_content() {
    local host=$1
    local user=$2
    local password=$3
    local remote_file=$4

    local cmd="cat ${remote_file}"

    ssh_exec_remote "$host" "$user" "$password" "$cmd"
}
