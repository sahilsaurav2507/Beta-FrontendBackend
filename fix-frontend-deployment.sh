#!/bin/bash

# =============================================================================
# Frontend Deployment Fix Script
# =============================================================================
# This script fixes the frontend deployment issue by properly copying
# and building the frontend application.
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
PROJECT_DIR="/opt/lawvriksh"
DOMAIN="lawvriksh.com"

# Logging functions
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
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

# Check if running as the correct user
check_user() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Please run as a regular user with sudo privileges."
    fi
}

# Fix frontend directory
fix_frontend_directory() {
    log "Fixing frontend directory structure..."
    
    # Create frontend directory if it doesn't exist
    mkdir -p ${PROJECT_DIR}/frontend
    
    # Find and copy Frontend directory
    if [ -d "Frontend" ]; then
        info "Found Frontend directory in current location"
        cp -r Frontend/* ${PROJECT_DIR}/frontend/
    elif [ -d "../Frontend" ]; then
        info "Found Frontend directory in parent location"
        cp -r ../Frontend/* ${PROJECT_DIR}/frontend/
    else
        error "Frontend directory not found. Please ensure you're running this from the correct directory."
    fi
    
    # Verify package.json exists
    if [ -f "${PROJECT_DIR}/frontend/package.json" ]; then
        success "Frontend files copied successfully"
    else
        error "package.json still not found after copying"
    fi
    
    # Set proper permissions
    chown -R $USER:$USER ${PROJECT_DIR}/frontend
}

# Build frontend
build_frontend() {
    log "Building frontend application..."
    
    cd ${PROJECT_DIR}/frontend
    
    # Check if already built
    if [ -d "dist" ] && [ -f "dist/index.html" ]; then
        info "Frontend appears to be pre-built"
        read -p "Do you want to rebuild it? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Using existing build"
            deploy_frontend
            return 0
        fi
    fi
    
    # Install dependencies
    info "Installing dependencies..."
    npm install || error "Failed to install dependencies"
    
    # Build for production
    info "Building for production..."
    npm run build || error "Build failed"
    
    # Verify build
    if [ ! -d "dist" ] || [ ! -f "dist/index.html" ]; then
        error "Build did not produce expected output"
    fi
    
    success "Frontend built successfully"
    
    cd - > /dev/null
}

# Deploy frontend to web directory
deploy_frontend() {
    log "Deploying frontend to web directory..."
    
    # Create web directory
    sudo mkdir -p /var/www/${DOMAIN}
    
    # Copy built files
    if [ -d "${PROJECT_DIR}/frontend/dist" ]; then
        sudo cp -r ${PROJECT_DIR}/frontend/dist/* /var/www/${DOMAIN}/
    else
        error "Frontend dist directory not found"
    fi
    
    # Set proper permissions
    sudo chown -R www-data:www-data /var/www/${DOMAIN}
    
    # Verify deployment
    if [ -f "/var/www/${DOMAIN}/index.html" ]; then
        success "Frontend deployed successfully"
    else
        error "Frontend deployment failed"
    fi
}

# Test frontend
test_frontend() {
    log "Testing frontend deployment..."
    
    # Test if files exist
    if [ -f "/var/www/${DOMAIN}/index.html" ]; then
        success "Frontend files are in place"
    else
        error "Frontend files not found"
    fi
    
    # Test if Nginx can serve the files
    if curl -f -s http://localhost/ >/dev/null 2>&1; then
        success "Frontend is accessible via HTTP"
    else
        warning "Frontend not accessible via HTTP (this is normal if SSL is configured)"
    fi
    
    # Test HTTPS if available
    if curl -f -s https://${DOMAIN}/ >/dev/null 2>&1; then
        success "Frontend is accessible via HTTPS"
    else
        info "HTTPS not yet configured or not accessible"
    fi
}

# Main function
main() {
    log "=============================================================="
    log "Frontend Deployment Fix"
    log "=============================================================="
    log "Domain: ${DOMAIN}"
    log "Project Directory: ${PROJECT_DIR}"
    log "=============================================================="
    
    check_user
    fix_frontend_directory
    build_frontend
    deploy_frontend
    test_frontend
    
    log "=============================================================="
    success "Frontend deployment fix completed!"
    log "=============================================================="
    echo
    info "Next steps:"
    echo "1. Continue with the main deployment script if it was interrupted"
    echo "2. Or run: ./deploy-ubuntu-complete.sh to restart deployment"
    echo "3. Test the deployment: ./test-deployment.sh"
    echo
    log "=============================================================="
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Frontend Deployment Fix Script"
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  --help, -h    Show this help message"
        echo "  --test        Test frontend only"
        echo "  --deploy      Deploy frontend only (skip build)"
        exit 0
        ;;
    --test)
        test_frontend
        exit 0
        ;;
    --deploy)
        deploy_frontend
        test_frontend
        exit 0
        ;;
    *)
        main
        ;;
esac
