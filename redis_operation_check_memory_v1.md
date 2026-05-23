# Redis内存检测脚本 v1.0.0

## 角色与目标
- 角色：Redis运维工程师
- 目标：快速检测Redis实例的内存使用情况，包括已使用内存、内存峰值、内存碎片率等关键指标
- 适用场景：日常Redis巡检、性能排查、容量规划

---

## 脚本元数据

# DBA_SKILLS_SCRIPT_METADATA_V1.0 【大模型识别锚点，绝对不可修改】
script_id: "redis_operation_check_memory_v1_20260523"  # 固定格式：db_type_action_function_version_date
name: "Redis内存检测脚本"
version: "1.0.0"
author: "DBA Team"
created_at: "2026-05-23"
updated_at: "2026-05-23"
description: "检测Redis实例的内存使用情况，包括已使用内存、内存峰值、内存碎片率、内存使用率等关键指标"
database_type: "redis"
database_version: ">=2.8"
os_support: ["CentOS7", "CentOS8", "RHEL8", "Ubuntu20.04", "Ubuntu22.04", "Windows"]
tags: ["operation", "redis", "memory", "check", "monitoring"]
dependencies:
  - name: "redis"
    version: ">=3.0"
    required: true
  - name: "click"
    version: ">=7.0"
    required: true
input_parameters:
  - name: "redisHost"
    type: "string"
    required: true
    description: "Redis主机地址"
    default: "127.0.0.1"
    validation: "^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$|^[a-zA-Z0-9.-]+$"
    env_var: "DBA_SKILLS_REDIS_HOST"
    config_key: "redis.host"
  - name: "redisPort"
    type: "integer"
    required: true
    description: "Redis端口"
    default: 6379
    validation: "^[1-9][0-9]{0,4}$"
    env_var: "DBA_SKILLS_REDIS_PORT"
    config_key: "redis.port"
  - name: "redisPassword"
    type: "string"
    required: false
    description: "Redis密码"
    default: ""
    env_var: "DBA_SKILLS_REDIS_PASSWORD"
    config_key: "redis.password"
  - name: "redisDb"
    type: "integer"
    required: false
    description: "Redis数据库编号"
    default: 0
    validation: "^[0-9]+$"
    env_var: "DBA_SKILLS_REDIS_DB"
    config_key: "redis.db"
output_parameters:
  - name: "success"
    type: "boolean"
    description: "执行是否成功"
  - name: "errorCode"
    type: "integer"
    description: "错误码"
  - name: "errorMessage"
    type: "string"
    description: "错误信息"
  - name: "data"
    type: "object"
    description: "检测结果数据"
  - name: "data.redisVersion"
    type: "string"
    description: "Redis版本"
  - name: "data.uptimeInDays"
    type: "integer"
    description: "运行天数"
  - name: "data.connectedClients"
    type: "integer"
    description: "连接客户端数"
  - name: "data.memory"
    type: "object"
    description: "内存信息"
error_codes:
  - code: 0
    description: "执行成功"
  - code: 100
    description: "参数验证失败"
  - code: 101
    description: "依赖检查失败"
  - code: 102
    description: "Redis连接失败"
  - code: 103
    description: "获取Redis信息失败"
execution_control:
  risk_level: "low"
  timeout_seconds: 30
  retry_count: 0
  retry_interval_seconds: 0
  allow_parallel: true
  require_confirmation: false
---
---

## 执行工作流
1. 初始化日志系统
2. 合并命令行、环境变量和配置文件参数
3. 执行前置检查（依赖检查）
4. 连接Redis实例
5. 获取Redis INFO信息
6. 分析内存使用情况
7. 输出检测结果（人类可读格式 + JSON格式）

## 异常处理流程
| 错误码 | 错误描述 | 处理方式 |
|--------|----------|----------|
| 101 | 依赖检查失败 | 提示用户安装缺失的Python库 |
| 102 | Redis连接失败 | 记录错误信息并退出 |
| 103 | 获取Redis信息失败 | 记录错误信息并退出 |

## Agent调用示例
```bash
# 基本调用（使用默认参数连接本地Redis）
python redis_operation_check_memory_v1.py

# 指定Redis主机和端口
python redis_operation_check_memory_v1.py --redis-host=192.168.1.100 --redis-port=6380

# 使用密码连接
python redis_operation_check_memory_v1.py --redis-host=192.168.1.100 --redis-password=yourpassword

# 使用环境变量
export DBA_SKILLS_REDIS_HOST=192.168.1.100
export DBA_SKILLS_REDIS_PORT=6380
export DBA_SKILLS_REDIS_PASSWORD=yourpassword
python redis_operation_check_memory_v1.py

# Dry-run模式
python redis_operation_check_memory_v1.py --dry-run

# 查看帮助
python redis_operation_check_memory_v1.py --help

# 查看版本
python redis_operation_check_memory_v1.py --version
```

## 依赖安装
```bash
pip install redis click
```

## 输出说明
脚本会输出两种格式的结果：
1. 人类可读的彩色格式，方便直接查看
2. 标准JSON格式，方便程序解析

## 内存指标说明
- **used_memory**: Redis分配器分配的内存总量（字节）
- **used_memory_rss**: Redis进程在操作系统中占用的物理内存（字节）
- **used_memory_peak**: 内存使用峰值（字节）
- **used_memory_lua**: Lua引擎使用的内存（字节）
- **maxmemory**: Redis配置的最大内存限制（字节）
- **mem_fragmentation_ratio**: 内存碎片率（used_memory_rss / used_memory）
- **memory_usage_percent**: 内存使用率（仅在配置了maxmemory时有效）
