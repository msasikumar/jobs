#!/bin/bash

set -euo pipefail

# CI/CD Pipeline Setup Script
# This script automates the initial setup of the CI/CD pipeline

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Configuration
TARGET_SERVER="192.168.68.89"
SSH_USER="deploy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."
    
    local missing_tools=()
    
    # Check required tools
    for tool in ssh scp curl wget jq; do
        if ! command -v "$tool" &> /dev/null; then
            missing_tools+=("$tool")
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        error "Missing required tools: ${missing_tools[*]}"
        error "Please install the missing tools and run this script again"
        exit 1
    fi
    
    success "All prerequisites met"
}

# Function to test SSH connectivity
test_ssh_connection() {
    log "Testing SSH connection to ${TARGET_SERVER}..."
    
    if ssh -o ConnectTimeout=10 -o BatchMode=yes "${SSH_USER}@${TARGET_SERVER}" "echo 'SSH connection successful'" 2>/dev/null; then
        success "SSH connection to ${TARGET_SERVER} successful"
    else
        error "SSH connection to ${TARGET_SERVER} failed"
        error "Please ensure:"
        error "1. SSH key is configured and added to ssh-agent"
        error "2. Public key is added to ${SSH_USER}@${TARGET_SERVER}:~/.ssh/authorized_keys"
        error "3. Target server is accessible"
        exit 1
    fi
}

# Function to setup target server directories
setup_server_directories() {
    log "Setting up directories on target server..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        # Create application directories
        mkdir -p /opt/jobs-app/{data,logs,configs,scripts}
        mkdir -p /opt/backups/jobs-app
        mkdir -p /opt/monitoring
        
        # Set permissions
        chmod 755 /opt/jobs-app
        chmod 755 /opt/backups
        chmod 755 /opt/monitoring
        
        # Create log files
        touch /opt/jobs-app/logs/application.log
        touch /opt/jobs-app/logs/deployment.log
        
        echo 'Server directories created successfully'
    "
    
    success "Server directories setup completed"
}

# Function to copy configuration files
copy_configurations() {
    log "Copying configuration files to target server..."
    
    # Copy environment configurations
    scp "${SCRIPT_DIR}/configs/"*.env "${SSH_USER}@${TARGET_SERVER}:/opt/jobs-app/configs/"
    
    # Copy scripts
    scp "${SCRIPT_DIR}/scripts/"*.sh "${SSH_USER}@${TARGET_SERVER}:/opt/jobs-app/scripts/"
    
    # Copy monitoring configuration
    scp -r "${SCRIPT_DIR}/monitoring/"* "${SSH_USER}@${TARGET_SERVER}:/opt/monitoring/"
    
    # Set script permissions
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        chmod +x /opt/jobs-app/scripts/*.sh
        chmod 644 /opt/jobs-app/configs/*.env
    "
    
    success "Configuration files copied successfully"
}

# Function to install required software on target server
install_server_software() {
    log "Installing required software on target server..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        # Update system
        sudo dnf update -y || sudo apt-get update -y || true
        
        # Install Podman
        if ! command -v podman &> /dev/null; then
            sudo dnf install -y podman podman-compose || sudo apt-get install -y podman podman-compose || true
        fi
        
        # Install monitoring tools
        sudo dnf install -y curl wget jq bc htop || sudo apt-get install -y curl wget jq bc htop || true
        
        # Install Node.js (for health checks)
        if ! command -v node &> /dev/null; then
            curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash - || true
            sudo dnf install -y nodejs || sudo apt-get install -y nodejs || true
        fi
        
        # Install Trivy for security scanning
        if ! command -v trivy &> /dev/null; then
            curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin || true
        fi
        
        echo 'Software installation completed'
    "
    
    success "Server software installation completed"
}

# Function to setup monitoring stack
setup_monitoring() {
    log "Setting up monitoring stack..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        cd /opt/monitoring
        
        # Start monitoring services
        if command -v podman-compose &> /dev/null; then
            podman-compose up -d
        else
            # Fallback to individual container starts
            podman run -d --name prometheus -p 9090:9090 \
                -v /opt/monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro \
                prom/prometheus:latest
            
            podman run -d --name grafana -p 3001:3000 \
                -e GF_SECURITY_ADMIN_PASSWORD=admin123 \
                grafana/grafana:latest
        fi
        
        echo 'Monitoring stack setup completed'
    "
    
    success "Monitoring stack setup completed"
}

# Function to setup log rotation
setup_log_rotation() {
    log "Setting up log rotation..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        # Create logrotate configuration
        sudo tee /etc/logrotate.d/jobs-app > /dev/null << 'EOF'
/opt/jobs-app/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 deploy deploy
    postrotate
        # Send USR1 signal to application to reopen log files
        /usr/bin/podman kill -s USR1 \$(podman ps -q --filter label=app=jobs) 2>/dev/null || true
    endscript
}
EOF
        
        echo 'Log rotation setup completed'
    "
    
    success "Log rotation setup completed"
}

# Function to setup backup cron job
setup_backup_cron() {
    log "Setting up backup cron job..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        # Add backup cron job
        (crontab -l 2>/dev/null || echo '') | grep -v 'backup.sh' | crontab -
        (crontab -l 2>/dev/null; echo '0 2 * * * /opt/jobs-app/scripts/backup.sh production full >> /opt/jobs-app/logs/backup.log 2>&1') | crontab -
        (crontab -l 2>/dev/null; echo '0 3 * * 0 find /opt/backups -type f -mtime +30 -delete') | crontab -
        
        echo 'Backup cron job setup completed'
    "
    
    success "Backup cron job setup completed"
}

# Function to configure firewall
configure_firewall() {
    log "Configuring firewall..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        # Configure firewall (if firewalld is available)
        if command -v firewall-cmd &> /dev/null; then
            sudo firewall-cmd --permanent --add-port=80/tcp || true
            sudo firewall-cmd --permanent --add-port=8080/tcp || true
            sudo firewall-cmd --permanent --add-port=3000/tcp || true
            sudo firewall-cmd --permanent --add-port=9090/tcp || true
            sudo firewall-cmd --permanent --add-port=3001/tcp || true
            sudo firewall-cmd --reload || true
        fi
        
        # Configure UFW (if available)
        if command -v ufw &> /dev/null; then
            sudo ufw allow 80/tcp || true
            sudo ufw allow 8080/tcp || true
            sudo ufw allow 3000/tcp || true
            sudo ufw allow 9090/tcp || true
            sudo ufw allow 3001/tcp || true
        fi
        
        echo 'Firewall configuration completed'
    "
    
    success "Firewall configuration completed"
}

# Function to run initial tests
run_initial_tests() {
    log "Running initial tests..."
    
    # Test health check script
    if ssh "${SSH_USER}@${TARGET_SERVER}" "/opt/jobs-app/scripts/health-check.sh production resources"; then
        success "Health check script test passed"
    else
        warning "Health check script test failed (this is expected if no application is running yet)"
    fi
    
    # Test backup script
    if ssh "${SSH_USER}@${TARGET_SERVER}" "/opt/jobs-app/scripts/backup.sh production config"; then
        success "Backup script test passed"
    else
        warning "Backup script test failed"
    fi
    
    # Test security scan script
    if ssh "${SSH_USER}@${TARGET_SERVER}" "/opt/jobs-app/scripts/../security/security-scan.sh filesystem /opt/jobs-app"; then
        success "Security scan script test passed"
    else
        warning "Security scan script test failed"
    fi
}

# Function to display setup summary
display_summary() {
    log "=== SETUP SUMMARY ==="
    
    cat << EOF

✅ CI/CD Pipeline Setup Completed Successfully!

📋 What was configured:
   • Server directories and permissions
   • Configuration files and scripts
   • Required software (Podman, Node.js, Trivy)
   • Monitoring stack (Prometheus, Grafana)
   • Log rotation
   • Automated backups
   • Firewall rules

🔗 Access Points:
   • Application (when deployed): http://${TARGET_SERVER}
   • Staging: http://${TARGET_SERVER}:8080
   • Prometheus: http://${TARGET_SERVER}:9090
   • Grafana: http://${TARGET_SERVER}:3001 (admin/admin123)

📚 Next Steps:
   1. Configure GitHub repository secrets
   2. Copy CI/CD files to your jobs repository
   3. Push code to trigger first deployment
   4. Review monitoring dashboards
   5. Test deployment and rollback procedures

📖 Documentation:
   • Setup Guide: docs/setup.md
   • Deployment Guide: docs/deployment.md
   • Troubleshooting: docs/troubleshooting.md

🆘 Support:
   • Run health checks: ssh ${SSH_USER}@${TARGET_SERVER} '/opt/jobs-app/scripts/health-check.sh production'
   • View logs: ssh ${SSH_USER}@${TARGET_SERVER} 'tail -f /opt/jobs-app/logs/*.log'
   • Check containers: ssh ${SSH_USER}@${TARGET_SERVER} 'podman ps'

EOF
    
    success "Setup completed! Your CI/CD pipeline is ready to use."
}

# Main setup function
main() {
    log "Starting CI/CD Pipeline Setup"
    log "Target Server: ${TARGET_SERVER}"
    log "SSH User: ${SSH_USER}"
    
    # Run setup steps
    check_prerequisites
    test_ssh_connection
    setup_server_directories
    install_server_software
    copy_configurations
    setup_monitoring
    setup_log_rotation
    setup_backup_cron
    configure_firewall
    run_initial_tests
    display_summary
    
    success "CI/CD Pipeline setup completed successfully!"
}

# Handle script arguments
case "${1:-setup}" in
    "setup")
        main
        ;;
    "test")
        log "Running connectivity tests..."
        check_prerequisites
        test_ssh_connection
        success "Connectivity tests passed"
        ;;
    "clean")
        log "Cleaning up server configuration..."
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            sudo rm -rf /opt/jobs-app /opt/backups /opt/monitoring
            crontab -l | grep -v 'backup.sh' | crontab -
            echo 'Cleanup completed'
        "
        success "Server cleanup completed"
        ;;
    "help")
        cat << EOF
CI/CD Pipeline Setup Script

Usage: $0 [command]

Commands:
  setup    - Run full pipeline setup (default)
  test     - Test connectivity and prerequisites
  clean    - Clean up server configuration
  help     - Show this help message

Examples:
  $0                    # Run full setup
  $0 setup              # Run full setup
  $0 test               # Test connectivity
  $0 clean              # Clean up server

EOF
        ;;
    *)
        error "Unknown command: $1"
        error "Use '$0 help' for usage information"
        exit 1
        ;;
esac