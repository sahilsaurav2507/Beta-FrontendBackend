#!/bin/bash

# =============================================================================
# Lawvriksh Deployment Testing Script
# =============================================================================
# This script tests all components of the Lawvriksh deployment:
# - MySQL on port 3307
# - Backend API on port 8001
# - Frontend served by Nginx
# - SSL certificates
# - Domain accessibility
# =============================================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
DOMAIN="lawvriksh.com"
MYSQL_PORT="3307"
BACKEND_PORT="8001"
PROJECT_DIR="/opt/lawvriksh"

# Test results
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

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

test_header() {
    echo -e "${CYAN}[TEST] $1${NC}"
}

# Test result functions
test_pass() {
    ((TESTS_PASSED++))
    success "✓ $1"
}

test_fail() {
    ((TESTS_FAILED++))
    FAILED_TESTS+=("$1")
    error "✗ $1"
}

# Test MySQL connectivity
test_mysql() {
    test_header "Testing MySQL connectivity on port ${MYSQL_PORT}..."
    
    if command -v mysql >/dev/null 2>&1; then
        if mysql -h 127.0.0.1 -P ${MYSQL_PORT} -u root -p${MYSQL_ROOT_PASSWORD} -e "SELECT 1;" >/dev/null 2>&1; then
            test_pass "MySQL is accessible on port ${MYSQL_PORT}"
        else
            test_fail "MySQL connection failed on port ${MYSQL_PORT}"
        fi
    else
        if nc -z 127.0.0.1 ${MYSQL_PORT} >/dev/null 2>&1; then
            test_pass "MySQL port ${MYSQL_PORT} is open"
        else
            test_fail "MySQL port ${MYSQL_PORT} is not accessible"
        fi
    fi
}

# Test backend API
test_backend() {
    test_header "Testing backend API on port ${BACKEND_PORT}..."
    
    # Test health endpoint
    if curl -f -s http://127.0.0.1:${BACKEND_PORT}/health >/dev/null 2>&1; then
        test_pass "Backend health endpoint responding on port ${BACKEND_PORT}"
    else
        test_fail "Backend health endpoint not responding on port ${BACKEND_PORT}"
    fi
    
    # Test API documentation
    if curl -f -s http://127.0.0.1:${BACKEND_PORT}/docs >/dev/null 2>&1; then
        test_pass "Backend API documentation accessible"
    else
        test_fail "Backend API documentation not accessible"
    fi
}

# Test Docker containers
test_docker_containers() {
    test_header "Testing Docker containers..."
    
    # Check if containers are running
    containers=("lawvriksh-mysql" "lawvriksh-backend" "lawvriksh-rabbitmq" "lawvriksh-redis" "lawvriksh-celery-worker" "lawvriksh-celery-beat")
    
    for container in "${containers[@]}"; do
        if docker ps --format "table {{.Names}}" | grep -q "^${container}$"; then
            test_pass "Container ${container} is running"
        else
            test_fail "Container ${container} is not running"
        fi
    done
    
    # Check container health
    for container in "${containers[@]}"; do
        if docker ps --format "table {{.Names}}\t{{.Status}}" | grep "^${container}" | grep -q "healthy\|Up"; then
            test_pass "Container ${container} is healthy"
        else
            test_fail "Container ${container} is not healthy"
        fi
    done
}

# Test Nginx configuration
test_nginx() {
    test_header "Testing Nginx configuration..."
    
    # Test Nginx syntax
    if sudo nginx -t >/dev/null 2>&1; then
        test_pass "Nginx configuration syntax is valid"
    else
        test_fail "Nginx configuration has syntax errors"
    fi
    
    # Test if Nginx is running
    if systemctl is-active --quiet nginx; then
        test_pass "Nginx service is running"
    else
        test_fail "Nginx service is not running"
    fi
    
    # Test if site configuration exists
    if [ -f "/etc/nginx/sites-available/${DOMAIN}" ]; then
        test_pass "Nginx site configuration exists"
    else
        test_fail "Nginx site configuration not found"
    fi
    
    # Test if site is enabled
    if [ -L "/etc/nginx/sites-enabled/${DOMAIN}" ]; then
        test_pass "Nginx site is enabled"
    else
        test_fail "Nginx site is not enabled"
    fi
}

# Test SSL certificates
test_ssl() {
    test_header "Testing SSL certificates..."
    
    # Check if certificates exist
    if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        test_pass "SSL certificate exists"
        
        # Check certificate validity
        if openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -checkend 86400 >/dev/null 2>&1; then
            test_pass "SSL certificate is valid and not expiring soon"
        else
            test_fail "SSL certificate is invalid or expiring soon"
        fi
    else
        test_fail "SSL certificate not found"
    fi
}

# Test frontend files
test_frontend() {
    test_header "Testing frontend deployment..."
    
    # Check if frontend files exist
    if [ -d "/var/www/${DOMAIN}" ]; then
        test_pass "Frontend directory exists"
        
        # Check if index.html exists
        if [ -f "/var/www/${DOMAIN}/index.html" ]; then
            test_pass "Frontend index.html exists"
        else
            test_fail "Frontend index.html not found"
        fi
        
        # Check file permissions
        if [ -r "/var/www/${DOMAIN}/index.html" ]; then
            test_pass "Frontend files are readable"
        else
            test_fail "Frontend files are not readable"
        fi
    else
        test_fail "Frontend directory not found"
    fi
}

# Test domain accessibility
test_domain_access() {
    test_header "Testing domain accessibility..."
    
    # Test HTTP redirect to HTTPS
    if curl -s -o /dev/null -w "%{http_code}" "http://${DOMAIN}" | grep -q "301\|302"; then
        test_pass "HTTP to HTTPS redirect working"
    else
        test_fail "HTTP to HTTPS redirect not working"
    fi
    
    # Test HTTPS frontend
    if curl -f -s "https://${DOMAIN}" >/dev/null 2>&1; then
        test_pass "HTTPS frontend accessible"
    else
        test_fail "HTTPS frontend not accessible"
    fi
    
    # Test HTTPS API
    if curl -f -s "https://${DOMAIN}/api/health" >/dev/null 2>&1; then
        test_pass "HTTPS API accessible"
    else
        test_fail "HTTPS API not accessible"
    fi
}

# Test database connectivity from backend
test_database_integration() {
    test_header "Testing database integration..."
    
    # Test if backend can connect to database
    if curl -f -s "http://127.0.0.1:${BACKEND_PORT}/health" | grep -q "database.*ok\|healthy\|success"; then
        test_pass "Backend database integration working"
    else
        test_fail "Backend database integration not working"
    fi
}

# Test email configuration
test_email_config() {
    test_header "Testing email configuration..."
    
    # Check if environment variables are set
    if [ -f "${PROJECT_DIR}/.env.production" ]; then
        if grep -q "SMTP_HOST" "${PROJECT_DIR}/.env.production" && grep -q "SMTP_USER" "${PROJECT_DIR}/.env.production"; then
            test_pass "Email configuration variables present"
        else
            test_fail "Email configuration variables missing"
        fi
    else
        test_fail "Environment file not found"
    fi
}

# Test log files
test_logs() {
    test_header "Testing log files..."
    
    log_dirs=("${PROJECT_DIR}/logs/nginx" "${PROJECT_DIR}/logs/backend" "${PROJECT_DIR}/logs/mysql")
    
    for log_dir in "${log_dirs[@]}"; do
        if [ -d "$log_dir" ]; then
            test_pass "Log directory exists: $log_dir"
        else
            test_fail "Log directory missing: $log_dir"
        fi
    done
}

# Test backup functionality
test_backup() {
    test_header "Testing backup functionality..."
    
    if [ -f "${PROJECT_DIR}/backup.sh" ]; then
        test_pass "Backup script exists"
        
        if [ -x "${PROJECT_DIR}/backup.sh" ]; then
            test_pass "Backup script is executable"
        else
            test_fail "Backup script is not executable"
        fi
    else
        test_fail "Backup script not found"
    fi
    
    if [ -d "${PROJECT_DIR}/backups" ]; then
        test_pass "Backup directory exists"
    else
        test_fail "Backup directory not found"
    fi
}

# Performance test
test_performance() {
    test_header "Testing performance..."
    
    # Test frontend response time
    frontend_time=$(curl -o /dev/null -s -w "%{time_total}" "https://${DOMAIN}" 2>/dev/null || echo "999")
    if (( $(echo "$frontend_time < 3.0" | bc -l) )); then
        test_pass "Frontend response time acceptable (${frontend_time}s)"
    else
        test_fail "Frontend response time too slow (${frontend_time}s)"
    fi
    
    # Test API response time
    api_time=$(curl -o /dev/null -s -w "%{time_total}" "https://${DOMAIN}/api/health" 2>/dev/null || echo "999")
    if (( $(echo "$api_time < 2.0" | bc -l) )); then
        test_pass "API response time acceptable (${api_time}s)"
    else
        test_fail "API response time too slow (${api_time}s)"
    fi
}

# Security test
test_security() {
    test_header "Testing security headers..."
    
    # Test security headers
    headers=$(curl -s -I "https://${DOMAIN}" 2>/dev/null || echo "")
    
    if echo "$headers" | grep -q "Strict-Transport-Security"; then
        test_pass "HSTS header present"
    else
        test_fail "HSTS header missing"
    fi
    
    if echo "$headers" | grep -q "X-Frame-Options"; then
        test_pass "X-Frame-Options header present"
    else
        test_fail "X-Frame-Options header missing"
    fi
    
    if echo "$headers" | grep -q "X-Content-Type-Options"; then
        test_pass "X-Content-Type-Options header present"
    else
        test_fail "X-Content-Type-Options header missing"
    fi
}

# Main test function
run_all_tests() {
    log "=============================================================="
    log "Starting Lawvriksh Deployment Tests"
    log "=============================================================="
    log "Domain: ${DOMAIN}"
    log "MySQL Port: ${MYSQL_PORT}"
    log "Backend Port: ${BACKEND_PORT}"
    log "=============================================================="
    
    # Load environment if available
    if [ -f "${PROJECT_DIR}/.env.production" ]; then
        set -a
        source "${PROJECT_DIR}/.env.production"
        set +a
    fi
    
    # Run all tests
    test_docker_containers
    test_mysql
    test_backend
    test_nginx
    test_ssl
    test_frontend
    test_domain_access
    test_database_integration
    test_email_config
    test_logs
    test_backup
    test_performance
    test_security
    
    # Display results
    log "=============================================================="
    log "Test Results Summary"
    log "=============================================================="
    success "Tests Passed: ${TESTS_PASSED}"
    if [ ${TESTS_FAILED} -gt 0 ]; then
        error "Tests Failed: ${TESTS_FAILED}"
        echo
        error "Failed Tests:"
        for failed_test in "${FAILED_TESTS[@]}"; do
            echo "  - $failed_test"
        done
    else
        success "All tests passed!"
    fi
    log "=============================================================="
    
    # Exit with appropriate code
    if [ ${TESTS_FAILED} -gt 0 ]; then
        exit 1
    else
        exit 0
    fi
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Lawvriksh Deployment Testing Script"
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  --help, -h        Show this help message"
        echo "  --mysql           Test MySQL only"
        echo "  --backend         Test backend only"
        echo "  --frontend        Test frontend only"
        echo "  --nginx           Test Nginx only"
        echo "  --ssl             Test SSL only"
        echo "  --domain          Test domain access only"
        echo "  --performance     Test performance only"
        echo "  --security        Test security only"
        exit 0
        ;;
    --mysql)
        test_mysql
        ;;
    --backend)
        test_backend
        ;;
    --frontend)
        test_frontend
        ;;
    --nginx)
        test_nginx
        ;;
    --ssl)
        test_ssl
        ;;
    --domain)
        test_domain_access
        ;;
    --performance)
        test_performance
        ;;
    --security)
        test_security
        ;;
    *)
        run_all_tests
        ;;
esac
