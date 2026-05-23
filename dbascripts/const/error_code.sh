#!/bin/bash

readonly ERR_SUCCESS=0
readonly ERR_PARAM_VALIDATION=100
readonly ERR_DEPENDENCY_CHECK=101
readonly ERR_META_DB_CONNECTION=102
readonly ERR_MASTER_DB_CONNECTION=103
readonly ERR_SLAVE_DB_CONNECTION=104
readonly ERR_SSH_CONNECTION=105
readonly ERR_REPLICATION_LAG_CHECK=106
readonly ERR_MASTER_SLAVE_SWITCH=107
readonly ERR_META_UPDATE=108
readonly ERR_ACCOUNT_LOCK=109
readonly ERR_TIMEOUT=110

readonly ERR_MSG_UNKNOWN="未知错误"
readonly ERR_MSG_SUCCESS="执行成功"
readonly ERR_MSG_PARAM_VALIDATION="参数验证失败"
readonly ERR_MSG_DEPENDENCY_CHECK="依赖检查失败"
readonly ERR_MSG_META_DB_CONNECTION="元数据库连接失败"
readonly ERR_MSG_MASTER_DB_CONNECTION="主库连接失败"
readonly ERR_MSG_SLAVE_DB_CONNECTION="从库连接失败"
readonly ERR_MSG_SSH_CONNECTION="SSH连接失败"
readonly ERR_MSG_REPLICATION_LAG_CHECK="主从复制延迟检查失败"
readonly ERR_MSG_MASTER_SLAVE_SWITCH="主从复制切换失败"
readonly ERR_MSG_META_UPDATE="元数据更新失败"
readonly ERR_MSG_ACCOUNT_LOCK="用户权限锁定失败"
readonly ERR_MSG_TIMEOUT="超时退出"

declare -A ERROR_MESSAGES=(
    [${ERR_SUCCESS}]="${ERR_MSG_SUCCESS}"
    [${ERR_PARAM_VALIDATION}]="${ERR_MSG_PARAM_VALIDATION}"
    [${ERR_DEPENDENCY_CHECK}]="${ERR_MSG_DEPENDENCY_CHECK}"
    [${ERR_META_DB_CONNECTION}]="${ERR_MSG_META_DB_CONNECTION}"
    [${ERR_MASTER_DB_CONNECTION}]="${ERR_MSG_MASTER_DB_CONNECTION}"
    [${ERR_SLAVE_DB_CONNECTION}]="${ERR_MSG_SLAVE_DB_CONNECTION}"
    [${ERR_SSH_CONNECTION}]="${ERR_MSG_SSH_CONNECTION}"
    [${ERR_REPLICATION_LAG_CHECK}]="${ERR_MSG_REPLICATION_LAG_CHECK}"
    [${ERR_MASTER_SLAVE_SWITCH}]="${ERR_MSG_MASTER_SLAVE_SWITCH}"
    [${ERR_META_UPDATE}]="${ERR_MSG_META_UPDATE}"
    [${ERR_ACCOUNT_LOCK}]="${ERR_MSG_ACCOUNT_LOCK}"
    [${ERR_TIMEOUT}]="${ERR_MSG_TIMEOUT}"
)

get_error_message() {
    local error_code=$1
    echo "${ERROR_MESSAGES[$error_code]:-${ERR_MSG_UNKNOWN}}"
}

exit_with_error() {
    local error_code=$1
    local error_msg=$(get_error_message $error_code)
    echo "错误: ${error_msg} (错误码: ${error_code})" >&2
    exit $error_code
}

check_error_code() {
    local error_code=$1
    if [ $error_code -ne 0 ]; then
        exit_with_error $error_code
    fi
}
