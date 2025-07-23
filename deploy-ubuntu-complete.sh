#!/bin/bash

# =============================================================================
# Complete Lawvriksh Deployment Script for Ubuntu 24.04
# =============================================================================
# This script handles complete deployment including:
# - Docker and Docker Compose installation
# - MySQL on custom port (3307)
# - Backend on custom port (8001)
# - Frontend served by Nginx
# - SSL certificates with Certbot
# - Database initialization and migrations
# - Domain: lawvriksh.com (frontend) and lawvriksh.com/api (backend)
# =============================================================================

set -euo pipefail  # Exit on any error, undefined variables, and pipe failures

# Trap to cleanup on exit
trap cleanup EXIT

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Deployment failed with exit code $exit_code"
        log "Check the logs above for details"
    fi
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
PROJECT_NAME="lawvriksh"
DOMAIN="lawvriksh.com"
MYSQL_PORT="3307"
BACKEND_PORT="8001"
FRONTEND_PORT="3000"
PROJECT_DIR="/opt/${PROJECT_NAME}"
NGINX_SITES_DIR="/etc/nginx/sites-available"
NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"

# Database configuration
DB_NAME="lawvriksh_production"
DB_USER="lawvriksh_user"

# Deployment state tracking
DEPLOYMENT_STATE_FILE="${PROJECT_DIR}/.deployment_state"

# Required packages
REQUIRED_PACKAGES=(
    "curl" "wget" "git" "unzip" "software-properties-common"
    "apt-transport-https" "ca-certificates" "gnupg" "lsb-release"
    "build-essential" "python3-pip" "python3-venv" "nodejs" "npm"
    "ufw" "fail2ban" "htop" "tree" "jq" "netcat-openbsd"
)

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

step() {
    echo -e "${CYAN}[STEP] $1${NC}"
}

# Save deployment state
save_state() {
    local step="$1"
    echo "$step" > "$DEPLOYMENT_STATE_FILE"
    log "Deployment state saved: $step"
}

# Get deployment state
get_state() {
    if [ -f "$DEPLOYMENT_STATE_FILE" ]; then
        cat "$DEPLOYMENT_STATE_FILE"
    else
        echo "not_started"
    fi
}

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Please run as a regular user with sudo privileges."
    fi
}

# Check system requirements
check_system_requirements() {
    step "Checking system requirements..."

    # Check available disk space (need at least 5GB)
    local available_space=$(df / | awk 'NR==2 {print $4}')
    local required_space=5242880  # 5GB in KB

    if [ "$available_space" -lt "$required_space" ]; then
        error "Insufficient disk space. Need at least 5GB, available: $(($available_space/1024/1024))GB"
    fi

    # Check available memory (need at least 2GB)
    local available_memory=$(free -k | awk 'NR==2{print $2}')
    local required_memory=2097152  # 2GB in KB

    if [ "$available_memory" -lt "$required_memory" ]; then
        warning "Low memory detected. Recommended: 2GB+, available: $(($available_memory/1024/1024))GB"
    fi

    # Check if domain resolves to this server
    local server_ip=$(curl -s ifconfig.me || echo "unknown")
    local domain_ip=$(dig +short "$DOMAIN" | tail -n1 || echo "unknown")

    if [ "$server_ip" != "unknown" ] && [ "$domain_ip" != "unknown" ]; then
        if [ "$server_ip" != "$domain_ip" ]; then
            warning "Domain $DOMAIN does not resolve to this server IP ($server_ip vs $domain_ip)"
            warning "SSL certificate generation may fail"
        else
            success "Domain $DOMAIN correctly resolves to this server"
        fi
    fi

    success "System requirements check completed"
}

# Check Ubuntu version
check_ubuntu_version() {
    log "Checking Ubuntu version..."
    if ! grep -q "24.04" /etc/os-release; then
        warning "This script is optimized for Ubuntu 24.04. Current version:"
        cat /etc/os-release | grep VERSION
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    success "Ubuntu version check passed"
}

# Update system packages
update_system() {
    step "Updating system packages..."

    # Update package lists
    sudo apt update || error "Failed to update package lists"

    # Upgrade existing packages
    sudo apt upgrade -y || warning "Package upgrade failed, continuing anyway"

    # Install required packages
    echo "Installing required packages: ${REQUIRED_PACKAGES[*]}"
    sudo apt install -y "${REQUIRED_PACKAGES[@]}" || error "Failed to install required packages"

    # Check if all required packages are installed
    local missing_packages=()
    for pkg in "${REQUIRED_PACKAGES[@]}"; do
        if ! dpkg -l | grep -q "ii  $pkg"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        warning "Some packages could not be installed: ${missing_packages[*]}"
        warning "You may need to install them manually"
    else
        success "All required packages installed successfully"
    fi

    # Install Node.js LTS if needed
    if ! command -v node >/dev/null || [ "$(node -v | cut -d. -f1 | tr -d 'v')" -lt 16 ]; then
        info "Installing/updating Node.js LTS..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt install -y nodejs
    fi

    success "System packages updated"
}

# Configure firewall
configure_firewall() {
    step "Configuring UFW firewall..."
    sudo ufw --force reset
    sudo ufw default deny incoming
    sudo ufw default allow outgoing
    sudo ufw allow ssh
    sudo ufw allow 80/tcp
    sudo ufw allow 443/tcp
    sudo ufw allow ${MYSQL_PORT}/tcp
    sudo ufw allow ${BACKEND_PORT}/tcp
    sudo ufw --force enable
    success "Firewall configured"
}

# Install Docker
install_docker() {
    step "Installing Docker..."

    # Check if Docker is already installed
    if command -v docker >/dev/null 2>&1; then
        info "Docker is already installed, checking version..."
        docker --version

        # Check if Docker is running
        if ! sudo systemctl is-active --quiet docker; then
            sudo systemctl start docker
            sudo systemctl enable docker
        fi

        # Ensure user is in docker group
        if ! groups $USER | grep -q docker; then
            sudo usermod -aG docker $USER
            warning "Added user to docker group. You may need to log out and back in."
        fi

        success "Docker is ready"
        return 0
    fi

    # Remove old versions
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg || error "Failed to add Docker GPG key"

    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    sudo apt update || error "Failed to update package lists after adding Docker repository"
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || error "Failed to install Docker"

    # Add user to docker group
    sudo usermod -aG docker $USER

    # Start and enable Docker
    sudo systemctl start docker || error "Failed to start Docker service"
    sudo systemctl enable docker || error "Failed to enable Docker service"

    # Test Docker installation
    if sudo docker run --rm hello-world >/dev/null 2>&1; then
        success "Docker installed and tested successfully"
    else
        error "Docker installation test failed"
    fi

    warning "You may need to log out and back in for Docker group membership to take effect"
}

# Install Docker Compose
install_docker_compose() {
    step "Installing Docker Compose..."

    # Check if Docker Compose is already available (comes with Docker Desktop)
    if docker compose version >/dev/null 2>&1; then
        info "Docker Compose (plugin) is already available"
        docker compose version
        success "Docker Compose is ready"
        return 0
    fi

    # Check if standalone docker-compose is installed
    if command -v docker-compose >/dev/null 2>&1; then
        info "Docker Compose (standalone) is already installed"
        docker-compose --version
        success "Docker Compose is ready"
        return 0
    fi

    # Install standalone Docker Compose
    info "Installing standalone Docker Compose..."

    # Get latest version
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r '.tag_name' 2>/dev/null || echo "v2.23.0")

    if [ -z "$DOCKER_COMPOSE_VERSION" ] || [ "$DOCKER_COMPOSE_VERSION" = "null" ]; then
        DOCKER_COMPOSE_VERSION="v2.23.0"
        warning "Could not fetch latest version, using $DOCKER_COMPOSE_VERSION"
    fi

    info "Installing Docker Compose $DOCKER_COMPOSE_VERSION..."

    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose || error "Failed to download Docker Compose"
    sudo chmod +x /usr/local/bin/docker-compose || error "Failed to make Docker Compose executable"

    # Create symlink
    sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

    # Test installation
    if docker-compose --version >/dev/null 2>&1; then
        success "Docker Compose installed successfully"
        docker-compose --version
    else
        error "Docker Compose installation failed"
    fi
}

# Install Nginx
install_nginx() {
    step "Installing and configuring Nginx..."
    sudo apt install -y nginx
    sudo systemctl start nginx
    sudo systemctl enable nginx
    
    # Remove default site
    sudo rm -f /etc/nginx/sites-enabled/default
    
    success "Nginx installed"
}

# Install Certbot
install_certbot() {
    step "Installing Certbot for SSL certificates..."
    sudo apt install -y certbot python3-certbot-nginx
    success "Certbot installed"
}

# Generate secure passwords and keys
generate_secrets() {
    step "Generating secure passwords and keys..."
    
    # Generate random passwords
    DB_ROOT_PASSWORD=$(openssl rand -base64 32)
    DB_PASSWORD=$(openssl rand -base64 32)
    JWT_SECRET_KEY=$(openssl rand -base64 64)
    RABBITMQ_USER="lawvriksh_rabbit"
    RABBITMQ_PASSWORD=$(openssl rand -base64 32)
    REDIS_PASSWORD=$(openssl rand -base64 32)
    
    success "Secrets generated"
}

# Create project directory structure
create_project_structure() {
    step "Creating project directory structure..."
    
    sudo mkdir -p ${PROJECT_DIR}
    sudo chown $USER:$USER ${PROJECT_DIR}
    
    mkdir -p ${PROJECT_DIR}/{logs,cache,data,backups,ssl,frontend}
    mkdir -p ${PROJECT_DIR}/data/{mysql,rabbitmq,redis}
    mkdir -p ${PROJECT_DIR}/logs/{nginx,mysql,backend,celery,frontend}
    
    success "Project structure created at ${PROJECT_DIR}"
}

# Create environment file
create_environment_file() {
    step "Creating production environment file..."
    
    cat > ${PROJECT_DIR}/.env.production << EOF
# =============================================================================
# Lawvriksh Production Environment Configuration
# =============================================================================
# Generated on: $(date)
# Domain: ${DOMAIN}
# MySQL Port: ${MYSQL_PORT}
# Backend Port: ${BACKEND_PORT}
# =============================================================================

# Domain Configuration
DOMAIN=${DOMAIN}
API_BASE_URL=https://${DOMAIN}/api
FRONTEND_URL=https://${DOMAIN}

# Database Configuration
DB_HOST=localhost
DB_PORT=${MYSQL_PORT}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
MYSQL_ROOT_PASSWORD=${DB_ROOT_PASSWORD}
DATABASE_URL=mysql+pymysql://${DB_USER}:${DB_PASSWORD}@localhost:${MYSQL_PORT}/${DB_NAME}

# Backend Configuration
BACKEND_HOST=localhost
BACKEND_PORT=${BACKEND_PORT}

# Message Queue Configuration
RABBITMQ_HOST=localhost
RABBITMQ_PORT=5672
RABBITMQ_USER=${RABBITMQ_USER}
RABBITMQ_PASSWORD=${RABBITMQ_PASSWORD}
RABBITMQ_VHOST=lawvriksh
RABBITMQ_URL=amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@localhost:5672/lawvriksh

# Cache Configuration
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_URL=redis://:${REDIS_PASSWORD}@localhost:6379/0

# Security Configuration
JWT_SECRET_KEY=${JWT_SECRET_KEY}
SECRET_KEY=${JWT_SECRET_KEY}

# Application Settings
ENVIRONMENT=production
DEBUG=false
LOG_LEVEL=INFO
CACHE_DIR=${PROJECT_DIR}/cache

# Email Configuration (to be filled by user)
EMAIL_FROM=noreply@${DOMAIN}
SMTP_HOST=smtp.gmail.com
SMTP_PORT=587
SMTP_USER=your-email@gmail.com
SMTP_PASSWORD=your-app-password

# Security Headers
ALLOWED_HOSTS=${DOMAIN},www.${DOMAIN},localhost,127.0.0.1

# File Upload Configuration
UPLOAD_DIR=${PROJECT_DIR}/uploads
MAX_UPLOAD_SIZE=10485760

# Backup Configuration
BACKUP_DIR=${PROJECT_DIR}/backups
BACKUP_RETENTION_DAYS=30
EOF

    chmod 600 ${PROJECT_DIR}/.env.production
    success "Environment file created at ${PROJECT_DIR}/.env.production"
}

# Copy application files
copy_application_files() {
    step "Copying application files to ${PROJECT_DIR}..."

    # Create directories
    mkdir -p ${PROJECT_DIR}/backend
    mkdir -p ${PROJECT_DIR}/frontend

    # Copy backend files (exclude Frontend directory)
    info "Copying backend files..."
    rsync -av --exclude='Frontend' --exclude='.git' --exclude='__pycache__' \
          --exclude='*.pyc' --exclude='.env*' --exclude='node_modules' \
          --exclude='dist' --exclude='build' \
          . ${PROJECT_DIR}/backend/ || error "Failed to copy backend files"

    # Copy frontend files
    if [ -d "Frontend" ]; then
        info "Copying frontend files..."
        cp -r Frontend/* ${PROJECT_DIR}/frontend/ || error "Failed to copy frontend files"

        # Verify package.json exists
        if [ -f "${PROJECT_DIR}/frontend/package.json" ]; then
            success "Frontend package.json found"
        else
            error "Frontend package.json not found after copying"
        fi
    else
        warning "Frontend directory not found in current location"
        # Try to find Frontend directory
        if [ -d "../Frontend" ]; then
            info "Found Frontend directory in parent directory, copying..."
            cp -r ../Frontend/* ${PROJECT_DIR}/frontend/
        else
            error "Frontend directory not found"
        fi
    fi

    # Set proper permissions
    chown -R $USER:$USER ${PROJECT_DIR}/backend ${PROJECT_DIR}/frontend

    success "Application files copied"
}

# Build frontend
build_frontend() {
    step "Building frontend application..."

    if [ -d "${PROJECT_DIR}/frontend" ]; then
        cd ${PROJECT_DIR}/frontend

        # Check if package.json exists
        if [ ! -f "package.json" ]; then
            error "package.json not found in frontend directory"
        fi

        # Check if dist directory already exists (pre-built)
        if [ -d "dist" ] && [ -f "dist/index.html" ]; then
            info "Frontend appears to be pre-built, using existing dist directory"
        else
            # Check Node.js version
            if ! command -v node >/dev/null; then
                error "Node.js is not installed"
            fi

            local node_version=$(node -v | cut -d'v' -f2 | cut -d'.' -f1)
            if [ "$node_version" -lt 16 ]; then
                warning "Node.js version is $node_version, recommended version is 16+"
            fi

            # Install dependencies
            info "Installing frontend dependencies..."
            npm install || error "Failed to install frontend dependencies"

            # Build for production
            info "Building frontend for production..."
            npm run build || error "Frontend build failed"
        fi

        # Verify build output
        if [ ! -d "dist" ] || [ ! -f "dist/index.html" ]; then
            error "Frontend build did not produce expected output (dist/index.html)"
        fi

        # Copy built files to nginx directory
        info "Deploying frontend files to web directory..."
        sudo mkdir -p /var/www/${DOMAIN}
        sudo cp -r dist/* /var/www/${DOMAIN}/ || error "Failed to copy frontend files to web directory"
        sudo chown -R www-data:www-data /var/www/${DOMAIN}

        # Verify deployment
        if [ -f "/var/www/${DOMAIN}/index.html" ]; then
            success "Frontend built and deployed successfully"
        else
            error "Frontend deployment verification failed"
        fi

        cd - > /dev/null
    else
        error "Frontend directory not found at ${PROJECT_DIR}/frontend"
    fi
}

# Create Nginx configuration
create_nginx_config() {
    step "Creating Nginx configuration..."

    # Create main site configuration
    sudo tee ${NGINX_SITES_DIR}/${DOMAIN} > /dev/null << EOF
# Lawvriksh Nginx Configuration
# Frontend: ${DOMAIN}
# Backend API: ${DOMAIN}/api

# Rate limiting
limit_req_zone \$binary_remote_addr zone=api:10m rate=10r/s;
limit_req_zone \$binary_remote_addr zone=login:10m rate=5r/m;

# Upstream backend
upstream backend {
    server 127.0.0.1:${BACKEND_PORT};
    keepalive 32;
}

# HTTP to HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN} www.${DOMAIN};

    # Let's Encrypt challenge
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Redirect all HTTP to HTTPS
    location / {
        return 301 https://\$server_name\$request_uri;
    }
}

# HTTPS server
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${DOMAIN} www.${DOMAIN};

    # SSL Configuration (will be updated by Certbot)
    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

    # SSL Security
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-RSA-AES256-GCM-SHA512:DHE-RSA-AES256-GCM-SHA512:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # Security Headers
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header X-Frame-Options DENY always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    # Gzip compression
    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_types text/plain text/css text/xml text/javascript application/javascript application/xml+rss application/json;

    # Frontend - Static files
    location / {
        root /var/www/${DOMAIN};
        index index.html;
        try_files \$uri \$uri/ /index.html;

        # Cache static assets
        location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)\$ {
            expires 1y;
            add_header Cache-Control "public, immutable";
        }
    }

    # Backend API
    location /api/ {
        # Rate limiting
        limit_req zone=api burst=20 nodelay;

        # Proxy settings
        proxy_pass http://backend/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_cache_bypass \$http_upgrade;

        # Timeouts
        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;

        # Buffer settings
        proxy_buffering on;
        proxy_buffer_size 128k;
        proxy_buffers 4 256k;
        proxy_busy_buffers_size 256k;
    }

    # Special rate limiting for login endpoints
    location /api/auth/login {
        limit_req zone=login burst=3 nodelay;
        proxy_pass http://backend/auth/login;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    # Health check endpoint
    location /api/health {
        proxy_pass http://backend/health;
        access_log off;
    }

    # Deny access to sensitive files
    location ~ /\. {
        deny all;
    }

    location ~ \.(env|log|ini)\$ {
        deny all;
    }
}
EOF

    # Enable the site
    sudo ln -sf ${NGINX_SITES_DIR}/${DOMAIN} ${NGINX_ENABLED_DIR}/

    # Test Nginx configuration
    sudo nginx -t

    success "Nginx configuration created"
}

# Wait for services to be ready
wait_for_services() {
    step "Waiting for services to be ready..."

    local max_attempts=60
    local attempt=0

    # Wait for MySQL
    info "Waiting for MySQL on port ${MYSQL_PORT}..."
    while ! nc -z localhost ${MYSQL_PORT} && [ $attempt -lt $max_attempts ]; do
        sleep 5
        ((attempt++))
        echo -n "."
    done

    if [ $attempt -eq $max_attempts ]; then
        error "MySQL failed to start within $(($max_attempts * 5)) seconds"
    fi
    success "MySQL is ready"

    # Wait for backend
    attempt=0
    info "Waiting for backend on port ${BACKEND_PORT}..."
    while ! curl -f -s http://localhost:${BACKEND_PORT}/health >/dev/null 2>&1 && [ $attempt -lt $max_attempts ]; do
        sleep 5
        ((attempt++))
        echo -n "."
    done

    if [ $attempt -eq $max_attempts ]; then
        error "Backend failed to start within $(($max_attempts * 5)) seconds"
    fi
    success "Backend is ready"
}

# Initialize database
initialize_database() {
    step "Initializing database..."

    cd ${PROJECT_DIR}/backend

    # Load environment variables
    set -a
    source ${PROJECT_DIR}/.env.production
    set +a

    # Wait for MySQL to be ready
    info "Waiting for MySQL to be ready for connections..."
    local max_attempts=30
    local attempt=0

    while ! docker exec lawvriksh-mysql mysqladmin ping -h localhost -u root -p${MYSQL_ROOT_PASSWORD} --silent >/dev/null 2>&1 && [ $attempt -lt $max_attempts ]; do
        sleep 2
        ((attempt++))
    done

    if [ $attempt -eq $max_attempts ]; then
        error "MySQL is not ready for connections"
    fi

    # Create database if it doesn't exist
    info "Creating database if it doesn't exist..."
    docker exec lawvriksh-mysql mysql -u root -p${MYSQL_ROOT_PASSWORD} -e "CREATE DATABASE IF NOT EXISTS ${DB_NAME};" || error "Failed to create database"

    # Run database migrations if alembic is available
    if [ -f "alembic.ini" ]; then
        info "Running database migrations..."
        docker exec lawvriksh-backend alembic upgrade head || warning "Database migrations failed, continuing anyway"
    else
        warning "No alembic.ini found, skipping migrations"
    fi

    # Run database initialization script if available
    if [ -f "init_db.py" ]; then
        info "Running database initialization..."
        docker exec lawvriksh-backend python init_db.py || warning "Database initialization script failed"
    fi

    success "Database initialized"
}

# Create Docker Compose with custom ports
create_docker_compose() {
    step "Creating Docker Compose configuration with custom ports..."

    cat > ${PROJECT_DIR}/backend/docker-compose.custom-ports.yml << 'EOF'
version: '3.8'

# Production Docker Compose for Lawvriksh
# MySQL Port: 3307 (custom)
# Backend Port: 8001 (custom)
# Domain: lawvriksh.com

services:
  # MySQL Database on custom port
  mysql:
    image: mysql:8.0
    container_name: lawvriksh-mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: ${DB_NAME}
      MYSQL_USER: ${DB_USER}
      MYSQL_PASSWORD: ${DB_PASSWORD}
      MYSQL_CHARSET: utf8mb4
      MYSQL_COLLATION: utf8mb4_unicode_ci
    volumes:
      - mysql_data:/var/lib/mysql
      - ../data/mysql:/var/lib/mysql-backup
      - ../logs/mysql:/var/log/mysql
    ports:
      - "127.0.0.1:3307:3306"  # Custom MySQL port
    command: >
      --default-authentication-plugin=mysql_native_password
      --character-set-server=utf8mb4
      --collation-server=utf8mb4_unicode_ci
      --innodb-buffer-pool-size=512M
      --max-connections=200
      --slow-query-log=1
      --slow-query-log-file=/var/log/mysql/slow.log
      --long-query-time=2
      --bind-address=0.0.0.0
    networks:
      - lawvriksh-network
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p${MYSQL_ROOT_PASSWORD}"]
      timeout: 20s
      retries: 10
      interval: 30s

  # RabbitMQ Message Queue
  rabbitmq:
    image: rabbitmq:3.12-management
    container_name: lawvriksh-rabbitmq
    restart: unless-stopped
    environment:
      RABBITMQ_DEFAULT_USER: ${RABBITMQ_USER}
      RABBITMQ_DEFAULT_PASS: ${RABBITMQ_PASSWORD}
      RABBITMQ_DEFAULT_VHOST: lawvriksh
    volumes:
      - rabbitmq_data:/var/lib/rabbitmq
      - ../logs/rabbitmq:/var/log/rabbitmq
    ports:
      - "127.0.0.1:5672:5672"    # AMQP port
      - "127.0.0.1:15672:15672"  # Management UI
    networks:
      - lawvriksh-network
    healthcheck:
      test: rabbitmq-diagnostics -q ping
      interval: 30s
      timeout: 30s
      retries: 3

  # Redis Cache
  redis:
    image: redis:7-alpine
    container_name: lawvriksh-redis
    restart: unless-stopped
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
      - ../logs/redis:/var/log/redis
    ports:
      - "127.0.0.1:6379:6379"
    networks:
      - lawvriksh-network
    healthcheck:
      test: ["CMD", "redis-cli", "--raw", "incr", "ping"]
      interval: 30s
      timeout: 10s
      retries: 3
EOF

    # Continue Docker Compose configuration
    cat >> ${PROJECT_DIR}/backend/docker-compose.custom-ports.yml << 'EOF'

  # FastAPI Backend Application on custom port
  backend:
    build:
      context: .
      dockerfile: Dockerfile.production
      args:
        - BUILD_ENV=production
    container_name: lawvriksh-backend
    restart: unless-stopped
    environment:
      # Database Configuration
      DATABASE_URL: mysql+pymysql://${DB_USER}:${DB_PASSWORD}@mysql:3306/${DB_NAME}

      # Message Queue
      RABBITMQ_URL: amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/lawvriksh

      # Cache
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0

      # Security
      JWT_SECRET_KEY: ${JWT_SECRET_KEY}

      # Email Configuration
      EMAIL_FROM: ${EMAIL_FROM}
      SMTP_HOST: ${SMTP_HOST}
      SMTP_PORT: ${SMTP_PORT}
      SMTP_USER: ${SMTP_USER}
      SMTP_PASSWORD: ${SMTP_PASSWORD}

      # Application Settings
      ENVIRONMENT: production
      DEBUG: "false"
      CACHE_DIR: /app/cache
      LOG_LEVEL: INFO

      # Domain Configuration
      DOMAIN: ${DOMAIN}
      API_BASE_URL: https://${DOMAIN}/api
      FRONTEND_URL: https://${DOMAIN}

      # Security Headers
      ALLOWED_HOSTS: ${DOMAIN},www.${DOMAIN}

    volumes:
      - ../cache:/app/cache
      - ../logs/backend:/app/logs
      - ../uploads:/app/uploads
    ports:
      - "127.0.0.1:8001:8000"  # Custom backend port
    depends_on:
      mysql:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - lawvriksh-network
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  # Celery Worker for Background Tasks
  celery-worker:
    build:
      context: .
      dockerfile: Dockerfile.production
      args:
        - BUILD_ENV=production
    container_name: lawvriksh-celery-worker
    restart: unless-stopped
    command: celery -A app.tasks.celery_app worker --loglevel=info --concurrency=2
    environment:
      DATABASE_URL: mysql+pymysql://${DB_USER}:${DB_PASSWORD}@mysql:3306/${DB_NAME}
      RABBITMQ_URL: amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/lawvriksh
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      JWT_SECRET_KEY: ${JWT_SECRET_KEY}
      EMAIL_FROM: ${EMAIL_FROM}
      SMTP_HOST: ${SMTP_HOST}
      SMTP_PORT: ${SMTP_PORT}
      SMTP_USER: ${SMTP_USER}
      SMTP_PASSWORD: ${SMTP_PASSWORD}
      ENVIRONMENT: production
      DEBUG: "false"
      LOG_LEVEL: INFO
    volumes:
      - ../cache:/app/cache
      - ../logs/celery:/app/logs
    depends_on:
      mysql:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - lawvriksh-network

  # Celery Beat Scheduler
  celery-beat:
    build:
      context: .
      dockerfile: Dockerfile.production
      args:
        - BUILD_ENV=production
    container_name: lawvriksh-celery-beat
    restart: unless-stopped
    command: celery -A app.tasks.celery_app beat --loglevel=info
    environment:
      DATABASE_URL: mysql+pymysql://${DB_USER}:${DB_PASSWORD}@mysql:3306/${DB_NAME}
      RABBITMQ_URL: amqp://${RABBITMQ_USER}:${RABBITMQ_PASSWORD}@rabbitmq:5672/lawvriksh
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      JWT_SECRET_KEY: ${JWT_SECRET_KEY}
      ENVIRONMENT: production
      DEBUG: "false"
      LOG_LEVEL: INFO
    volumes:
      - ../cache:/app/cache
      - ../logs/celery-beat:/app/logs
    depends_on:
      mysql:
        condition: service_healthy
      rabbitmq:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - lawvriksh-network

# Networks
networks:
  lawvriksh-network:
    driver: bridge
    name: lawvriksh-network

# Volumes
volumes:
  mysql_data:
    driver: local
    name: lawvriksh-mysql-data
  rabbitmq_data:
    driver: local
    name: lawvriksh-rabbitmq-data
  redis_data:
    driver: local
    name: lawvriksh-redis-data
EOF

    success "Docker Compose configuration created with custom ports"
}

# Setup SSL certificates
setup_ssl() {
    step "Setting up SSL certificates with Certbot..."

    # Create webroot directory for challenges
    sudo mkdir -p /var/www/certbot
    sudo chown www-data:www-data /var/www/certbot

    # Test Nginx configuration before proceeding
    if ! sudo nginx -t; then
        error "Nginx configuration is invalid. Cannot proceed with SSL setup."
    fi

    # Reload Nginx to apply initial configuration
    sudo systemctl reload nginx || error "Failed to reload Nginx"

    # Check if certificates already exist
    if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]; then
        info "SSL certificates already exist for ${DOMAIN}"

        # Check if they're still valid (not expiring in next 30 days)
        if openssl x509 -in "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" -noout -checkend 2592000 >/dev/null 2>&1; then
            success "Existing SSL certificates are valid"
            return 0
        else
            warning "SSL certificates are expiring soon, renewing..."
        fi
    fi

    # Get SSL certificate
    info "Requesting SSL certificate for ${DOMAIN}..."

    # Use staging environment for testing (comment out for production)
    # local staging_flag="--staging"
    local staging_flag=""

    if sudo certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN} $staging_flag; then
        success "SSL certificates obtained successfully"
    else
        error "Failed to obtain SSL certificates. Check domain DNS and firewall settings."
    fi

    # Setup auto-renewal
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 12 * * * /usr/bin/certbot renew --quiet") | crontab -
        success "SSL auto-renewal configured"
    else
        info "SSL auto-renewal already configured"
    fi

    # Test certificate renewal
    info "Testing certificate renewal..."
    if sudo certbot renew --dry-run >/dev/null 2>&1; then
        success "Certificate renewal test passed"
    else
        warning "Certificate renewal test failed, but certificates are installed"
    fi
}

# Start services
start_services() {
    step "Starting all services..."

    cd ${PROJECT_DIR}/backend

    # Load environment variables
    set -a
    source ${PROJECT_DIR}/.env.production
    set +a

    # Check if Docker Compose file exists
    if [ ! -f "docker-compose.custom-ports.yml" ]; then
        error "Docker Compose file not found: docker-compose.custom-ports.yml"
    fi

    # Start Docker services
    info "Starting Docker services..."
    if docker compose -f docker-compose.custom-ports.yml up -d; then
        success "Docker services started"
    elif docker-compose -f docker-compose.custom-ports.yml up -d; then
        success "Docker services started (using legacy docker-compose)"
    else
        error "Failed to start Docker services"
    fi

    # Wait for services to be healthy
    wait_for_services

    # Check service status
    info "Service status:"
    if command -v docker-compose >/dev/null; then
        docker-compose -f docker-compose.custom-ports.yml ps
    else
        docker compose -f docker-compose.custom-ports.yml ps
    fi

    # Initialize database
    initialize_database

    # Restart Nginx to ensure it picks up the backend
    sudo systemctl restart nginx || error "Failed to restart Nginx"

    success "All services started and initialized"
}

# Create systemd service for auto-start
create_systemd_service() {
    step "Creating systemd service for auto-start..."

    # Determine which docker-compose command to use
    local docker_compose_cmd
    if command -v docker-compose >/dev/null; then
        docker_compose_cmd="/usr/local/bin/docker-compose"
    else
        docker_compose_cmd="/usr/bin/docker compose"
    fi

    sudo tee /etc/systemd/system/lawvriksh.service > /dev/null << EOF
[Unit]
Description=Lawvriksh Application
Requires=docker.service
After=docker.service network.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_DIR}/backend
Environment=PATH=/usr/local/bin:/usr/bin:/bin
ExecStart=${docker_compose_cmd} -f docker-compose.custom-ports.yml up -d
ExecStop=${docker_compose_cmd} -f docker-compose.custom-ports.yml down
ExecReload=${docker_compose_cmd} -f docker-compose.custom-ports.yml restart
TimeoutStartSec=300
TimeoutStopSec=60

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable lawvriksh.service

    success "Systemd service created"
}

# Create backup script
create_backup_script() {
    step "Creating backup script..."

    cat > ${PROJECT_DIR}/backup.sh << 'EOF'
#!/bin/bash

# Lawvriksh Backup Script
BACKUP_DIR="/opt/lawvriksh/backups"
DATE=$(date +%Y%m%d_%H%M%S)
MYSQL_CONTAINER="lawvriksh-mysql"

# Create backup directory
mkdir -p ${BACKUP_DIR}

# Backup MySQL database
echo "Backing up MySQL database..."
docker exec ${MYSQL_CONTAINER} mysqldump -u root -p${MYSQL_ROOT_PASSWORD} ${DB_NAME} > ${BACKUP_DIR}/mysql_backup_${DATE}.sql

# Backup application files
echo "Backing up application files..."
tar -czf ${BACKUP_DIR}/app_backup_${DATE}.tar.gz -C /opt/lawvriksh backend frontend

# Backup Nginx configuration
echo "Backing up Nginx configuration..."
tar -czf ${BACKUP_DIR}/nginx_backup_${DATE}.tar.gz /etc/nginx/sites-available/lawvriksh.com

# Remove old backups (keep last 7 days)
find ${BACKUP_DIR} -name "*.sql" -mtime +7 -delete
find ${BACKUP_DIR} -name "*.tar.gz" -mtime +7 -delete

echo "Backup completed: ${DATE}"
EOF

    chmod +x ${PROJECT_DIR}/backup.sh

    # Add to crontab for daily backups
    (crontab -l 2>/dev/null; echo "0 2 * * * ${PROJECT_DIR}/backup.sh") | crontab -

    success "Backup script created and scheduled"
}

# Test deployment
test_deployment() {
    step "Testing deployment..."

    # Test MySQL connection
    info "Testing MySQL connection on port ${MYSQL_PORT}..."
    if nc -z localhost ${MYSQL_PORT}; then
        success "MySQL is accessible on port ${MYSQL_PORT}"
    else
        error "MySQL is not accessible on port ${MYSQL_PORT}"
    fi

    # Test backend API
    info "Testing backend API on port ${BACKEND_PORT}..."
    if curl -f http://localhost:${BACKEND_PORT}/health > /dev/null 2>&1; then
        success "Backend API is responding on port ${BACKEND_PORT}"
    else
        warning "Backend API is not responding on port ${BACKEND_PORT} (may still be starting)"
    fi

    # Test Nginx
    info "Testing Nginx configuration..."
    if sudo nginx -t; then
        success "Nginx configuration is valid"
    else
        error "Nginx configuration has errors"
    fi

    # Test frontend
    info "Testing frontend..."
    if [ -d "/var/www/${DOMAIN}" ]; then
        success "Frontend files are deployed"
    else
        warning "Frontend files not found"
    fi

    success "Deployment tests completed"
}

# Display final information
display_final_info() {
    log "=============================================================="
    log "Lawvriksh Deployment Completed Successfully!"
    log "=============================================================="
    echo
    success "Domain: https://${DOMAIN}"
    success "API Endpoint: https://${DOMAIN}/api"
    success "MySQL Port: ${MYSQL_PORT}"
    success "Backend Port: ${BACKEND_PORT}"
    echo
    info "Important files and directories:"
    echo "  - Project Directory: ${PROJECT_DIR}"
    echo "  - Environment File: ${PROJECT_DIR}/.env.production"
    echo "  - Backend Code: ${PROJECT_DIR}/backend"
    echo "  - Frontend Code: ${PROJECT_DIR}/frontend"
    echo "  - Logs: ${PROJECT_DIR}/logs"
    echo "  - Backups: ${PROJECT_DIR}/backups"
    echo
    info "Useful commands:"
    echo "  - View logs: docker-compose -f ${PROJECT_DIR}/backend/docker-compose.production.yml logs -f"
    echo "  - Restart services: sudo systemctl restart lawvriksh"
    echo "  - Check status: docker-compose -f ${PROJECT_DIR}/backend/docker-compose.production.yml ps"
    echo "  - Backup: ${PROJECT_DIR}/backup.sh"
    echo
    warning "Next steps:"
    echo "1. Update email configuration in ${PROJECT_DIR}/.env.production"
    echo "2. Test the application: https://${DOMAIN}"
    echo "3. Test the API: https://${DOMAIN}/api/health"
    echo "4. Monitor logs for any issues"
    echo
    log "=============================================================="
}

# Main deployment function
main() {
    log "=============================================================="
    log "Starting Complete Lawvriksh Deployment for Ubuntu 24.04"
    log "=============================================================="
    log "Domain: ${DOMAIN}"
    log "MySQL Port: ${MYSQL_PORT}"
    log "Backend Port: ${BACKEND_PORT}"
    log "Project Directory: ${PROJECT_DIR}"
    log "=============================================================="

    # Check current deployment state
    local current_state=$(get_state)
    if [ "$current_state" != "not_started" ]; then
        warning "Previous deployment detected (state: $current_state)"
        read -p "Do you want to continue from where it left off? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            info "Starting fresh deployment..."
            rm -f "$DEPLOYMENT_STATE_FILE"
        fi
    fi

    # Pre-deployment checks
    save_state "pre_checks"
    check_root
    check_ubuntu_version
    check_system_requirements

    # System setup
    save_state "system_setup"
    update_system
    configure_firewall

    # Install required software
    save_state "software_installation"
    install_docker
    install_docker_compose
    install_nginx
    install_certbot

    # Generate secrets and setup project
    save_state "project_setup"
    generate_secrets
    create_project_structure
    create_environment_file

    # Copy and build application
    save_state "application_setup"
    copy_application_files
    build_frontend

    # Configure services
    save_state "service_configuration"
    create_nginx_config
    create_docker_compose

    # Start services (before SSL to avoid chicken-and-egg problem)
    save_state "service_startup"
    start_services

    # Setup SSL after services are running
    save_state "ssl_setup"
    setup_ssl

    # Create additional scripts and services
    save_state "finalization"
    create_systemd_service
    create_backup_script

    # Test deployment
    save_state "testing"
    test_deployment

    # Mark as completed
    save_state "completed"

    # Display final information
    display_final_info
}

# Handle script arguments
case "${1:-}" in
    --help|-h)
        echo "Lawvriksh Complete Deployment Script for Ubuntu 24.04"
        echo "Usage: $0 [options]"
        echo "Options:"
        echo "  --help, -h    Show this help message"
        echo "  --test        Run deployment tests only"
        echo "  --backup      Create backup only"
        exit 0
        ;;
    --test)
        test_deployment
        exit 0
        ;;
    --backup)
        create_backup_script
        ${PROJECT_DIR}/backup.sh
        exit 0
        ;;
    *)
        main "$@"
        ;;
esac
