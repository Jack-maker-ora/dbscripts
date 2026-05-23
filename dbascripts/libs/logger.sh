#!/bin/bash

LOG_DIR="${LOG_DIR:-/var/log/dbascripts}"
LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_FILE="${LOG_FILE:-}"

readonly LOG_LEVEL_DEBUG=0
readonly LOG_LEVEL_INFO=1
readonly LOG_LEVEL_WARNING=2
readonly LOG_LEVEL_ERROR=3
readonly LOG_LEVEL_SUCCESS=4

declare -A LOG_LEVEL_NAMES=(
    [${LOG_LEVEL_DEBUG}]="DEBUG"
    [${LOG_LEVEL_INFO}]="INFO"
    [${LOG_LEVEL_WARNING}]="WARNING"
    [${LOG_LEVEL_ERROR}]="ERROR"
    [${LOG_LEVEL_SUCCESS}]="SUCCESS"
)

get_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

should_log() {
    local level=$1
    local current_level=$2

    case $LOG_LEVEL in
        DEBUG)
            [ $level -ge $current_level ]
            ;;
        INFO)
            [ $level -ge $LOG_LEVEL_INFO ]
            ;;
        WARNING)
            [ $level -ge $LOG_LEVEL_WARNING ]
            ;;
        ERROR)
            [ $level -ge $LOG_LEVEL_ERROR ]
            ;;
        *)
            [ $level -ge $LOG_LEVEL_INFO ]
            ;;
    esac
}

log_message() {
    local level=$1
    local message=$2
    local timestamp=$(get_timestamp)
    local level_name="${LOG_LEVEL_NAMES[$level]}"

    local log_entry="${timestamp} [${level_name}] ${message}"

    if should_log $level $LOG_LEVEL; then
        echo "$log_entry"

        if [ -n "$LOG_FILE" ]; then
            echo "$log_entry" >> "$LOG_FILE"
        fi
    fi
}

log_debug() {
    log_message $LOG_LEVEL_DEBUG "$1"
}

log_info() {
    log_message $LOG_LEVEL_INFO "$1"
}

log_warning() {
    log_message $LOG_LEVEL_WARNING "$1"
}

log_error() {
    log_message $LOG_LEVEL_ERROR "$1"
}

log_success() {
    log_message $LOG_LEVEL_SUCCESS "$1"
}

init_logger() {
    if [ -z "$LOG_FILE" ]; then
        LOG_FILE="${LOG_DIR}/dbascripts_$(date '+%Y%m%d').log"
    fi

    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
    fi

    log_info "日志系统初始化完成"
    log_info "日志级别: ${LOG_LEVEL}"
    log_info "日志文件: ${LOG_FILE}"
}
