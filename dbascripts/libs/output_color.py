#!/usr/bin/env python3
# -*- coding: utf-8 -*-

COLOR_RESET = "\033[0m"
COLOR_RED = "\033[0;31m"
COLOR_GREEN = "\033[0;32m"
COLOR_YELLOW = "\033[0;33m"
COLOR_BLUE = "\033[0;34m"
COLOR_MAGENTA = "\033[0;35m"
COLOR_CYAN = "\033[0;36m"
COLOR_WHITE = "\033[1;37m"
COLOR_GRAY = "\033[0;90m"

COLOR_BOLD = "\033[1m"
COLOR_DIM = "\033[2m"

def print_color(color, message):
    try:
        print(f"{color}{message}{COLOR_RESET}")
    except UnicodeEncodeError:
        message = message.replace('✓', '[OK]').replace('✗', '[ERROR]').replace('⚠', '[WARN]').replace('ℹ', '[INFO]')
        print(f"{color}{message}{COLOR_RESET}")

def print_red(message):
    print_color(COLOR_RED, message)

def print_green(message):
    print_color(COLOR_GREEN, message)

def print_yellow(message):
    print_color(COLOR_YELLOW, message)

def print_blue(message):
    print_color(COLOR_BLUE, message)

def print_magenta(message):
    print_color(COLOR_MAGENTA, message)

def print_cyan(message):
    print_color(COLOR_CYAN, message)

def print_white(message):
    print_color(COLOR_WHITE, message)

def print_gray(message):
    print_color(COLOR_GRAY, message)

def print_bold(message):
    print(f"{COLOR_BOLD}{message}{COLOR_RESET}")

def print_dim(message):
    print(f"{COLOR_DIM}{message}{COLOR_RESET}")

def print_header(message):
    print_blue("==========================================")
    print_blue(f"  {message}")
    print_blue("==========================================")

def print_step(step, message):
    print_cyan(f"[步骤 {step}] {message}")

def print_success(message):
    print_green(f"✓ {message}")

def print_error(message):
    print_red(f"✗ {message}")

def print_warning(message):
    print_yellow(f"⚠ {message}")

def print_info(message):
    print_white(f"ℹ {message}")
