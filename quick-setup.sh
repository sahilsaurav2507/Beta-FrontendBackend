#!/bin/bash

# =============================================================================
# Lawvriksh Quick Setup Script
# =============================================================================
# This script provides a quick way to set up the environment and start services
# after the main deployment script has been run.
# =============================================================================

set -e

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

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Please run as a regular user with sudo privileges."
    fi
}

# Generate secure environment file
generate_env_file() {
    log "Generating production environment file..."
    
    if [ ! -f "${PROJECT_DIR}/.env.production" ]; then
        # Copy template
        cp .env.production.template ${PROJECT_DIR}/.env.production
        
        # Generate secure passwords
        DB_PASSWORD=$(openssl rand -base64 32)
        DB_ROOT_PASSWORD=$(openssl rand -base64 32)
        JWT_SECRET_KEY=$(openssl rand -base64 64)
        SECRET_KEY=$(openssl rand -base64 64)
        RABBITMQ_PASSWORD=$(openssl rand -base64 32)
        REDIS_PASSWORD=$(openssl rand -base64 32)
        
        # Replace placeholders
        sed -i "s/CHANGE_THIS_SECURE_PASSWORD/${DB_PASSWORD}/g" ${PROJECT_DIR}/.env.production
        sed -i "s/CHANGE_THIS_ROOT_PASSWORD/${DB_ROOT_PASSWORD}/g" ${PROJECT_DIR}/.env.production
        sed -i "s/CHANGE_THIS_JWT_SECRET_KEY_TO_LONG_RANDOM_STRING/${JWT_SECRET_KEY}/g" ${PROJECT_DIR}/.env.production
        sed -i "s/CHANGE_THIS_SECRET_KEY_TO_LONG_RANDOM_STRING/${SECRET_KEY}/g" ${PROJECT_DIR}/.env.production
        sed -i "s/CHANGE_THIS_RABBITMQ_PASSWORD/${RABBITMQ_PASSWORD}/g" ${PROJECT_DIR}/.env.production
        sed -i "s/CHANGE_THIS_REDIS_PASSWORD/${REDIS_PASSWORD}/g" ${PROJECT_DIR}/.env.production
        
        chmod 600 ${PROJECT_DIR}/.env.production
        success "Environment file generated with secure passwords"
    else
        info "Environment file already exists"
    fi
}

# Build and start services
start_services() {
    log "Starting all services..."

    cd ${PROJECT_DIR}/backend

    # Load environment variables
    set -a
    source ${PROJECT_DIR}/.env.production
    set +a

    # Check if Docker Compose file exists
    if [ ! -f "docker-compose.custom-ports.yml" ]; then
        error "Docker Compose file not found. Please run the main deployment script first."
    fi

    # Build and start services
    info "Building Docker images..."
    if docker compose -f docker-compose.custom-ports.yml build; then
        info "Starting services..."
        docker compose -f docker-compose.custom-ports.yml up -d
    elif docker-compose -f docker-compose.custom-ports.yml build; then
        info "Starting services..."
        docker-compose -f docker-compose.custom-ports.yml up -d
    else
        error "Failed to build and start services"
    fi

    success "Services started"
}

# Wait for services to be ready
wait_for_services() {
    log "Waiting for services to be ready..."
    
    # Wait for MySQL
    info "Waiting for MySQL..."
    for i in {1..30}; do
        if nc -z localhost 3307; then
            success "MySQL is ready"
            break
        fi
        sleep 2
    done
    
    # Wait for backend
    info "Waiting for backend..."
    for i in {1..30}; do
        if curl -f -s http://localhost:8001/health >/dev/null 2>&1; then
            success "Backend is ready"
            break
        fi
        sleep 2
    done
}

# Setup database
setup_database() {
    log "Setting up database..."
    
    cd ${PROJECT_DIR}/backend
    
    # Run database migrations
    if [ -f "alembic.ini" ]; then
        docker-compose -f docker-compose.custom-ports.yml exec backend alembic upgrade head
        success "Database migrations completed"
    else
        warning "No alembic.ini found, skipping migrations"
    fi
}

# Build frontend
build_frontend() {
    log "Building frontend..."

    # Check if frontend directory exists
    if [ ! -d "${PROJECT_DIR}/frontend" ]; then
        warning "Frontend directory not found, attempting to copy from current location..."

        # Try to find and copy Frontend directory
        if [ -d "Frontend" ]; then
            mkdir -p ${PROJECT_DIR}/frontend
            cp -r Frontend/* ${PROJECT_DIR}/frontend/
            chown -R $USER:$USER ${PROJECT_DIR}/frontend
            success "Frontend files copied"
        elif [ -d "../Frontend" ]; then
            mkdir -p ${PROJECT_DIR}/frontend
            cp -r ../Frontend/* ${PROJECT_DIR}/frontend/
            chown -R $USER:$USER ${PROJECT_DIR}/frontend
            success "Frontend files copied from parent directory"
        else
            error "Frontend directory not found anywhere"
        fi
    fi

    cd ${PROJECT_DIR}/frontend

    # Verify package.json exists
    if [ ! -f "package.json" ]; then
        error "package.json not found in frontend directory"
    fi

    # Check if already built
    if [ -d "dist" ] && [ -f "dist/index.html" ]; then
        info "Frontend appears to be pre-built, using existing build"
    else
        # Install dependencies and build
        info "Installing dependencies..."
        npm install || error "Failed to install dependencies"

        info "Building frontend..."
        npm run build || error "Frontend build failed"
    fi

    # Verify build output
    if [ ! -d "dist" ] || [ ! -f "dist/index.html" ]; then
        error "Frontend build did not produce expected output"
    fi

    # Copy to nginx directory
    sudo mkdir -p /var/www/${DOMAIN}
    sudo cp -r dist/* /var/www/${DOMAIN}/
    sudo chown -R www-data:www-data /var/www/${DOMAIN}

    cd - > /dev/null
    success "Frontend built and deployed"
}

# Configure and restart nginx
setup_nginx() {
    log "Setting up Nginx..."
    
    # Copy nginx configuration
    sudo cp nginx-lawvriksh.conf /etc/nginx/sites-available/${DOMAIN}
    sudo ln -sf /etc/nginx/sites-available/${DOMAIN} /etc/nginx/sites-enabled/
    
    # Test configuration
    sudo nginx -t
    
    # Restart nginx
    sudo systemctl restart nginx
    
    success "Nginx configured and restarted"
}

# Setup SSL certificates
setup_ssl() {
    log "Setting up SSL certificates..."
    
    # Create webroot for challenges
    sudo mkdir -p /var/www/certbot
    sudo chown www-data:www-data /var/www/certbot
    
    # Get certificates
    sudo certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN}
    
    # Setup auto-renewal
    echo "0 12 * * * /usr/bin/certbot renew --quiet" | sudo crontab -
    
    success "SSL certificates configured"
}

# Create systemd service
create_systemd_service() {
    log "Creating systemd service..."
    
    sudo tee /etc/systemd/system/lawvriksh.service > /dev/null << EOF
[Unit]
Description=Lawvriksh Application
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_DIR}/backend
ExecStart=/usr/local/bin/docker-compose -f docker-compose.custom-ports.yml up -d
ExecStop=/usr/local/bin/docker-compose -f docker-compose.custom-ports.yml down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable lawvriksh.service
    
    success "Systemd service created"
}

# Run tests
run_tests() {
    log "Running deployment tests..."
    
    if [ -f "test-deployment.sh" ]; then
        chmod +x test-deployment.sh
        ./test-deployment.sh
    else
        warning "Test script not found"
    fi
}

# Display final information
display_info() {
    log "=============================================================="
    log "Lawvriksh Quick Setup Completed!"
    log "=============================================================="
    echo
    success "Domain: https://${DOMAIN}"
    success "API: https://${DOMAIN}/api"
    success "MySQL Port: 3307"
    success "Backend Port: 8001"
    echo
    info "Useful commands:"
    echo "  - View logs: docker-compose -f ${PROJECT_DIR}/backend/docker-compose.custom-ports.yml logs -f"
    echo "  - Restart: sudo systemctl restart lawvriksh"
    echo "  - Status: docker-compose -f ${PROJECT_DIR}/backend/docker-compose.custom-ports.yml ps"
    echo "  - Test: ./test-deployment.sh"
    echo
    warning "Don't forget to:"
    echo "1. Update email settings in ${PROJECT_DIR}/.env.production"
    echo "2. Test the application thoroughly"
    echo "3. Set up monitoring and backups"
    log "=============================================================="
}

# Main function
main() {
    log "Starting Lawvriksh Quick Setup..."
    
    check_root
    generate_env_file
    start_services
    wait_for_services
    setup_database
    build_frontend
    setup_nginx
    setup_ssl
    create_systemd_service
    run_tests
    display_info
}

# Handle arguments
case "${1:-}" in
    --help|-h)
        echo "Lawvriksh Quick Setup Script"
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  --help, -h    Show this help"
        echo "  --env         Generate environment file only"
        echo "  --services    Start services only"
        echo "  --frontend    Build frontend only"
        echo "  --nginx       Setup Nginx only"
        echo "  --ssl         Setup SSL only"
        echo "  --test        Run tests only"
        exit 0
        ;;
    --env)
        generate_env_file
        ;;
    --services)
        start_services
        wait_for_services
        ;;
    --frontend)
        build_frontend
        ;;
    --nginx)
        setup_nginx
        ;;
    --ssl)
        setup_ssl
        ;;
    --test)
        run_tests
        ;;
    *)
        main
        ;;
esac
