#!/bin/bash

# =============================================================================
# Lawvriksh Service Management Script
# =============================================================================
# Easy management of all Lawvriksh services
# Usage: ./manage-services.sh [start|stop|restart|status|logs|backup|test]
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
COMPOSE_FILE="${PROJECT_DIR}/backend/docker-compose.custom-ports.yml"
DOMAIN="lawvriksh.com"

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

# Check if project directory exists
check_project() {
    if [ ! -d "$PROJECT_DIR" ]; then
        error "Project directory not found: $PROJECT_DIR"
        error "Please run the deployment script first"
        exit 1
    fi
}

# Load environment variables
load_env() {
    if [ -f "${PROJECT_DIR}/.env.production" ]; then
        set -a
        source "${PROJECT_DIR}/.env.production"
        set +a
    else
        warning "Environment file not found: ${PROJECT_DIR}/.env.production"
    fi
}

# Start all services
start_services() {
    log "Starting all Lawvriksh services..."
    
    cd "${PROJECT_DIR}/backend"
    
    # Start Docker services
    docker-compose -f docker-compose.custom-ports.yml up -d
    
    # Wait for services to be ready
    info "Waiting for services to start..."
    sleep 10
    
    # Check if services are running
    if docker-compose -f docker-compose.custom-ports.yml ps | grep -q "Up"; then
        success "Docker services started successfully"
    else
        error "Some Docker services failed to start"
        docker-compose -f docker-compose.custom-ports.yml ps
        exit 1
    fi
    
    # Restart Nginx to ensure it connects to backend
    sudo systemctl restart nginx
    success "Nginx restarted"
    
    # Enable systemd service
    sudo systemctl enable lawvriksh 2>/dev/null || true
    
    success "All services started successfully"
}

# Stop all services
stop_services() {
    log "Stopping all Lawvriksh services..."
    
    cd "${PROJECT_DIR}/backend"
    
    # Stop Docker services
    docker-compose -f docker-compose.custom-ports.yml down
    
    success "All services stopped"
}

# Restart all services
restart_services() {
    log "Restarting all Lawvriksh services..."
    
    stop_services
    sleep 5
    start_services
}

# Show service status
show_status() {
    log "Checking Lawvriksh service status..."
    echo
    
    # Docker services status
    info "Docker Services:"
    cd "${PROJECT_DIR}/backend"
    docker-compose -f docker-compose.custom-ports.yml ps
    echo
    
    # Nginx status
    info "Nginx Status:"
    sudo systemctl status nginx --no-pager -l
    echo
    
    # Systemd service status
    info "Lawvriksh Systemd Service:"
    sudo systemctl status lawvriksh --no-pager -l 2>/dev/null || echo "Systemd service not configured"
    echo
    
    # Port status
    info "Port Status:"
    echo "MySQL (3307): $(nc -z localhost 3307 && echo "Open" || echo "Closed")"
    echo "Backend (8001): $(nc -z localhost 8001 && echo "Open" || echo "Closed")"
    echo "HTTP (80): $(nc -z localhost 80 && echo "Open" || echo "Closed")"
    echo "HTTPS (443): $(nc -z localhost 443 && echo "Open" || echo "Closed")"
    echo
    
    # Health checks
    info "Health Checks:"
    echo -n "Backend API: "
    if curl -f -s http://localhost:8001/health >/dev/null 2>&1; then
        echo "Healthy"
    else
        echo "Unhealthy"
    fi
    
    echo -n "Frontend: "
    if curl -f -s https://${DOMAIN} >/dev/null 2>&1; then
        echo "Accessible"
    else
        echo "Not accessible"
    fi
    
    echo -n "API Endpoint: "
    if curl -f -s https://${DOMAIN}/api/health >/dev/null 2>&1; then
        echo "Accessible"
    else
        echo "Not accessible"
    fi
}

# Show logs
show_logs() {
    log "Showing Lawvriksh service logs..."
    
    case "${2:-all}" in
        backend)
            cd "${PROJECT_DIR}/backend"
            docker-compose -f docker-compose.custom-ports.yml logs -f backend
            ;;
        mysql)
            cd "${PROJECT_DIR}/backend"
            docker-compose -f docker-compose.custom-ports.yml logs -f mysql
            ;;
        celery)
            cd "${PROJECT_DIR}/backend"
            docker-compose -f docker-compose.custom-ports.yml logs -f celery-worker celery-beat
            ;;
        nginx)
            sudo tail -f /var/log/nginx/lawvriksh.com.access.log /var/log/nginx/lawvriksh.com.error.log
            ;;
        all|*)
            cd "${PROJECT_DIR}/backend"
            docker-compose -f docker-compose.custom-ports.yml logs -f
            ;;
    esac
}

# Run backup
run_backup() {
    log "Running backup..."
    
    if [ -f "${PROJECT_DIR}/backup.sh" ]; then
        ${PROJECT_DIR}/backup.sh
        success "Backup completed"
    else
        error "Backup script not found: ${PROJECT_DIR}/backup.sh"
        exit 1
    fi
}

# Run tests
run_tests() {
    log "Running deployment tests..."
    
    if [ -f "test-deployment.sh" ]; then
        ./test-deployment.sh
    else
        error "Test script not found: test-deployment.sh"
        exit 1
    fi
}

# Update application
update_app() {
    log "Updating Lawvriksh application..."
    
    # Pull latest code (if git repository)
    if [ -d "${PROJECT_DIR}/backend/.git" ]; then
        cd "${PROJECT_DIR}/backend"
        git pull
        success "Code updated"
    else
        warning "Not a git repository, skipping code update"
    fi
    
    # Rebuild and restart services
    cd "${PROJECT_DIR}/backend"
    docker-compose -f docker-compose.custom-ports.yml build
    docker-compose -f docker-compose.custom-ports.yml up -d
    
    # Rebuild frontend if needed
    if [ -d "${PROJECT_DIR}/frontend" ]; then
        cd "${PROJECT_DIR}/frontend"
        npm install
        npm run build
        sudo cp -r dist/* /var/www/${DOMAIN}/
        sudo chown -R www-data:www-data /var/www/${DOMAIN}
        success "Frontend updated"
    fi
    
    # Restart Nginx
    sudo systemctl restart nginx
    
    success "Application updated successfully"
}

# Show help
show_help() {
    echo "Lawvriksh Service Management Script"
    echo
    echo "Usage: $0 [command] [options]"
    echo
    echo "Commands:"
    echo "  start     Start all services"
    echo "  stop      Stop all services"
    echo "  restart   Restart all services"
    echo "  status    Show service status"
    echo "  logs      Show logs [backend|mysql|celery|nginx|all]"
    echo "  backup    Run backup"
    echo "  test      Run deployment tests"
    echo "  update    Update application"
    echo "  help      Show this help"
    echo
    echo "Examples:"
    echo "  $0 start"
    echo "  $0 logs backend"
    echo "  $0 status"
    echo "  $0 backup"
}

# Main function
main() {
    check_project
    load_env
    
    case "${1:-help}" in
        start)
            start_services
            ;;
        stop)
            stop_services
            ;;
        restart)
            restart_services
            ;;
        status)
            show_status
            ;;
        logs)
            show_logs "$@"
            ;;
        backup)
            run_backup
            ;;
        test)
            run_tests
            ;;
        update)
            update_app
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $1"
            echo
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@"
