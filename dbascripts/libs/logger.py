#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import logging
import sys
from datetime import datetime

LOG_LEVEL_DEBUG = 0
LOG_LEVEL_INFO = 1
LOG_LEVEL_WARNING = 2
LOG_LEVEL_ERROR = 3
LOG_LEVEL_SUCCESS = 4

LOG_LEVEL_NAMES = {
    LOG_LEVEL_DEBUG: "DEBUG",
    LOG_LEVEL_INFO: "INFO",
    LOG_LEVEL_WARNING: "WARNING",
    LOG_LEVEL_ERROR: "ERROR",
    LOG_LEVEL_SUCCESS: "SUCCESS"
}

class Logger:
    def __init__(self, log_level="INFO", log_file=None):
        self.log_level = log_level
        self.log_file = log_file
        self.logger = logging.getLogger("dbascripts")
        self.logger.setLevel(logging.DEBUG)
        
        formatter = logging.Formatter('%(asctime)s [%(levelname)s] %(message)s', datefmt='%Y-%m-%d %H:%M:%S')
        
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setLevel(self._get_logging_level(log_level))
        console_handler.setFormatter(formatter)
        self.logger.addHandler(console_handler)
        
        if log_file:
            file_handler = logging.FileHandler(log_file, encoding='utf-8')
            file_handler.setLevel(logging.DEBUG)
            file_handler.setFormatter(formatter)
            self.logger.addHandler(file_handler)
    
    def _get_logging_level(self, level_str):
        level_map = {
            "DEBUG": logging.DEBUG,
            "INFO": logging.INFO,
            "WARNING": logging.WARNING,
            "ERROR": logging.ERROR
        }
        return level_map.get(level_str, logging.INFO)
    
    def debug(self, message):
        self.logger.debug(message)
    
    def info(self, message):
        self.logger.info(message)
    
    def warning(self, message):
        self.logger.warning(message)
    
    def error(self, message):
        self.logger.error(message)
    
    def success(self, message):
        self.logger.info(f"SUCCESS: {message}")

_logger_instance = None

def init_logger(log_level="INFO", log_file=None):
    global _logger_instance
    if _logger_instance is None:
        _logger_instance = Logger(log_level, log_file)
    return _logger_instance

def get_logger():
    if _logger_instance is None:
        return init_logger()
    return _logger_instance

def log_debug(message):
    get_logger().debug(message)

def log_info(message):
    get_logger().info(message)

def log_warning(message):
    get_logger().warning(message)

def log_error(message):
    get_logger().error(message)

def log_success(message):
    get_logger().success(message)
