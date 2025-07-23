# Lawvriksh Complete Deployment Guide

## Overview

This deployment package provides a complete, production-ready setup for the Lawvriksh application on Ubuntu 24.04 with Docker. The deployment includes:

- **Frontend**: React/Vue application served by Nginx at `lawvriksh.com`
- **Backend**: FastAPI application accessible at `lawvriksh.com/api`
- **Database**: MySQL on custom port 3307 (syncable locally)
- **SSL**: Automatic SSL certificates with Let's Encrypt
- **Monitoring**: Health checks and logging
- **Backup**: Automated backup system

## Architecture

```
Internet → Nginx (Port 80/443) → Frontend (Static Files)
                                → Backend API (Port 8001)
                                
Backend → MySQL (Port 3307)
        → Redis (Port 6379)
        → RabbitMQ (Port 5672)
```

## Custom Ports

- **MySQL**: Port 3307 (instead of default 3306) - allows local sync
- **Backend**: Port 8001 (instead of default 8000) - custom configuration
- **Frontend**: Served by Nginx on ports 80/443

## Files Included

### Deployment Scripts
- `deploy-ubuntu-complete.sh` - Complete deployment script
- `quick-setup.sh` - Quick setup after deployment
- `test-deployment.sh` - Comprehensive testing script

### Docker Configuration
- `docker-compose.custom-ports.yml` - Docker Compose with custom ports
- `Dockerfile.frontend` - Frontend Docker configuration
- `nginx-frontend.conf` - Nginx config for frontend container

### Nginx Configuration
- `nginx-lawvriksh.conf` - Main Nginx configuration for production

### Environment Configuration
- `.env.production.template` - Environment variables template

## Quick Start

### 1. Run Complete Deployment

```bash
# Make scripts executable
chmod +x deploy-ubuntu-complete.sh
chmod +x quick-setup.sh
chmod +x test-deployment.sh

# Run complete deployment (as non-root user with sudo)
./deploy-ubuntu-complete.sh
```

### 2. Quick Setup (Alternative)

If you prefer step-by-step setup:

```bash
# Generate environment and start services
./quick-setup.sh

# Or run individual components
./quick-setup.sh --env      # Generate environment file
./quick-setup.sh --services # Start Docker services
./quick-setup.sh --frontend # Build frontend
./quick-setup.sh --nginx    # Setup Nginx
./quick-setup.sh --ssl      # Setup SSL certificates
```

### 3. Test Deployment

```bash
# Run all tests
./test-deployment.sh

# Run specific tests
./test-deployment.sh --mysql     # Test MySQL
./test-deployment.sh --backend   # Test backend API
./test-deployment.sh --frontend  # Test frontend
./test-deployment.sh --ssl       # Test SSL certificates
./test-deployment.sh --domain    # Test domain access
```

## Manual Setup Steps

### 1. Prerequisites

- Ubuntu 24.04 LTS
- Non-root user with sudo privileges
- Domain pointing to server IP
- Ports 80, 443, 3307, 8001 open

### 2. Environment Configuration

```bash
# Copy and edit environment file
cp .env.production.template /opt/lawvriksh/.env.production
nano /opt/lawvriksh/.env.production

# Update these critical settings:
# - SMTP_HOST, SMTP_USER, SMTP_PASSWORD (email configuration)
# - All passwords (auto-generated if using scripts)
```

### 3. Start Services

```bash
cd /opt/lawvriksh/backend
docker-compose -f docker-compose.custom-ports.yml up -d
```

### 4. Setup Nginx

```bash
# Copy configuration
sudo cp nginx-lawvriksh.conf /etc/nginx/sites-available/lawvriksh.com
sudo ln -s /etc/nginx/sites-available/lawvriksh.com /etc/nginx/sites-enabled/

# Test and restart
sudo nginx -t
sudo systemctl restart nginx
```

### 5. Setup SSL

```bash
# Install Certbot
sudo apt install certbot python3-certbot-nginx

# Get certificates
sudo certbot --nginx -d lawvriksh.com -d www.lawvriksh.com
```

## Service Management

### Docker Services

```bash
# View status
docker-compose -f /opt/lawvriksh/backend/docker-compose.custom-ports.yml ps

# View logs
docker-compose -f /opt/lawvriksh/backend/docker-compose.custom-ports.yml logs -f

# Restart services
docker-compose -f /opt/lawvriksh/backend/docker-compose.custom-ports.yml restart

# Stop services
docker-compose -f /opt/lawvriksh/backend/docker-compose.custom-ports.yml down

# Start services
docker-compose -f /opt/lawvriksh/backend/docker-compose.custom-ports.yml up -d
```

### Systemd Service

```bash
# Start/stop application
sudo systemctl start lawvriksh
sudo systemctl stop lawvriksh
sudo systemctl restart lawvriksh

# Check status
sudo systemctl status lawvriksh

# Enable auto-start
sudo systemctl enable lawvriksh
```

### Nginx

```bash
# Test configuration
sudo nginx -t

# Restart Nginx
sudo systemctl restart nginx

# Check status
sudo systemctl status nginx
```

## Database Access

### Local MySQL Access (Port 3307)

```bash
# Connect to MySQL
mysql -h 127.0.0.1 -P 3307 -u lawvriksh_user -p lawvriksh_production

# Or using Docker
docker exec -it lawvriksh-mysql mysql -u root -p
```

### Database Backup

```bash
# Manual backup
/opt/lawvriksh/backup.sh

# Automated backups run daily at 2 AM via cron
```

## Monitoring and Logs

### Log Locations

- **Nginx**: `/var/log/nginx/lawvriksh.com.access.log`
- **Backend**: `/opt/lawvriksh/logs/backend/`
- **MySQL**: `/opt/lawvriksh/logs/mysql/`
- **Celery**: `/opt/lawvriksh/logs/celery/`

### Health Checks

```bash
# Backend health
curl http://localhost:8001/health

# Frontend health
curl https://lawvriksh.com

# API health
curl https://lawvriksh.com/api/health

# Database health
nc -z localhost 3307
```

## Troubleshooting

### Common Issues

1. **Services not starting**
   ```bash
   # Check Docker logs
   docker-compose -f /opt/lawvriksh/backend/docker-compose.custom-ports.yml logs
   
   # Check system resources
   df -h
   free -h
   ```

2. **SSL certificate issues**
   ```bash
   # Renew certificates
   sudo certbot renew
   
   # Check certificate status
   sudo certbot certificates
   ```

3. **Database connection issues**
   ```bash
   # Check MySQL container
   docker exec -it lawvriksh-mysql mysqladmin ping
   
   # Check port accessibility
   nc -z localhost 3307
   ```

4. **Frontend not loading**
   ```bash
   # Check Nginx configuration
   sudo nginx -t
   
   # Check frontend files
   ls -la /var/www/lawvriksh.com/
   ```

### Performance Tuning

1. **Increase worker processes**
   - Edit `/opt/lawvriksh/.env.production`
   - Increase `WORKER_PROCESSES` and `CELERY_WORKER_CONCURRENCY`

2. **Database optimization**
   - Monitor slow query log: `/opt/lawvriksh/logs/mysql/slow.log`
   - Adjust `innodb-buffer-pool-size` in Docker Compose

3. **Nginx optimization**
   - Adjust `worker_connections` in Nginx configuration
   - Enable additional caching if needed

## Security

### Firewall Configuration

```bash
# UFW is configured automatically, but you can check:
sudo ufw status

# Allow additional ports if needed
sudo ufw allow 22/tcp  # SSH
sudo ufw allow 80/tcp  # HTTP
sudo ufw allow 443/tcp # HTTPS
```

### SSL Security

- TLS 1.2 and 1.3 enabled
- Strong cipher suites configured
- HSTS headers enabled
- Security headers configured

### Database Security

- MySQL accessible only from localhost
- Strong passwords auto-generated
- Regular backups enabled

## Backup and Recovery

### Automated Backups

- Daily backups at 2 AM
- Retention: 7 days
- Location: `/opt/lawvriksh/backups/`

### Manual Backup

```bash
# Run backup script
/opt/lawvriksh/backup.sh

# Backup specific components
docker exec lawvriksh-mysql mysqldump -u root -p lawvriksh_production > backup.sql
```

### Recovery

```bash
# Restore database
docker exec -i lawvriksh-mysql mysql -u root -p lawvriksh_production < backup.sql

# Restore application files
tar -xzf app_backup_YYYYMMDD_HHMMSS.tar.gz -C /opt/lawvriksh/
```

## Support

For issues or questions:

1. Check logs in `/opt/lawvriksh/logs/`
2. Run diagnostic tests: `./test-deployment.sh`
3. Check service status: `sudo systemctl status lawvriksh`
4. Review this documentation

## Updates

To update the application:

1. Pull new code to `/opt/lawvriksh/backend/`
2. Rebuild containers: `docker-compose build`
3. Restart services: `sudo systemctl restart lawvriksh`
4. Run tests: `./test-deployment.sh`
