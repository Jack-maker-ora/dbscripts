#!/bin/bash

COLOR_RESET='\033[0m'
COLOR_RED='\033[0;31m'
COLOR_GREEN='\033[0;32m'
COLOR_YELLOW='\033[0;33m'
COLOR_BLUE='\033[0;34m'
COLOR_MAGENTA='\033[0;35m'
COLOR_CYAN='\033[0;36m'
COLOR_WHITE='\033[1;37m'
COLOR_GRAY='\033[0;90m'

COLOR_BOLD='\033[1m'
COLOR_DIM='\033[2m'

print_color() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${COLOR_RESET}"
}

print_red() {
    print_color "$COLOR_RED" "$1"
}

print_green() {
    print_color "$COLOR_GREEN" "$1"
}

print_yellow() {
    print_color "$COLOR_YELLOW" "$1"
}

print_blue() {
    print_color "$COLOR_BLUE" "$1"
}

print_magenta() {
    print_color "$COLOR_MAGENTA" "$1"
}

print_cyan() {
    print_color "$COLOR_CYAN" "$1"
}

print_white() {
    print_color "$COLOR_WHITE" "$1"
}

print_gray() {
    print_color "$COLOR_GRAY" "$1"
}

print_bold() {
    local message=$1
    echo -e "${COLOR_BOLD}${message}${COLOR_RESET}"
}

print_dim() {
    local message=$1
    echo -e "${COLOR_DIM}${message}${COLOR_RESET}"
}

print_header() {
    local message=$1
    print_blue "=========================================="
    print_blue "  $message"
    print_blue "=========================================="
}

print_step() {
    local step=$1
    local message=$2
    print_cyan "[步骤 ${step}] ${message}"
}

print_success() {
    print_green "✓ $1"
}

print_error() {
    print_red "✗ $1"
}

print_warning() {
    print_yellow "⚠ $1"
}

print_info() {
    print_white "ℹ $1"
}
