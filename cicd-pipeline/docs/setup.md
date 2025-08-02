# CI/CD Pipeline Setup Guide

This guide provides step-by-step instructions for setting up the comprehensive CI/CD pipeline for the Jobs application.

## Prerequisites

### System Requirements

- **Target Server**: Unix server at 192.168.68.89
- **Container Runtime**: Podman installed and configured
- **SSH Access**: SSH key-based authentication configured
- **Git**: Access to the source repository (https://github.com/msasikumar/jobs.git)

### Required Software

#### On the Target Server (192.168.68.89)

```bash
# Install Podman
sudo dnf install -y podman podman-compose

# Install monitoring tools
sudo dnf install -y curl wget jq bc

# Install Node.js (for health checks)
curl -fsSL https://rpm.nodesource.com/setup_18.x | sudo bash -
sudo dnf install -y nodejs

# Create deployment user
sudo useradd -m -s /bin/bash deploy
sudo usermod -aG wheel deploy

# Create application directories
sudo mkdir -p /opt/jobs-app/{data,logs,configs,backups}
sudo chown -R deploy:deploy /opt/jobs-app
```

#### On the CI/CD Server (GitHub Actions Runner or local)

```bash
# Install required tools
sudo apt-get update
sudo apt-get install -y curl wget jq bc ssh-client

# Install Trivy for security scanning
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
```

## Setup Steps

### 1. SSH Configuration

#### Generate SSH Key Pair

```bash
# Generate SSH key for deployment
ssh-keygen -t ed25519 -C "deployment-key" -f ~/.ssh/deploy_key

# Copy public key to target server
ssh-copy-id -i ~/.ssh/deploy_key.pub deploy@192.168.68.89

# Test SSH connection
ssh -i ~/.ssh/deploy_key deploy@192.168.68.89 "echo 'SSH connection successful'"
```

#### Configure SSH Config

Create `~/.ssh/config`:

```
Host jobs-server
    HostName 192.168.68.89
    User deploy
    IdentityFile ~/.ssh/deploy_key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
```

### 2. GitHub Repository Setup

#### Fork the Repository

1. Fork https://github.com/msasikumar/jobs.git to your organization
2. Clone the forked repository
3. Copy the CI/CD pipeline files to the repository root

```bash
git clone https://github.com/YOUR_ORG/jobs.git
cd jobs

# Copy CI/CD pipeline files
cp -r /path/to/cicd-pipeline/.github .
cp -r /path/to/cicd-pipeline/docker .
cp -r /path/to/cicd-pipeline/scripts .
cp -r /path/to/cicd-pipeline/configs .
cp -r /path/to/cicd-pipeline/security .

# Commit and push
git add .
git commit -m "Add CI/CD pipeline configuration"
git push origin main
```

#### Configure GitHub Secrets

Navigate to your repository settings and add the following secrets:

```
# SSH Configuration
SSH_PRIVATE_KEY=<contents of ~/.ssh/deploy_key>
SSH_USER=deploy

# Container Registry (if using private registry)
REGISTRY_USERNAME=<your_username>
REGISTRY_PASSWORD=<your_token>

# Notification Configuration (optional)
SLACK_WEBHOOK_URL=<your_slack_webhook>
PAGERDUTY_SERVICE_KEY=<your_pagerduty_key>

# Database Credentials (for production)
DB_PASSWORD=<secure_production_password>
REDIS_PASSWORD=<secure_redis_password>

# Application Secrets
JWT_SECRET=<your_jwt_secret>
SESSION_SECRET=<your_session_secret>
ENCRYPTION_KEY=<your_encryption_key>
```

### 3. Target Server Configuration

#### Create Environment Files

```bash
# SSH to target server
ssh deploy@192.168.68.89

# Create configuration directory
mkdir -p /opt/jobs-app/configs

# Copy environment files (adjust values as needed)
# These files should be created based on the templates in configs/
```

#### Configure Podman

```bash
# Enable Podman socket (for monitoring)
systemctl --user enable --now podman.socket

# Configure Podman for rootless operation
echo 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"' >> ~/.bashrc
source ~/.bashrc

# Test Podman
podman run --rm hello-world
```

#### Setup Log Rotation

Create `/etc/logrotate.d/jobs-app`:

```
/opt/jobs-app/logs/*.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 644 deploy deploy
    postrotate
        # Restart containers to reopen log files
        /usr/bin/podman kill -s USR1 $(podman ps -q --filter label=app=jobs) 2>/dev/null || true
    endscript
}
```

### 4. Monitoring Setup

#### Deploy Monitoring Stack

```bash
# SSH to target server
ssh deploy@192.168.68.89

# Create monitoring directory
mkdir -p /opt/monitoring
cd /opt/monitoring

# Copy monitoring configuration
# (Copy files from cicd-pipeline/monitoring/)

# Start monitoring stack
podman-compose up -d

# Verify services
podman ps
curl http://localhost:9090  # Prometheus
curl http://localhost:3001  # Grafana
```

#### Configure Grafana

1. Access Grafana at http://192.168.68.89:3001
2. Login with admin/admin123
3. Import dashboards from `monitoring/grafana/dashboards/`
4. Configure data sources:
   - Prometheus: http://prometheus:9090
   - Loki: http://loki:3100

### 5. Security Configuration

#### Setup Security Scanning

```bash
# Install Trivy on target server
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin

# Test security scanning
cd /path/to/jobs/repository
./security/security-scan.sh filesystem .
```

#### Configure Firewall

```bash
# Configure firewall rules
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --permanent --add-port=8080/tcp
sudo firewall-cmd --permanent --add-port=3000/tcp
sudo firewall-cmd --permanent --add-port=9090/tcp
sudo firewall-cmd --permanent --add-port=3001/tcp
sudo firewall-cmd --reload
```

### 6. Backup Configuration

#### Setup Automated Backups

```bash
# Create backup cron job
crontab -e

# Add the following lines:
# Daily backup at 2 AM
0 2 * * * /opt/jobs-app/scripts/backup.sh production full

# Weekly cleanup
0 3 * * 0 find /opt/backups -type f -mtime +30 -delete
```

#### Test Backup System

```bash
# Test backup script
./scripts/backup.sh production data
./scripts/backup.sh production config

# Verify backups
ls -la /opt/backups/jobs-app/
```

### 7. Testing the Pipeline

#### Test Deployment Scripts

```bash
# Test health check
./scripts/health-check.sh production

# Test backup
./scripts/backup.sh production data

# Test deployment (with a test image)
./scripts/deploy-blue-green.sh production nginx:latest
```

#### Trigger CI/CD Pipeline

1. Make a small change to the repository
2. Commit and push to the `develop` branch
3. Verify the staging deployment
4. Create a pull request to `main`
5. Merge to trigger production deployment

### 8. Verification

#### Check Pipeline Status

1. **GitHub Actions**: Verify workflows are running successfully
2. **Monitoring**: Check Grafana dashboards for metrics
3. **Logs**: Review application and system logs
4. **Health Checks**: Verify all health endpoints are responding

#### Verify Deployments

```bash
# Check running containers
podman ps

# Check application health
curl http://192.168.68.89/health
curl http://192.168.68.89:8080/health

# Check monitoring
curl http://192.168.68.89:9090/targets
curl http://192.168.68.89:3001/api/health
```

## Troubleshooting

### Common Issues

#### SSH Connection Issues

```bash
# Test SSH connection
ssh -vvv deploy@192.168.68.89

# Check SSH key permissions
chmod 600 ~/.ssh/deploy_key
chmod 644 ~/.ssh/deploy_key.pub
```

#### Container Issues

```bash
# Check container logs
podman logs jobs-app-production

# Check container status
podman inspect jobs-app-production

# Restart container
podman restart jobs-app-production
```

#### Permission Issues

```bash
# Fix ownership
sudo chown -R deploy:deploy /opt/jobs-app

# Fix SELinux contexts (if applicable)
sudo setsebool -P container_manage_cgroup on
```

### Getting Help

- Check the [troubleshooting guide](troubleshooting.md)
- Review container logs: `podman logs <container_name>`
- Check system logs: `journalctl -u podman`
- Monitor resource usage: `htop`, `df -h`, `free -h`

## Next Steps

1. Review the [configuration guide](configuration.md)
2. Set up [monitoring and alerting](monitoring.md)
3. Configure [backup and recovery](backup-recovery.md)
4. Review [security best practices](security.md)

## Support

For issues and questions:
- Create an issue in the repository
- Contact the DevOps team
- Review the documentation in the `docs/` directory