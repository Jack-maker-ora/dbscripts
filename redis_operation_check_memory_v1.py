#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import json
import os
import sys
from typing import Dict, Any

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'dbascripts'))

try:
    import click
except ImportError:
    print("错误: 需要安装click库，请运行: pip install click")
    sys.exit(1)

from const.error_code import (  # noqa: E402
    ERR_SUCCESS,
    ERR_DEPENDENCY_CHECK,
    ERR_REDIS_CONNECTION,
    ERR_REDIS_INFO,
    get_error_message
)
from libs.logger import init_logger, log_info, log_error  # noqa: E402

SCRIPT_VERSION = "1.0.0"
SCRIPT_NAME = "Redis内存检测脚本"


def safe_print(message):
    try:
        print(message)
    except UnicodeEncodeError:
        safe_chars = []
        for c in message:
            if ord(c) < 128:
                safe_chars.append(c)
            else:
                safe_chars.append('?')
        print(''.join(safe_chars))


def bytes_to_human(n: int) -> str:
    symbols = ('KB', 'MB', 'GB', 'TB')
    prefix = {}
    for i, s in enumerate(symbols):
        prefix[s] = 1 << (i + 1) * 10
    for s in reversed(symbols):
        if n >= prefix[s]:
            value = float(n) / prefix[s]
            return '%.2f %s' % (value, s)
    return "%s B" % n


def get_redis_connection(
    redis_host: str,
    redis_port: int,
    redis_password: str = None,
    redis_db: int = 0
):
    try:
        import redis
    except ImportError:
        log_error("redis库未安装")
        return None

    try:
        if redis_password:
            r = redis.Redis(
                host=redis_host,
                port=redis_port,
                password=redis_password,
                db=redis_db,
                decode_responses=True,
                socket_timeout=5
            )
        else:
            r = redis.Redis(
                host=redis_host,
                port=redis_port,
                db=redis_db,
                decode_responses=True,
                socket_timeout=5
            )
        r.ping()
        return r
    except Exception as e:
        log_error(f"Redis连接失败: {str(e)}")
        return None


def get_redis_info(redis_conn) -> Dict[str, Any]:
    try:
        info = redis_conn.info()
        return info
    except Exception as e:
        log_error(f"获取Redis信息失败: {str(e)}")
        return {}


def check_redis_memory(info: Dict[str, Any]) -> Dict[str, Any]:
    memory_info = {
        "used_memory": info.get("used_memory", 0),
        "used_memory_human": info.get("used_memory_human", "0B"),
        "used_memory_rss": info.get("used_memory_rss", 0),
        "used_memory_rss_human": info.get("used_memory_rss_human", "0B"),
        "used_memory_peak": info.get("used_memory_peak", 0),
        "used_memory_peak_human": info.get("used_memory_peak_human", "0B"),
        "used_memory_lua": info.get("used_memory_lua", 0),
        "used_memory_lua_human": info.get("used_memory_lua_human", "0B"),
        "maxmemory": info.get("maxmemory", 0),
        "maxmemory_human": info.get("maxmemory_human", "0B"),
        "mem_fragmentation_ratio": info.get("mem_fragmentation_ratio", 0.0),
        "mem_allocator": info.get("mem_allocator", "")
    }

    if memory_info["maxmemory"] > 0:
        memory_info["memory_usage_percent"] = (
            memory_info["used_memory"] / memory_info["maxmemory"]
        ) * 100
    else:
        memory_info["memory_usage_percent"] = 0.0

    return memory_info


def pre_checks(redis_host: str, redis_port: int):
    log_info("开始前置检查")

    safe_print("[INFO] 检查Python依赖库")
    try:
        import redis  # noqa: F401
        safe_print("[OK] redis库已安装")
    except ImportError:
        safe_print(
            "[ERROR] redis库未安装，请运行: pip install redis"
        )
        return ERR_DEPENDENCY_CHECK

    safe_print(f"[INFO] 检查Redis连接: {redis_host}:{redis_port}")

    safe_print("[OK] 前置检查完成")
    return ERR_SUCCESS


def redis_operation_check_memory_v1(
    redis_host: str,
    redis_port: int,
    redis_password: str,
    redis_db: int,
    dry_run: bool
):
    safe_print("=" * 50)
    safe_print(f"  {SCRIPT_NAME} v{SCRIPT_VERSION}")
    safe_print("=" * 50)

    result = {
        "success": False,
        "error_code": ERR_SUCCESS,
        "error_message": "",
        "data": {}
    }

    try:
        log_info("初始化日志系统")
        init_logger()

        if dry_run:
            log_info("Dry-run模式，不会实际执行检测")
            result["success"] = True
            result["data"] = {
                "message": "Dry-run模式执行完成"
            }
            safe_print("[OK] Dry-run模式执行完成")
            return result

        error_code = pre_checks(redis_host, redis_port)
        if error_code != ERR_SUCCESS:
            result["error_code"] = error_code
            result["error_message"] = get_error_message(error_code)
            return result

        log_info(f"连接Redis: {redis_host}:{redis_port}")
        redis_conn = get_redis_connection(
            redis_host,
            redis_port,
            redis_password,
            redis_db
        )
        if not redis_conn:
            result["error_code"] = ERR_REDIS_CONNECTION
            result["error_message"] = get_error_message(ERR_REDIS_CONNECTION)
            return result

        log_info("获取Redis信息")
        info = get_redis_info(redis_conn)
        if not info:
            result["error_code"] = ERR_REDIS_INFO
            result["error_message"] = get_error_message(ERR_REDIS_INFO)
            return result

        log_info("分析内存使用情况")
        memory_info = check_redis_memory(info)

        result["success"] = True
        result["data"] = {
            "redis_version": info.get("redis_version", ""),
            "uptime_in_seconds": info.get("uptime_in_seconds", 0),
            "uptime_in_days": info.get("uptime_in_days", 0),
            "connected_clients": info.get("connected_clients", 0),
            "blocked_clients": info.get("blocked_clients", 0),
            "memory": memory_info
        }

        safe_print("[OK] Redis内存检测完成")

        safe_print("\n=== 内存使用详情 ===")
        safe_print(f"Redis版本: {info.get('redis_version', '')}")
        safe_print(f"运行时间: {info.get('uptime_in_days', 0)}天")
        safe_print(f"连接客户端数: {info.get('connected_clients', 0)}")
        safe_print(f"已使用内存: {memory_info['used_memory_human']}")
        safe_print(f"RSS内存: {memory_info['used_memory_rss_human']}")
        safe_print(f"内存峰值: {memory_info['used_memory_peak_human']}")
        safe_print(f"最大内存限制: {memory_info['maxmemory_human']}")
        if memory_info['maxmemory'] > 0:
            usage_percent = memory_info['memory_usage_percent']
            if usage_percent > 80:
                safe_print(
                    f"[WARN] 内存使用率: {usage_percent:.2f}%"
                )
            else:
                safe_print(
                    f"[INFO] 内存使用率: {usage_percent:.2f}%"
                )
        safe_print(
            f"内存碎片率: {memory_info['mem_fragmentation_ratio']}"
        )
        safe_print(
            f"内存分配器: {memory_info['mem_allocator']}"
        )

        return result

    except Exception as e:
        log_error(f"执行过程出错: {str(e)}")
        result["error_code"] = ERR_SUCCESS
        result["error_message"] = str(e)
        return result


@click.command()
@click.option(
    '--redis-host',
    default='127.0.0.1',
    help='Redis主机地址',
    envvar='DBA_SKILLS_REDIS_HOST'
)
@click.option(
    '--redis-port',
    default=6379,
    type=int,
    help='Redis端口',
    envvar='DBA_SKILLS_REDIS_PORT'
)
@click.option(
    '--redis-password',
    default='',
    help='Redis密码',
    envvar='DBA_SKILLS_REDIS_PASSWORD'
)
@click.option(
    '--redis-db',
    default=0,
    type=int,
    help='Redis数据库编号',
    envvar='DBA_SKILLS_REDIS_DB'
)
@click.option(
    '--dry-run',
    is_flag=True,
    help='Dry-run模式，不实际执行'
)
@click.version_option(
    version=SCRIPT_VERSION,
    prog_name=SCRIPT_NAME
)
def main(redis_host, redis_port, redis_password, redis_db, dry_run):
    result = redis_operation_check_memory_v1(
        redis_host,
        redis_port,
        redis_password,
        redis_db,
        dry_run
    )

    safe_print("\n" + "="*50)
    safe_print("JSON格式输出:")
    safe_print(json.dumps(result, ensure_ascii=False, indent=2))
    safe_print("="*50)

    if result["success"]:
        sys.exit(0)
    else:
        sys.exit(result.get("error_code", 1))


if __name__ == "__main__":
    main()
