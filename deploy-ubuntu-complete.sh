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
# - Domain: lawvriksh.com (frontend) and lawvriksh.com/api (backend)
# =============================================================================

set -e  # Exit on any error

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

# Check if running as root
check_root() {
    if [[ $EUID -eq 0 ]]; then
        error "This script should not be run as root. Please run as a regular user with sudo privileges."
    fi
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
    sudo apt update && sudo apt upgrade -y
    sudo apt install -y curl wget git unzip software-properties-common \
        apt-transport-https ca-certificates gnupg lsb-release \
        build-essential python3-pip python3-venv nodejs npm \
        ufw fail2ban htop tree
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
    
    # Remove old versions
    sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Add Docker's official GPG key
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Install Docker
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    
    # Add user to docker group
    sudo usermod -aG docker $USER
    
    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker
    
    success "Docker installed successfully"
}

# Install Docker Compose
install_docker_compose() {
    step "Installing Docker Compose..."
    
    # Get latest version
    DOCKER_COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | grep 'tag_name' | cut -d\" -f4)
    sudo curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    sudo chmod +x /usr/local/bin/docker-compose
    
    # Create symlink
    sudo ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose
    
    success "Docker Compose installed"
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

    # Create backend directory
    mkdir -p ${PROJECT_DIR}/backend

    # Copy backend files (exclude Frontend directory)
    rsync -av --exclude='Frontend' --exclude='.git' --exclude='__pycache__' \
          --exclude='*.pyc' --exclude='.env*' --exclude='node_modules' \
          . ${PROJECT_DIR}/backend/

    # Copy frontend files
    if [ -d "Frontend" ]; then
        cp -r Frontend ${PROJECT_DIR}/frontend/
    fi

    success "Application files copied"
}

# Build frontend
build_frontend() {
    step "Building frontend application..."

    if [ -d "${PROJECT_DIR}/frontend" ]; then
        cd ${PROJECT_DIR}/frontend

        # Install dependencies
        npm install

        # Build for production
        npm run build

        # Copy built files to nginx directory
        sudo mkdir -p /var/www/${DOMAIN}
        sudo cp -r dist/* /var/www/${DOMAIN}/
        sudo chown -R www-data:www-data /var/www/${DOMAIN}

        cd - > /dev/null
        success "Frontend built and deployed"
    else
        warning "Frontend directory not found, skipping frontend build"
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

# Create Docker Compose with custom ports
create_docker_compose() {
    step "Creating Docker Compose configuration with custom ports..."

    cat > ${PROJECT_DIR}/backend/docker-compose.production.yml << 'EOF'
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
    cat >> ${PROJECT_DIR}/backend/docker-compose.production.yml << 'EOF'

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

    # Reload Nginx to apply initial configuration
    sudo systemctl reload nginx

    # Get SSL certificate
    info "Requesting SSL certificate for ${DOMAIN}..."
    sudo certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos --email admin@${DOMAIN}

    # Setup auto-renewal
    echo "0 12 * * * /usr/bin/certbot renew --quiet" | sudo crontab -

    success "SSL certificates configured"
}

# Start services
start_services() {
    step "Starting all services..."

    cd ${PROJECT_DIR}/backend

    # Load environment variables
    set -a
    source ${PROJECT_DIR}/.env.production
    set +a

    # Start Docker services
    docker-compose -f docker-compose.production.yml up -d

    # Wait for services to be healthy
    info "Waiting for services to be healthy..."
    sleep 30

    # Check service status
    docker-compose -f docker-compose.production.yml ps

    # Restart Nginx to ensure it picks up the backend
    sudo systemctl restart nginx

    success "All services started"
}

# Create systemd service for auto-start
create_systemd_service() {
    step "Creating systemd service for auto-start..."

    sudo tee /etc/systemd/system/lawvriksh.service > /dev/null << EOF
[Unit]
Description=Lawvriksh Application
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PROJECT_DIR}/backend
ExecStart=/usr/local/bin/docker-compose -f docker-compose.production.yml up -d
ExecStop=/usr/local/bin/docker-compose -f docker-compose.production.yml down
TimeoutStartSec=0

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

    # Pre-deployment checks
    check_root
    check_ubuntu_version

    # System setup
    update_system
    configure_firewall

    # Install required software
    install_docker
    install_docker_compose
    install_nginx
    install_certbot

    # Generate secrets and setup project
    generate_secrets
    create_project_structure
    create_environment_file

    # Copy and build application
    copy_application_files
    build_frontend

    # Configure services
    create_nginx_config
    create_docker_compose

    # Setup SSL and start services
    setup_ssl
    start_services

    # Create additional scripts and services
    create_systemd_service
    create_backup_script

    # Test deployment
    test_deployment

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
