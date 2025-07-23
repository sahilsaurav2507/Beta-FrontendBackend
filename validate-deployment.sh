#!/bin/bash

# =============================================================================
# Lawvriksh Deployment Validation Script
# =============================================================================
# This script validates that all components are properly installed and configured
# before running the main deployment script.
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Configuration
DOMAIN="lawvriksh.com"
MYSQL_PORT="3307"
BACKEND_PORT="8001"
PROJECT_DIR="/opt/lawvriksh"

# Validation results
VALIDATIONS_PASSED=0
VALIDATIONS_FAILED=0
FAILED_VALIDATIONS=()

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

info() {
    echo -e "${BLUE}[INFO] $1${NC}"
}

success() {
    echo -e "${PURPLE}[SUCCESS] $1${NC}"
}

# Validation result functions
validate_pass() {
    ((VALIDATIONS_PASSED++))
    success "✓ $1"
}

validate_fail() {
    ((VALIDATIONS_FAILED++))
    FAILED_VALIDATIONS+=("$1")
    error "✗ $1"
}

# Check if running as root
check_user() {
    info "Checking user permissions..."
    
    if [[ $EUID -eq 0 ]]; then
        validate_fail "Script is running as root (should run as regular user with sudo)"
    else
        validate_pass "Running as non-root user"
    fi
    
    # Check sudo access
    if sudo -n true 2>/dev/null; then
        validate_pass "User has sudo privileges"
    else
        validate_fail "User does not have sudo privileges"
    fi
}

# Check Ubuntu version
check_ubuntu_version() {
    info "Checking Ubuntu version..."
    
    if [ -f /etc/os-release ]; then
        local version=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
        if [[ "$version" == "24.04" ]]; then
            validate_pass "Ubuntu 24.04 detected"
        else
            validate_fail "Ubuntu version is $version (expected 24.04)"
        fi
    else
        validate_fail "Cannot determine Ubuntu version"
    fi
}

# Check system resources
check_system_resources() {
    info "Checking system resources..."
    
    # Check disk space (need at least 10GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space=10485760  # 10GB in KB
    
    if [ "$available_space" -gt "$required_space" ]; then
        validate_pass "Sufficient disk space available ($(($available_space/1024/1024))GB)"
    else
        validate_fail "Insufficient disk space (need 10GB+, available: $(($available_space/1024/1024))GB)"
    fi
    
    # Check memory (need at least 2GB)
    local available_memory=$(free -k | awk 'NR==2{print $2}')
    local required_memory=2097152  # 2GB in KB
    
    if [ "$available_memory" -gt "$required_memory" ]; then
        validate_pass "Sufficient memory available ($(($available_memory/1024/1024))GB)"
    else
        validate_fail "Insufficient memory (need 2GB+, available: $(($available_memory/1024/1024))GB)"
    fi
}

# Check network connectivity
check_network() {
    info "Checking network connectivity..."
    
    # Check internet connectivity
    if curl -s --connect-timeout 5 https://google.com >/dev/null; then
        validate_pass "Internet connectivity available"
    else
        validate_fail "No internet connectivity"
    fi
    
    # Check domain resolution
    if dig +short "$DOMAIN" >/dev/null 2>&1; then
        local domain_ip=$(dig +short "$DOMAIN" | tail -n1)
        local server_ip=$(curl -s --connect-timeout 5 ifconfig.me || echo "unknown")
        
        if [ "$server_ip" != "unknown" ] && [ "$domain_ip" = "$server_ip" ]; then
            validate_pass "Domain $DOMAIN resolves to this server"
        else
            validate_fail "Domain $DOMAIN does not resolve to this server ($domain_ip vs $server_ip)"
        fi
    else
        validate_fail "Cannot resolve domain $DOMAIN"
    fi
}

# Check required ports
check_ports() {
    info "Checking port availability..."
    
    local ports=("80" "443" "$MYSQL_PORT" "$BACKEND_PORT")
    
    for port in "${ports[@]}"; do
        if ! nc -z localhost "$port" 2>/dev/null; then
            validate_pass "Port $port is available"
        else
            validate_fail "Port $port is already in use"
        fi
    done
}

# Check required files
check_required_files() {
    info "Checking required deployment files..."
    
    local required_files=(
        "deploy-ubuntu-complete.sh"
        "docker-compose.custom-ports.yml"
        "nginx-lawvriksh.conf"
        ".env.production.template"
        "Dockerfile.production"
        "requirements.production.txt"
    )
    
    for file in "${required_files[@]}"; do
        if [ -f "$file" ]; then
            validate_pass "Required file exists: $file"
        else
            validate_fail "Missing required file: $file"
        fi
    done
}

# Check application structure
check_application_structure() {
    info "Checking application structure..."
    
    # Check backend structure
    if [ -d "app" ]; then
        validate_pass "Backend app directory exists"
        
        local required_dirs=("app/api" "app/core" "app/models" "app/schemas" "app/services")
        for dir in "${required_dirs[@]}"; do
            if [ -d "$dir" ]; then
                validate_pass "Directory exists: $dir"
            else
                validate_fail "Missing directory: $dir"
            fi
        done
        
        # Check main.py
        if [ -f "app/main.py" ]; then
            validate_pass "Main application file exists"
        else
            validate_fail "Missing app/main.py"
        fi
    else
        validate_fail "Backend app directory not found"
    fi
    
    # Check frontend structure
    if [ -d "Frontend" ]; then
        validate_pass "Frontend directory exists"
        
        if [ -f "Frontend/package.json" ]; then
            validate_pass "Frontend package.json exists"
        else
            validate_fail "Missing Frontend/package.json"
        fi
    else
        validate_fail "Frontend directory not found"
    fi
}

# Check dependencies
check_dependencies() {
    info "Checking system dependencies..."
    
    # Check if curl is available
    if command -v curl >/dev/null; then
        validate_pass "curl is available"
    else
        validate_fail "curl is not installed"
    fi
    
    # Check if git is available
    if command -v git >/dev/null; then
        validate_pass "git is available"
    else
        validate_fail "git is not installed"
    fi
    
    # Check if openssl is available
    if command -v openssl >/dev/null; then
        validate_pass "openssl is available"
    else
        validate_fail "openssl is not installed"
    fi
    
    # Check if nc (netcat) is available
    if command -v nc >/dev/null; then
        validate_pass "netcat is available"
    else
        validate_fail "netcat is not installed"
    fi
}

# Main validation function
run_validations() {
    log "=============================================================="
    log "Lawvriksh Deployment Validation"
    log "=============================================================="
    log "Domain: $DOMAIN"
    log "MySQL Port: $MYSQL_PORT"
    log "Backend Port: $BACKEND_PORT"
    log "=============================================================="
    
    # Run all validations
    check_user
    check_ubuntu_version
    check_system_resources
    check_network
    check_ports
    check_required_files
    check_application_structure
    check_dependencies
    
    # Display results
    log "=============================================================="
    log "Validation Results"
    log "=============================================================="
    success "Validations Passed: $VALIDATIONS_PASSED"
    
    if [ $VALIDATIONS_FAILED -gt 0 ]; then
        error "Validations Failed: $VALIDATIONS_FAILED"
        echo
        error "Failed Validations:"
        for failed_validation in "${FAILED_VALIDATIONS[@]}"; do
            echo "  - $failed_validation"
        done
        echo
        error "Please fix the above issues before running the deployment script."
        log "=============================================================="
        exit 1
    else
        success "All validations passed!"
        echo
        success "Your system is ready for Lawvriksh deployment."
        success "You can now run: ./deploy-ubuntu-complete.sh"
        log "=============================================================="
        exit 0
    fi
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Lawvriksh Deployment Validation Script"
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  --help, -h    Show this help message"
        exit 0
        ;;
    *)
        run_validations
        ;;
esac
