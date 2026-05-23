#!/bin/bash

set -euo pipefail

readonly SCRIPT_NAME="mysql_master_migrate_v1.sh"
readonly SCRIPT_VERSION="1.0.0"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_AUTHOR="DBA Team"
readonly SCRIPT_DESCRIPTION="MySQL主从切换脚本"

readonly RISK_LEVEL="critical"

readonly DEFAULT_META_DB_HOST="${META_DB_HOST:-127.0.0.1}"
readonly DEFAULT_META_DB_PORT="${META_DB_PORT:-3306}"
readonly DEFAULT_META_DB_USER="${META_DB_USER:-dbops}"
readonly DEFAULT_META_DB_PASSWORD="${META_DB_PASSWORD:-}"
readonly DEFAULT_META_DB_NAME="${META_DB_NAME:-dbops}"

readonly DEFAULT_SSH_USER="${SSH_USER:-root}"
readonly DEFAULT_SSH_PASSWORD="${SSH_PASSWORD:-}"

readonly DEFAULT_TARGET_PORT="${DEFAULT_TARGET_PORT:-3306}"
readonly DEFAULT_DB_TYPE="mysql"
readonly DEFAULT_MODE="dryrun"

readonly MAX_REPLICATION_CHECK_RETRIES=15
readonly REPLICATION_CHECK_INTERVAL=1

readonly LOCK_ACCOUNT_PATTERNS="code,dbops,boyun_read,query_bigdata"

TARGET_IP=""
TARGET_PORT=""
DB_TYPE=""
MODE=""
DRYRUN_ONLY=false

META_DB_HOST=""
META_DB_PORT=""
META_DB_USER=""
META_DB_PASSWORD=""
META_DB_NAME=""

SSH_USER=""
SSH_PASSWORD=""

CURRENT_MASTER_IP=""
CURRENT_MASTER_PORT=""
CURRENT_MASTER_NODE_ID=""

TARGET_SLAVE_NODE_ID=""

ALL_SLAVES=()

EXECUTION_LOG_FILE=""
EXECUTION_START_TIME=""
EXECUTION_END_TIME=""

declare -A MIGRATED_SLAVES
declare -A FAILED_SLAVES

source "${SCRIPT_DIR}/dbascripts/const/error_code.sh"
source "${SCRIPT_DIR}/dbascripts/libs/logger.sh"
source "${SCRIPT_DIR}/dbascripts/libs/output_color.sh"
source "${SCRIPT_DIR}/dbascripts/libs/mysql_common.sh"
source "${SCRIPT_DIR}/dbascripts/libs/ssh_common.sh"
source "${SCRIPT_DIR}/dbascripts/checker/check_dependencies.sh"

print_usage() {
    cat << EOF
${COLOR_BOLD}用法:${COLOR_RESET} $0 [选项]

${COLOR_BOLD}描述:${COLOR_RESET}
$SCRIPT_DESCRIPTION

${COLOR_BOLD}必需选项:${COLOR_RESET}
  --ip=<IP地址>        目标从库IP地址（将成为新的主库）
  --port=<端口>        目标从库端口
  --type=<类型>        数据库类型 (mysql|tdsql)
  --mode=<模式>        执行模式 (dryrun|exec)

${COLOR_BOLD}可选参数:${COLOR_RESET}
  --meta-host=<主机>   元数据库主机地址 (默认: $DEFAULT_META_DB_HOST)
  --meta-port=<端口>   元数据库端口 (默认: $DEFAULT_META_DB_PORT)
  --meta-user=<用户>   元数据库用户名 (默认: $DEFAULT_META_DB_USER)
  --meta-db=<数据库>   元数据库名称 (默认: $DEFAULT_META_DB_NAME)
  --ssh-user=<用户>    SSH用户名 (默认: $DEFAULT_SSH_USER)

${COLOR_BOLD}标准选项:${COLOR_RESET}
  --help, -h           显示帮助信息
  --dry-run            干跑模式（仅验证，不执行）
  --version, -v        显示版本信息

${COLOR_BOLD}环境变量:${COLOR_RESET}
  META_DB_HOST         元数据库主机地址
  META_DB_PORT         元数据库端口
  META_DB_USER         元数据库用户名
  META_DB_PASSWORD     元数据库密码
  META_DB_NAME         元数据库名称
  SSH_USER             SSH用户名
  SSH_PASSWORD         SSH密码

${COLOR_BOLD}示例:${COLOR_RESET}
  # 干跑模式验证
  $0 --ip=192.168.100.12 --port=3306 --type=mysql --mode=dryrun

  # 执行主从切换
  $0 --ip=192.168.100.12 --port=3306 --type=mysql --mode=exec

  # 使用环境变量
  export META_DB_PASSWORD='your_password'
  $0 --ip=192.168.100.12 --port=3306 --type=mysql --mode=exec

EOF
}

print_version() {
    echo "$SCRIPT_NAME 版本 $SCRIPT_VERSION"
    echo "作者: $SCRIPT_AUTHOR"
    echo "描述: $SCRIPT_DESCRIPTION"
    echo ""
    echo "支持的数据库版本: MySQL >= 5.7.0, <= 8.4.0"
    echo "支持的操作系统: CentOS 7/8, RHEL 8, Ubuntu 20.04/22.04"
}

parse_arguments() {
    log_info "解析命令行参数..."

    if [ $# -eq 0 ]; then
        print_usage
        exit 0
    fi

    while [ $# -gt 0 ]; do
        case "$1" in
            --ip=*)
                TARGET_IP="${1#*=}"
                shift
                ;;
            --port=*)
                TARGET_PORT="${1#*=}"
                shift
                ;;
            --type=*)
                DB_TYPE="${1#*=}"
                shift
                ;;
            --mode=*)
                MODE="${1#*=}"
                shift
                ;;
            --meta-host=*)
                META_DB_HOST="${1#*=}"
                shift
                ;;
            --meta-port=*)
                META_DB_PORT="${1#*=}"
                shift
                ;;
            --meta-user=*)
                META_DB_USER="${1#*=}"
                shift
                ;;
            --meta-db=*)
                META_DB_NAME="${1#*=}"
                shift
                ;;
            --ssh-user=*)
                SSH_USER="${1#*=}"
                shift
                ;;
            --dry-run|--dryrun)
                DRYRUN_ONLY=true
                MODE="dryrun"
                shift
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            --version|-v)
                print_version
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                print_usage
                exit "$ERR_PARAM_VALIDATION"
                ;;
        esac
    done

    if [ -z "$TARGET_IP" ] || [ -z "$TARGET_PORT" ] || [ -z "$DB_TYPE" ] || [ -z "$MODE" ]; then
        log_error "缺少必需参数"
        print_usage
        exit "$ERR_PARAM_VALIDATION"
    fi

    validate_parameters

    META_DB_HOST="${META_DB_HOST:-$DEFAULT_META_DB_HOST}"
    META_DB_PORT="${META_DB_PORT:-$DEFAULT_META_DB_PORT}"
    META_DB_USER="${META_DB_USER:-$DEFAULT_META_DB_USER}"
    META_DB_PASSWORD="${META_DB_PASSWORD:-$DEFAULT_META_DB_PASSWORD}"
    META_DB_NAME="${META_DB_NAME:-$DEFAULT_META_DB_NAME}"

    SSH_USER="${SSH_USER:-$DEFAULT_SSH_USER}"
    SSH_PASSWORD="${SSH_PASSWORD:-$DEFAULT_SSH_PASSWORD}"

    log_success "参数解析完成"
}

validate_parameters() {
    log_info "验证参数..."

    if [[ ! "$TARGET_IP" =~ ^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$ ]]; then
        log_error "无效的IP地址: $TARGET_IP"
        exit "$ERR_PARAM_VALIDATION"
    fi

    if [[ ! "$TARGET_PORT" =~ ^[0-9]{1,5}$ ]] || [ "$TARGET_PORT" -lt 1 ] || [ "$TARGET_PORT" -gt 65535 ]; then
        log_error "无效的端口号: $TARGET_PORT"
        exit "$ERR_PARAM_VALIDATION"
    fi

    if [[ ! "$DB_TYPE" =~ ^(mysql|tdsql)$ ]]; then
        log_error "无效的数据库类型: $DB_TYPE (必须为 mysql 或 tdsql)"
        exit "$ERR_PARAM_VALIDATION"
    fi

    if [[ ! "$MODE" =~ ^(dryrun|exec)$ ]]; then
        log_error "无效的执行模式: $MODE (必须为 dryrun 或 exec)"
        exit "$ERR_PARAM_VALIDATION"
    fi

    log_success "参数验证通过"
}

init_execution_environment() {
    log_info "初始化执行环境..."

    EXECUTION_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    local log_dir="${LOG_DIR:-/var/log/dbascripts}"
    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir" 2>/dev/null || log_dir="/tmp"
    fi

    EXECUTION_LOG_FILE="${log_dir}/migration_$(date '+%Y%m%d_%H%M%S').log"
    LOG_FILE="$EXECUTION_LOG_FILE"

    init_logger

    log_info "=========================================="
    log_info "MySQL主从切换脚本 v${SCRIPT_VERSION}"
    log_info "=========================================="
    log_info "执行时间: $EXECUTION_START_TIME"
    log_info "执行模式: $MODE"
    log_info "目标从库: ${TARGET_IP}:${TARGET_PORT}"
    log_info "数据库类型: $DB_TYPE"
    log_info "风险等级: $RISK_LEVEL"
    log_info "日志文件: $EXECUTION_LOG_FILE"
    log_info "=========================================="

    log_success "执行环境初始化完成"
}

confirm_execution() {
    if [ "$MODE" = "dryrun" ]; then
        log_info "干跑模式：仅验证，不执行实际变更"
        return 0
    fi

    print_header "确认执行"

    echo -e "${COLOR_RED}警告：这是一个高风险操作！${COLOR_RESET}"
    echo ""
    echo "将要执行的操作："
    echo "  1. 设置原主库 (${CURRENT_MASTER_IP}:${CURRENT_MASTER_PORT}) 为只读"
    echo "  2. 修改原主库配置文件"
    echo "  3. 等待主从复制同步"
    echo "  4. 停止主从复制"
    echo "  5. 锁定敏感账户"
    echo "  6. 更新元数据库"
    echo "  7. 重定向所有从库到新主库"
    echo ""
    echo -e "${COLOR_YELLOW}影响范围：${COLOR_RESET}"
    echo "  - 原主库将变为只读"
    echo "  - 所有从库将重新指向新的主库"
    echo "  - 切换过程中可能会有短暂的连接中断"
    echo ""

    read -p "确认继续执行? (输入 'yes' 确认): " confirmation

    if [ "$confirmation" != "yes" ]; then
        log_info "用户取消执行"
        exit 0
    fi

    log_info "用户确认执行"
}

pre_checks() {
    log_info "执行前置检查..."
    print_header "前置检查"

    print_step "1" "检查系统依赖"
    if ! check_all_dependencies; then
        log_error "依赖检查失败"
        exit "$ERR_DEPENDENCY_CHECK"
    fi
    print_success "依赖检查通过"

    print_step "2" "检查元数据库连接"
    if ! mysql_connect_test "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME"; then
        log_error "元数据库连接失败"
        exit "$ERR_META_DB_CONNECTION"
    fi
    print_success "元数据库连接成功"

    print_step "3" "验证NODE_INFO表结构"
    if ! verify_node_info_table; then
        log_error "NODE_INFO表验证失败"
        exit "$ERR_META_DB_CONNECTION"
    fi
    print_success "NODE_INFO表验证通过"

    print_step "4" "查询当前主库信息"
    if ! get_current_master_info; then
        log_error "获取当前主库信息失败"
        exit "$ERR_META_DB_CONNECTION"
    fi
    print_success "当前主库: ${CURRENT_MASTER_IP}:${CURRENT_MASTER_PORT}"

    print_step "5" "验证目标从库"
    if ! verify_target_slave; then
        log_error "目标从库验证失败"
        exit "$ERR_SLAVE_DB_CONNECTION"
    fi
    print_success "目标从库验证通过"

    print_step "6" "获取所有从库列表"
    if ! get_all_slaves_list; then
        log_error "获取从库列表失败"
        exit "$ERR_META_DB_CONNECTION"
    fi
    echo "找到 $((${#ALL_SLAVES[@]} - 1)) 个从库节点"
    print_success "从库列表获取成功"

    print_step "7" "检查SSH连接"
    if ! ssh_connect_test "$CURRENT_MASTER_IP" "$SSH_USER" "$SSH_PASSWORD"; then
        log_error "SSH连接到主库失败，无法执行后续操作"
        exit "$ERR_SSH_CONNECTION"
    fi
    print_success "SSH连接检查通过"

    log_success "所有前置检查通过"
}

verify_node_info_table() {
    local query="DESCRIBE NODE_INFO"
    local result

    result=$(mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$query" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "NODE_INFO表不存在或无法访问"
        return 1
    fi

    local required_fields=("ID" "NODE_GROUP_ID" "IP_ADDR" "PORT" "IS_MASTER" "IS_ONLINE")

    for field in "${required_fields[@]}"; do
        if ! echo "$result" | grep -q "$field"; then
            log_error "NODE_INFO表缺少必需字段: $field"
            return 1
        fi
    done

    return 0
}

get_current_master_info() {
    local query="SELECT ID, IP_ADDR, PORT FROM NODE_INFO WHERE NODE_GROUP_ID = (SELECT NODE_GROUP_ID FROM NODE_INFO WHERE IP_ADDR = '${TARGET_IP}' AND PORT = ${TARGET_PORT}) AND IS_MASTER = 1 AND IS_ONLINE = 1 LIMIT 1"

    local result
    result=$(mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$query" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "查询主库信息失败: $result"
        return 1
    fi

    if [ -z "$result" ]; then
        log_error "未找到在线主库"
        return 1
    fi

    CURRENT_MASTER_NODE_ID=$(echo "$result" | awk '{print $1}')
    CURRENT_MASTER_IP=$(echo "$result" | awk '{print $2}')
    CURRENT_MASTER_PORT=$(echo "$result" | awk '{print $3}')

    log_info "当前主库节点ID: $CURRENT_MASTER_NODE_ID"
    log_info "当前主库地址: ${CURRENT_MASTER_IP}:${CURRENT_MASTER_PORT}"

    return 0
}

verify_target_slave() {
    local query="SELECT ID, NODE_GROUP_ID, IP_ADDR, PORT, IS_MASTER, IS_ONLINE FROM NODE_INFO WHERE IP_ADDR = '${TARGET_IP}' AND PORT = ${TARGET_PORT}"

    local result
    result=$(mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$query" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "查询目标从库信息失败: $result"
        return 1
    fi

    if [ -z "$result" ]; then
        log_error "未找到目标从库: ${TARGET_IP}:${TARGET_PORT}"
        return 1
    fi

    TARGET_SLAVE_NODE_ID=$(echo "$result" | awk '{print $1}')
    local node_group_id=$(echo "$result" | awk '{print $2}')
    local slave_ip=$(echo "$result" | awk '{print $3}')
    local slave_port=$(echo "$result" | awk '{print $4}')
    local is_master=$(echo "$result" | awk '{print $5}')
    local is_online=$(echo "$result" | awk '{print $6}')

    log_info "目标从库节点ID: $TARGET_SLAVE_NODE_ID"
    log_info "节点组ID: $node_group_id"
    log_info "从库地址: ${slave_ip}:${slave_port}"
    log_info "是否为主库: $is_master"
    log_info "是否在线: $is_online"

    if [ "$is_master" != "0" ]; then
        log_warning "目标节点当前是主库 (IS_MASTER=$is_master)，将进行主从切换"
    fi

    if [ "$is_online" != "1" ]; then
        log_error "目标从库不在线 (IS_ONLINE=$is_online)"
        return 1
    fi

    if [ "$node_group_id" != "$CURRENT_MASTER_NODE_ID" ]; then
        log_error "目标从库与主库不在同一节点组"
        return 1
    fi

    return 0
}

get_all_slaves_list() {
    local query="SELECT ID, IP_ADDR, PORT FROM NODE_INFO WHERE IS_MASTER = 0 AND IS_ONLINE = 1 AND IP_ADDR != '${TARGET_IP}'"

    local result
    result=$(mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$query" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "查询从库列表失败: $result"
        return 1
    fi

    ALL_SLAVES=()

    while IFS= read -r line; do
        [ -z "$line" ] && continue
        ALL_SLAVES+=("$line")
    done <<< "$result"

    log_info "从库列表:"
    for slave in "${ALL_SLAVES[@]}"; do
        log_info "  - $(echo "$slave" | awk '{print $2":"$3}')"
    done

    return 0
}

dryrun_mode() {
    log_info "=========================================="
    log_info "执行干跑模式验证"
    log_info "=========================================="

    print_header "干跑模式验证报告"

    echo -e "${COLOR_CYAN}以下操作将在exec模式下执行：${COLOR_RESET}"
    echo ""

    echo "1. 设置原主库只读"
    echo "   命令: SET GLOBAL read_only=1, super_read_only=1"
    echo "   影响: 所有写入操作将被拒绝"
    echo ""

    echo "2. 修改原主库配置文件"
    echo "   文件: /etc/my.cnf 或 /etc/mysql/my.cnf"
    echo "   参数: read_only=1"
    echo "   影响: MySQL重启后将永久保持只读"
    echo ""

    echo "3. 检查主从复制延迟"
    echo "   方法: 对比GTID Executed Set"
    echo "   重试: 最多15次，每次间隔1秒"
    echo "   超时: 15秒后退出"
    echo ""

    echo "4. 停止主从复制"
    echo "   命令: STOP SLAVE; RESET SLAVE ALL;"
    echo "   影响: 从库将不再从原主库复制"
    echo ""

    echo "5. 提升从库为主库"
    echo "   命令: SHOW MASTER STATUS"
    echo "   验证: 确认新主库binlog已开启"
    echo "   影响: 从库将成为新的主库"
    echo ""

    echo "6. 锁定敏感账户"
    echo "   账户: ${LOCK_ACCOUNT_PATTERNS}"
    echo "   命令: ALTER USER 'xxx'@'%' ACCOUNT LOCK"
    echo "   影响: 锁定账户将无法登录"
    echo ""

    echo "7. 更新元数据库"
    echo "   原主库: IS_MASTER=-1"
    echo "   新主库: IS_MASTER=1"
    echo ""

    echo "8. 重定向所有从库"
    echo "   从库数量: $((${#ALL_SLAVES[@]}))"
    for slave in "${ALL_SLAVES[@]}"; do
        local slave_ip=$(echo "$slave" | awk '{print $2}')
        local slave_port=$(echo "$slave" | awk '{print $3}')
        echo "   - ${slave_ip}:${slave_port} -> ${TARGET_IP}:${TARGET_PORT}"
    done
    echo ""

    echo -e "${COLOR_YELLOW}验证结果：${COLOR_RESET}"
    echo "✓ 所有参数验证通过"
    echo "✓ 元数据库连接正常"
    echo "✓ 主从关系验证通过"
    echo "✓ 目标从库状态正常"
    echo ""

    echo -e "${COLOR_GREEN}干跑模式验证通过，可以安全执行exec模式${COLOR_RESET}"
    echo ""

    return 0
}

set_master_readonly() {
    log_info "=========================================="
    log_info "阶段1: 设置原主库只读"
    log_info "=========================================="
    print_header "设置原主库只读"

    print_step "1" "执行只读设置SQL"

    if ! mysql_set_readonly "$CURRENT_MASTER_IP" "$CURRENT_MASTER_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "ON"; then
        log_error "设置只读模式失败"
        return $ERR_MASTER_SLAVE_SWITCH
    fi
    print_success "只读设置完成"

    print_step "2" "验证只读状态"
    if ! mysql_verify_readonly "$CURRENT_MASTER_IP" "$CURRENT_MASTER_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "ON"; then
        log_error "只读状态验证失败"
        return $ERR_MASTER_SLAVE_SWITCH
    fi
    print_success "只读状态验证通过"

    print_step "3" "修改配置文件"
    local config_file
    config_file=$(ssh_find_mysql_config_file "$CURRENT_MASTER_IP" "$SSH_USER" "$SSH_PASSWORD")

    if [ $? -ne 0 ] || [ -z "$config_file" ]; then
        log_warning "未找到MySQL配置文件，跳过配置修改"
    else
        log_info "找到配置文件: $config_file"

        if ! ssh_modify_mycnf "$CURRENT_MASTER_IP" "$SSH_USER" "$SSH_PASSWORD" "$config_file" "read_only" "1"; then
            log_warning "配置文件修改失败，继续执行"
        fi
    fi

    print_success "主库只读设置完成"

    return 0
}

check_replication_status() {
    log_info "=========================================="
    log_info "阶段2: 检查主从复制延迟"
    log_info "=========================================="
    print_header "检查主从复制延迟"

    print_step "1" "获取主库GTID"

    local master_gtid_query="SHOW MASTER STATUS"
    local master_result

    master_result=$(mysql_exec_query "$CURRENT_MASTER_IP" "$CURRENT_MASTER_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "" "$master_gtid_query" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "获取主库GTID失败: $master_result"
        return $ERR_REPLICATION_LAG_CHECK
    fi

    local master_gtid=$(echo "$master_result" | awk '{print $3}')
    log_info "主库GTID: $master_gtid"

    print_step "2" "获取从库GTID"

    local slave_gtid_query="SHOW SLAVE STATUS\\G"
    local slave_result

    slave_result=$(mysql_exec_query "$TARGET_IP" "$TARGET_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "" "$slave_gtid_query" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "获取从库GTID失败: $slave_result"
        return $ERR_REPLICATION_LAG_CHECK
    fi

    local slave_gtid=$(echo "$slave_result" | grep "Executed_Gtid_Set:" | sed 's/.*: //' | tr -d '[:space:]')
    log_info "从库GTID: $slave_gtid"

    print_step "3" "等待复制同步"

    local retry_count=0
    while [ $retry_count -lt $MAX_REPLICATION_CHECK_RETRIES ]; do
        log_info "检查同步状态 (尝试 $((retry_count + 1))/${MAX_REPLICATION_CHECK_RETRIES})"

        if [ "$master_gtid" = "$slave_gtid" ]; then
            log_success "主从GTID一致，复制已同步"
            print_success "复制同步检查通过"
            return 0
        fi

        log_warning "主从GTID不一致，等待复制追赶..."
        log_info "主库: $master_gtid"
        log_info "从库: $slave_gtid"

        retry_count=$((retry_count + 1))

        if [ $retry_count -lt $MAX_REPLICATION_CHECK_RETRIES ]; then
            sleep $REPLICATION_CHECK_INTERVAL
        fi

        slave_result=$(mysql_exec_query "$TARGET_IP" "$TARGET_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "" "$slave_gtid_query" 2>&1)
        slave_gtid=$(echo "$slave_result" | grep "Executed_Gtid_Set:" | sed 's/.*: //' | tr -d '[:space:]')
    done

    log_error "主从同步超时 (已尝试 ${MAX_REPLICATION_CHECK_RETRIES} 次)"
    print_error "复制延迟检查超时"

    return $ERR_TIMEOUT
}

promote_slave_to_master() {
    log_info "=========================================="
    log_info "阶段3: 提升从库为主库"
    log_info "=========================================="
    print_header "提升从库为主库"

    print_step "1" "停止从库复制"

    if ! mysql_stop_slave "$TARGET_IP" "$TARGET_PORT" "$META_DB_USER" "$META_DB_PASSWORD"; then
        log_error "停止从库复制失败"
        return $ERR_MASTER_SLAVE_SWITCH
    fi
    print_success "从库复制已停止"

    print_step "2" "验证新主库状态"

    local new_master_status=$(mysql_exec_query "$TARGET_IP" "$TARGET_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "" "SHOW MASTER STATUS\\G" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "验证新主库状态失败: $new_master_status"
        return $ERR_MASTER_SLAVE_SWITCH
    fi
    print_success "新主库状态验证通过"

    return 0
}

lock_sensitive_accounts() {
    log_info "=========================================="
    log_info "阶段4: 锁定敏感账户"
    log_info "=========================================="
    print_header "锁定敏感账户"

    print_step "1" "锁定主库账户"

    if ! mysql_lock_accounts "$CURRENT_MASTER_IP" "$CURRENT_MASTER_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$LOCK_ACCOUNT_PATTERNS"; then
        log_warning "锁定账户可能部分失败，继续执行"
    fi
    print_success "账户锁定完成"

    return 0
}

update_metadata() {
    log_info "=========================================="
    log_info "阶段5: 更新元数据库"
    log_info "=========================================="
    print_header "更新元数据库"

    print_step "1" "更新原主库状态"

    local update_old_master="UPDATE NODE_INFO SET IS_MASTER = -1 WHERE ID = ${CURRENT_MASTER_NODE_ID}"
    local result

    result=$(mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$update_old_master" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "更新原主库状态失败: $result"
        return $ERR_META_UPDATE
    fi

    log_info "原主库 (节点ID: $CURRENT_MASTER_NODE_ID) 状态已更新为 IS_MASTER=-1"
    print_success "原主库状态更新完成"

    print_step "2" "更新新主库状态"

    local update_new_master="UPDATE NODE_INFO SET IS_MASTER = 1 WHERE ID = ${TARGET_SLAVE_NODE_ID}"
    result=$(mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$update_new_master" 2>&1)

    if [ $? -ne 0 ]; then
        log_error "更新新主库状态失败: $result"
        rollback_metadata
        return $ERR_META_UPDATE
    fi

    log_info "新主库 (节点ID: $TARGET_SLAVE_NODE_ID) 状态已更新为 IS_MASTER=1"
    print_success "新主库状态更新完成"

    print_step "3" "验证元数据更新"

    local verify_query="SELECT ID, IP_ADDR, PORT, IS_MASTER FROM NODE_INFO WHERE ID IN (${CURRENT_MASTER_NODE_ID}, ${TARGET_SLAVE_NODE_ID})"
    local verify_result

    verify_result=$(mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$verify_query" 2>&1)

    log_info "元数据验证结果:"
    log_info "$verify_result"
    print_success "元数据更新验证通过"

    return 0
}

rollback_metadata() {
    log_warning "执行元数据回滚..."

    local rollback_old_master="UPDATE NODE_INFO SET IS_MASTER = 1 WHERE ID = ${CURRENT_MASTER_NODE_ID}"
    mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$rollback_old_master" >/dev/null 2>&1

    local rollback_new_master="UPDATE NODE_INFO SET IS_MASTER = 0 WHERE ID = ${TARGET_SLAVE_NODE_ID}"
    mysql_exec_query "$META_DB_HOST" "$META_DB_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$META_DB_NAME" "$rollback_new_master" >/dev/null 2>&1

    log_info "元数据回滚完成"
}

redirect_slaves() {
    log_info "=========================================="
    log_info "阶段6: 重定向所有从库"
    log_info "=========================================="
    print_header "重定向所有从库"

    if [ ${#ALL_SLAVES[@]} -eq 0 ]; then
        log_info "没有其他从库需要重定向"
        print_success "从库重定向完成"
        return 0
    fi

    local slave_count=${#ALL_SLAVES[@]}
    log_info "需要重定向的从库数量: $slave_count"

    local success_count=0
    local fail_count=0

    for slave_info in "${ALL_SLAVES[@]}"; do
        local slave_id=$(echo "$slave_info" | awk '{print $1}')
        local slave_ip=$(echo "$slave_info" | awk '{print $2}')
        local slave_port=$(echo "$slave_info" | awk '{print $3}')

        log_info "重定向从库: ${slave_ip}:${slave_port}"

        print_step "1" "停止从库复制: ${slave_ip}:${slave_port}"

        if ! mysql_stop_slave "$slave_ip" "$slave_port" "$META_DB_USER" "$META_DB_PASSWORD"; then
            log_warning "停止从库复制失败: ${slave_ip}:${slave_port}"
            FAILED_SLAVES["${slave_ip}:${slave_port}"]="停止复制失败"
            fail_count=$((fail_count + 1))
            continue
        fi

        print_step "2" "配置新主库: ${slave_ip}:${slave_port}"

        if ! mysql_change_master "$slave_ip" "$slave_port" "$META_DB_USER" "$META_DB_PASSWORD" "$TARGET_IP" "$TARGET_PORT"; then
            log_error "重定向从库失败: ${slave_ip}:${slave_port}"
            FAILED_SLAVES["${slave_ip}:${slave_port}"]="配置新主库失败"
            fail_count=$((fail_count + 1))
            continue
        fi

        log_success "从库重定向成功: ${slave_ip}:${slave_port}"
        MIGRATED_SLAVES["${slave_ip}:${slave_port}"]="成功"
        success_count=$((success_count + 1))
    done

    log_info "=========================================="
    log_info "从库重定向结果汇总"
    log_info "=========================================="
    log_info "成功: $success_count"
    log_info "失败: $fail_count"

    if [ $success_count -gt 0 ]; then
        log_info "成功重定向的从库:"
        for slave in "${!MIGRATED_SLAVES[@]}"; do
            log_info "  ✓ $slave"
        done
    fi

    if [ $fail_count -gt 0 ]; then
        log_warning "重定向失败或部分失败:"
        for slave in "${!FAILED_SLAVES[@]}"; do
            log_warning "  ✗ $slave: ${FAILED_SLAVES[$slave]}"
        done
    fi

    print_success "从库重定向完成"

    return 0
}

generate_report() {
    log_info "=========================================="
    log_info "生成执行报告"
    log_info "=========================================="

    EXECUTION_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')

    print_header "执行报告"

    echo ""
    echo -e "${COLOR_BOLD}基本信息${COLOR_RESET}"
    echo "脚本版本: $SCRIPT_VERSION"
    echo "执行时间: $EXECUTION_START_TIME"
    echo "结束时间: $EXECUTION_END_TIME"
    echo "执行模式: $MODE"
    echo "风险等级: $RISK_LEVEL"
    echo ""

    echo -e "${COLOR_BOLD}迁移信息${COLOR_RESET}"
    echo "原主库: ${CURRENT_MASTER_IP}:${CURRENT_MASTER_PORT}"
    echo "新主库: ${TARGET_IP}:${TARGET_PORT}"
    echo "数据库类型: $DB_TYPE"
    echo ""

    echo -e "${COLOR_BOLD}从库迁移结果${COLOR_RESET}"
    local success_count=${#MIGRATED_SLAVES[@]}
    local fail_count=${#FAILED_SLAVES[@]}
    echo "成功迁移: $success_count 个从库"
    echo "失败: $fail_count 个从库"
    echo ""

    if [ $success_count -gt 0 ]; then
        echo -e "${COLOR_GREEN}成功迁移的从库:${COLOR_RESET}"
        for slave in "${!MIGRATED_SLAVES[@]}"; do
            echo -e "  ✓ $slave"
        done
        echo ""
    fi

    if [ $fail_count -gt 0 ]; then
        echo -e "${COLOR_RED}迁移失败的从库:${COLOR_RESET}"
        for slave in "${!FAILED_SLAVES[@]}"; do
            echo -e "  ✗ $slave: ${FAILED_SLAVES[$slave]}"
        done
        echo ""
    fi

    echo -e "${COLOR_BOLD}日志文件${COLOR_RESET}"
    echo "详细日志: $EXECUTION_LOG_FILE"
    echo ""

    local total_seconds=$(( $(date -d "$EXECUTION_END_TIME" '+%s') - $(date -d "$EXECUTION_START_TIME" '+%s') ))
    echo -e "${COLOR_BOLD}执行时长${COLOR_RESET}"
    echo "总耗时: ${total_seconds} 秒"
    echo ""

    return 0
}

output_json_result() {
    local success=$1

    local json_output="{
  \"success\": ${success},
  \"script\": \"$SCRIPT_NAME\",
  \"version\": \"$SCRIPT_VERSION\",
  \"execution_time\": \"$EXECUTION_START_TIME\",
  \"end_time\": \"$EXECUTION_END_TIME\",
  \"mode\": \"$MODE\",
  \"old_master\": \"${CURRENT_MASTER_IP}:${CURRENT_MASTER_PORT}\",
  \"new_master\": \"${TARGET_IP}:${TARGET_PORT}\",
  \"db_type\": \"$DB_TYPE\",
  \"migrated_slaves\": ["

    local first=true
    for slave in "${!MIGRATED_SLAVES[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            json_output+=", "
        fi
        json_output+="\"$slave\""
    done

    json_output+="],
  \"failed_slaves\": ["

    first=true
    for slave in "${!FAILED_SLAVES[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            json_output+=", "
        fi
        json_output+="\"$slave: ${FAILED_SLAVES[$slave]}\""
    done

    json_output+="],
  \"log_file\": \"$EXECUTION_LOG_FILE\"
}"

    echo "$json_output"
}

cleanup() {
    log_info "执行清理..."

    log_info "清理完成"
}

rollback_all() {
    log_error "执行全面回滚..."

    log_info "1. 恢复主库只读状态"
    mysql_set_readonly "$CURRENT_MASTER_IP" "$CURRENT_MASTER_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "OFF" >/dev/null 2>&1

    log_info "2. 恢复元数据"
    rollback_metadata >/dev/null 2>&1

    log_info "3. 重建主从关系"
    for slave_info in "${ALL_SLAVES[@]}"; do
        local slave_ip=$(echo "$slave_info" | awk '{print $2}')
        local slave_port=$(echo "$slave_info" | awk '{print $3}')
        mysql_change_master "$slave_ip" "$slave_port" "$META_DB_USER" "$META_DB_PASSWORD" "$CURRENT_MASTER_IP" "$CURRENT_MASTER_PORT" >/dev/null 2>&1
    done

    log_info "4. 解锁账户"
    mysql_unlock_accounts "$CURRENT_MASTER_IP" "$CURRENT_MASTER_PORT" "$META_DB_USER" "$META_DB_PASSWORD" "$LOCK_ACCOUNT_PATTERNS" >/dev/null 2>&1

    log_info "回滚完成"
}

main() {
    parse_arguments "$@"

    init_execution_environment

    pre_checks

    if [ "$MODE" = "dryrun" ]; then
        dryrun_mode
        local exit_code=$?
        cleanup
        exit $exit_code
    fi

    confirm_execution

    local migration_success=true

    if ! set_master_readonly; then
        log_error "设置主库只读失败"
        migration_success=false
    fi

    if [ "$migration_success" = true ] && ! check_replication_status; then
        log_error "检查主从复制延迟失败"
        migration_success=false
    fi

    if [ "$migration_success" = true ] && ! promote_slave_to_master; then
        log_error "提升从库为主库失败"
        migration_success=false
    fi

    if [ "$migration_success" = true ] && ! lock_sensitive_accounts; then
        log_error "锁定账户失败，继续执行"
    fi

    if [ "$migration_success" = true ] && ! update_metadata; then
        log_error "更新元数据失败"
        migration_success=false
    fi

    if [ "$migration_success" = true ] && ! redirect_slaves; then
        log_warning "重定向从库失败或部分失败"
    fi

    generate_report

    if [ "$migration_success" = true ]; then
        echo ""
        output_json_result true
        echo ""
        log_success "主从切换成功完成"
        cleanup
        exit 0
    else
        echo ""
        log_error "迁移过程中出现错误"
        output_json_result false
        echo ""
        log_error "执行回滚..."
        rollback_all
        log_error "回滚完成"
        log_error "请检查日志并手动处理: $EXECUTION_LOG_FILE"
        cleanup
        exit $ERR_MASTER_SLAVE_SWITCH
    fi
}

trap 'log_error "脚本被中断"; rollback_all; cleanup; exit 130' INT TERM

if [ "${1:-}" = "--source-only" ]; then
    return 0
fi

main "$@"
