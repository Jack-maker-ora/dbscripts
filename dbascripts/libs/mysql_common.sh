#!/bin/bash

source "$(dirname "${BASH_SOURCE[0]}")/../const/error_code.sh"
source "$(dirname "${BASH_SOURCE[0]}")/logger.sh"

MYSQL_TIMEOUT="${MYSQL_TIMEOUT:-30}"
MYSQL_DEFAULT_PORT="${MYSQL_DEFAULT_PORT:-3306}"

mysql_exec_query() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local database=$5
    local query=$6
    local output_mode=${7:-"value"}

    local password_env="MYSQL_PASSWORD=${password}"
    local cmd="mysql -h ${host} -P ${port} -u ${user}"

    if [ -n "$database" ]; then
        cmd="${cmd} ${database}"
    fi

    cmd="${cmd} -N -e \"${query}\""

    local result
    local exit_code

    if [ -z "$password" ]; then
        result=$(eval $cmd 2>&1)
        exit_code=$?
    else
        result=$(MYSQL_PASSWORD="${password}" eval $cmd 2>&1)
        exit_code=$?
    fi

    if [ $exit_code -ne 0 ]; then
        log_error "MySQL查询执行失败: $result"
        return $exit_code
    fi

    echo "$result"
    return 0
}

mysql_connect_test() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local database=${5:-""}

    log_info "测试MySQL连接: ${host}:${port}"

    local test_query="SELECT 1"
    local result

    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "$database" "$test_query" 2>&1)
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        log_success "MySQL连接成功: ${host}:${port}"
        return 0
    else
        log_error "MySQL连接失败: ${host}:${port} - $result"
        return $ERR_MASTER_DB_CONNECTION
    fi
}

mysql_get_master_info() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4

    log_info "获取主库信息: ${host}:${port}"

    local query="SHOW MASTER STATUS"
    local result

    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$query" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "获取主库状态失败: $result"
        return 1
    fi

    local file=$(echo "$result" | awk '{print $1}')
    local position=$(echo "$result" | awk '{print $2}')
    local gtid=$(echo "$result" | awk '{print $3}')

    echo "${file}|${position}|${gtid}"
    return 0
}

mysql_get_slave_info() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4

    log_info "获取从库信息: ${host}:${port}"

    local query="SHOW SLAVE STATUS\\G"
    local result

    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$query" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "获取从库状态失败: $result"
        return 1
    fi

    local master_host=$(echo "$result" | grep "Master_Host:" | awk '{print $2}')
    local master_port=$(echo "$result" | grep "Master_Port:" | awk '{print $2}')
    local slave_io_running=$(echo "$result" | grep "Slave_IO_Running:" | awk '{print $2}')
    local slave_sql_running=$(echo "$result" | grep "Slave_SQL_Running:" | awk '{print $2}')
    local executed_gtid=$(echo "$result" | grep "Executed_Gtid_Set:" | awk '{print $2}')
    local last_error=$(echo "$result" | grep "Last_Error:" | awk '{print $2" "$3" "$4}')

    echo "${master_host}|${master_port}|${slave_io_running}|${slave_sql_running}|${executed_gtid}|${last_error}"
    return 0
}

mysql_set_readonly() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local readonly=${5:-"ON"}

    log_info "设置只读模式: ${host}:${port} -> ${readonly}"

    local readonly_value
    if [ "$readonly" = "ON" ]; then
        readonly_value=1
    else
        readonly_value=0
    fi

    local queries="
FLUSH TABLES WITH READ LOCK;
SET GLOBAL read_only=${readonly_value};
SET GLOBAL super_read_only=${readonly_value};
UNLOCK TABLES;
"

    local result
    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$queries" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "设置只读模式失败: $result"
        return 1
    fi

    log_success "只读模式设置成功"
    return 0
}

mysql_verify_readonly() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local expected=${5:-"ON"}

    log_info "验证只读状态: ${host}:${port}"

    local query="SELECT @@global.read_only"
    local result

    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$query" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "查询只读状态失败: $result"
        return 1
    fi

    local current_value=$(echo "$result" | tr -d '[:space:]')

    if [ "$expected" = "ON" ] && [ "$current_value" = "1" ]; then
        log_success "只读状态验证通过: read_only=1"
        return 0
    elif [ "$expected" = "OFF" ] && [ "$current_value" = "0" ]; then
        log_success "只读状态验证通过: read_only=0"
        return 0
    else
        log_error "只读状态不匹配: 期望 ${expected}, 实际 ${current_value}"
        return 1
    fi
}

mysql_lock_accounts() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local account_patterns=${5:-"code,dbops,boyun_read,query_bigdata"}

    log_info "锁定敏感账户: ${host}:${port}"

    IFS=',' read -ra PATTERNS <<< "$account_patterns"

    for pattern in "${PATTERNS[@]}"; do
        log_info "查找匹配账户: ${pattern}%"

        local find_query="SELECT CONCAT(user, '@', host) FROM mysql.user WHERE user LIKE '${pattern}%'"
        local accounts

        accounts=$(mysql_exec_query "$host" "$port" "$user" "$password" "mysql" "$find_query" 2>&1)

        if [ -z "$accounts" ]; then
            log_warning "未找到匹配账户: ${pattern}%"
            continue
        fi

        while IFS= read -r account; do
            [ -z "$account" ] && continue

            log_info "锁定账户: ${account}"

            local lock_query="ALTER USER '${account}' ACCOUNT LOCK"
            local result

            result=$(mysql_exec_query "$host" "$port" "$user" "$password" "mysql" "$lock_query" 2>&1)
            local exit_code=$?

            if [ $exit_code -eq 0 ]; then
                log_success "账户锁定成功: ${account}"
            else
                log_error "账户锁定失败: ${account} - $result"
            fi
        done <<< "$accounts"
    done

    log_success "账户锁定操作完成"
    return 0
}

mysql_unlock_accounts() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local account_patterns=${5:-"code,dbops,boyun_read,query_bigdata"}

    log_info "解锁敏感账户: ${host}:${port}"

    IFS=',' read -ra PATTERNS <<< "$account_patterns"

    for pattern in "${PATTERNS[@]}"; do
        log_info "查找匹配账户: ${pattern}%"

        local find_query="SELECT CONCAT(user, '@', host) FROM mysql.user WHERE user LIKE '${pattern}%'"
        local accounts

        accounts=$(mysql_exec_query "$host" "$port" "$user" "$password" "mysql" "$find_query" 2>&1)

        if [ -z "$accounts" ]; then
            log_warning "未找到匹配账户: ${pattern}%"
            continue
        fi

        while IFS= read -r account; do
            [ -z "$account" ] && continue

            log_info "解锁账户: ${account}"

            local unlock_query="ALTER USER '${account}' ACCOUNT UNLOCK"
            local result

            result=$(mysql_exec_query "$host" "$port" "$user" "$password" "mysql" "$unlock_query" 2>&1)
            local exit_code=$?

            if [ $exit_code -eq 0 ]; then
                log_success "账户解锁成功: ${account}"
            else
                log_error "账户解锁失败: ${account} - $result"
            fi
        done <<< "$accounts"
    done

    log_success "账户解锁操作完成"
    return 0
}

mysql_check_replication() {
    local master_host=$1
    local master_port=$2
    local slave_host=$3
    local slave_port=$4
    local user=$5
    local password=$6

    log_info "检查主从复制状态"
    log_info "主库: ${master_host}:${master_port}"
    log_info "从库: ${slave_host}:${slave_port}"

    local master_uuid_query="SELECT @@server_uuid"
    local master_uuid

    master_uuid=$(mysql_exec_query "$master_host" "$master_port" "$user" "$password" "" "$master_uuid_query" 2>&1)
    local master_exit=$?

    if [ $master_exit -ne 0 ]; then
        log_error "获取主库UUID失败: $master_uuid"
        return 1
    fi

    local master_gtid_query="SHOW MASTER STATUS"
    local master_gtid

    master_gtid=$(mysql_exec_query "$master_host" "$master_port" "$user" "$password" "" "$master_gtid_query" 2>&1 | awk '{print $3}')
    local master_gtid_exit=$?

    if [ $master_gtid_exit -ne 0 ]; then
        log_error "获取主库GTID失败: $master_gtid"
        return 1
    fi

    local slave_gtid_query="SHOW SLAVE STATUS\\G"
    local slave_output

    slave_output=$(mysql_exec_query "$slave_host" "$slave_port" "$user" "$password" "" "$slave_gtid_query" 2>&1)
    local slave_exit=$?

    if [ $slave_exit -ne 0 ]; then
        log_error "获取从库状态失败: $slave_output"
        return 1
    fi

    local slave_gtid=$(echo "$slave_output" | grep "Executed_Gtid_Set:" | sed 's/.*: //' | tr -d '[:space:]')

    log_info "主库GTID: ${master_gtid}"
    log_info "从库GTID: ${slave_gtid}"

    if [ "$master_gtid" = "$slave_gtid" ]; then
        log_success "主从GTID一致，复制已同步"
        return 0
    else
        log_warning "主从GTID不一致，存在复制延迟"
        return 1
    fi
}

mysql_wait_for_sync() {
    local master_host=$1
    local master_port=$2
    local slave_host=$3
    local slave_port=$4
    local user=$5
    local password=$6
    local max_retries=${7:-15}
    local retry_interval=${8:-1}

    log_info "等待主从同步..."

    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
        log_info "检查同步状态 (尝试 $((retry_count + 1))/${max_retries})"

        if mysql_check_replication "$master_host" "$master_port" "$slave_host" "$slave_port" "$user" "$password"; then
            log_success "主从同步完成"
            return 0
        fi

        retry_count=$((retry_count + 1))

        if [ $retry_count -lt $max_retries ]; then
            log_info "等待 ${retry_interval} 秒后重试..."
            sleep $retry_interval
        fi
    done

    log_error "主从同步超时 (已尝试 ${max_retries} 次)"
    return $ERR_TIMEOUT
}

mysql_stop_slave() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4

    log_info "停止从库复制: ${host}:${port}"

    local query="STOP SLAVE"
    local result

    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$query" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_warning "STOP SLAVE失败: $result (可能已经停止)"
    fi

    local reset_query="RESET SLAVE ALL"
    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$reset_query" 2>&1)
    local reset_exit=$?

    if [ $reset_exit -ne 0 ]; then
        log_warning "RESET SLAVE ALL失败: $result"
    fi

    log_success "从库复制已停止"
    return 0
}

mysql_change_master() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4
    local master_host=$5
    local master_port=$6
    local master_user=${7:-"repl"}
    local master_password=${8:-""}

    log_info "修改从库复制源: ${host}:${port} -> ${master_host}:${master_port}"

    local stop_query="STOP SLAVE"
    mysql_exec_query "$host" "$port" "$user" "$password" "" "$stop_query" >/dev/null 2>&1

    local reset_query="RESET SLAVE ALL"
    mysql_exec_query "$host" "$port" "$user" "$password" "" "$reset_query" >/dev/null 2>&1

    local change_query="CHANGE MASTER TO MASTER_HOST='${master_host}', MASTER_PORT=${master_port}, MASTER_USER='${master_user}', MASTER_PASSWORD='${master_password}', GET_MASTER_PUBLIC_KEY=1, AUTO_POSITION=1"

    local result
    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$change_query" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "CHANGE MASTER TO失败: $result"
        return 1
    fi

    local start_query="START SLAVE"
    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$start_query" 2>&1)
    local start_exit=$?

    if [ $start_exit -ne 0 ]; then
        log_error "START SLAVE失败: $result"
        return 1
    fi

    sleep 2

    local status_query="SHOW SLAVE STATUS\\G"
    local status_output

    status_output=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$status_query" 2>&1)

    local io_running=$(echo "$status_output" | grep "Slave_IO_Running:" | awk '{print $2}')
    local sql_running=$(echo "$status_output" | grep "Slave_SQL_Running:" | awk '{print $2}')

    if [ "$io_running" = "Yes" ] && [ "$sql_running" = "Yes" ]; then
        log_success "从库复制配置成功"
        return 0
    else
        log_error "从库复制启动失败: IO=${io_running}, SQL=${sql_running}"
        return 1
    fi
}

mysql_get_server_id() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4

    local query="SELECT @@server_id"
    local result

    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$query" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "获取server_id失败: $result"
        return 1
    fi

    echo "$result" | tr -d '[:space:]'
    return 0
}

mysql_get_version() {
    local host=$1
    local port=$2
    local user=$3
    local password=$4

    local query="SELECT VERSION()"
    local result

    result=$(mysql_exec_query "$host" "$port" "$user" "$password" "" "$query" 2>&1)
    local exit_code=$?

    if [ $exit_code -ne 0 ]; then
        log_error "获取MySQL版本失败: $result"
        return 1
    fi

    echo "$result"
    return 0
}
