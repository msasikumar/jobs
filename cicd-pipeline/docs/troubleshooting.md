# CI/CD Pipeline Troubleshooting Guide

This guide provides solutions to common issues encountered with the CI/CD pipeline for the Jobs application.

## Table of Contents

1. [GitHub Actions Issues](#github-actions-issues)
2. [Deployment Issues](#deployment-issues)
3. [Container Issues](#container-issues)
4. [Monitoring Issues](#monitoring-issues)
5. [Security Scanning Issues](#security-scanning-issues)
6. [Network and Connectivity Issues](#network-and-connectivity-issues)
7. [Performance Issues](#performance-issues)
8. [Backup and Recovery Issues](#backup-and-recovery-issues)

## GitHub Actions Issues

### Workflow Not Triggering

**Symptoms:**
- Push to repository doesn't trigger workflow
- Pull request doesn't start CI/CD pipeline

**Solutions:**

1. **Check workflow file location:**
   ```bash
   # Ensure workflow is in correct location
   ls -la .github/workflows/
   ```

2. **Verify workflow syntax:**
   ```bash
   # Use GitHub CLI to validate
   gh workflow list
   gh workflow view ci-cd.yml
   ```

3. **Check repository permissions:**
   - Ensure Actions are enabled in repository settings
   - Verify branch protection rules don't block workflows

### SSH Connection Failures

**Symptoms:**
- `Permission denied (publickey)` errors
- `Host key verification failed`

**Solutions:**

1. **Verify SSH key configuration:**
   ```bash
   # Test SSH connection
   ssh -i ~/.ssh/deploy_key deploy@192.168.68.89 "echo 'Connection successful'"
   ```

2. **Check GitHub secrets:**
   - Ensure `SSH_PRIVATE_KEY` contains the complete private key
   - Verify `SSH_USER` is set to `deploy`

3. **Update known hosts:**
   ```bash
   ssh-keyscan -H 192.168.68.89 >> ~/.ssh/known_hosts
   ```

### Build Failures

**Symptoms:**
- Docker build fails
- Test failures
- Dependency installation issues

**Solutions:**

1. **Check Dockerfile syntax:**
   ```bash
   # Validate Dockerfile
   docker build --no-cache -t test-image .
   ```

2. **Review build logs:**
   - Check GitHub Actions logs for specific error messages
   - Look for dependency conflicts or missing files

3. **Test locally:**
   ```bash
   # Run tests locally
   npm install
   npm test
   npm run build
   ```

## Deployment Issues

### Blue-Green Deployment Failures

**Symptoms:**
- New container fails to start
- Health checks fail
- Traffic switch unsuccessful

**Solutions:**

1. **Check container logs:**
   ```bash
   # SSH to target server
   ssh deploy@192.168.68.89
   
   # Check container logs
   podman logs jobs-app-blue
   podman logs jobs-app-green
   ```

2. **Verify environment configuration:**
   ```bash
   # Check environment files
   cat /opt/jobs-app/configs/production.env
   
   # Verify file permissions
   ls -la /opt/jobs-app/configs/
   ```

3. **Manual deployment test:**
   ```bash
   # Test deployment script manually
   ./scripts/deploy-blue-green.sh production <image-tag>
   ```

### Rollback Issues

**Symptoms:**
- Rollback script fails
- Previous version not available
- Data inconsistency after rollback

**Solutions:**

1. **Check available containers:**
   ```bash
   # List all containers
   podman ps -a
   
   # Check container images
   podman images
   ```

2. **Verify backup availability:**
   ```bash
   # Check backup files
   ls -la /opt/backups/jobs-app/
   
   # Test backup integrity
   ./scripts/backup.sh production list
   ```

3. **Manual rollback:**
   ```bash
   # Execute rollback manually
   ./scripts/rollback.sh production
   
   # Check specific rollback type
   ./scripts/rollback.sh production container
   ```

## Container Issues

### Container Won't Start

**Symptoms:**
- Container exits immediately
- `podman ps` shows no running containers
- Application not accessible

**Solutions:**

1. **Check container logs:**
   ```bash
   # View container logs
   podman logs <container-name>
   
   # Follow logs in real-time
   podman logs -f <container-name>
   ```

2. **Verify image integrity:**
   ```bash
   # Check image
   podman inspect <image-name>
   
   # Test image manually
   podman run -it --rm <image-name> /bin/sh
   ```

3. **Check resource constraints:**
   ```bash
   # Check system resources
   free -h
   df -h
   
   # Check container resource limits
   podman inspect <container-name> | grep -A 10 "Resources"
   ```

### Health Check Failures

**Symptoms:**
- Container shows as unhealthy
- Health endpoint returns errors
- Load balancer removes container from rotation

**Solutions:**

1. **Test health endpoint manually:**
   ```bash
   # Test health endpoint
   curl -v http://localhost:3000/health
   
   # Check from inside container
   podman exec <container-name> curl http://localhost:3000/health
   ```

2. **Review health check configuration:**
   ```bash
   # Check Dockerfile health check
   grep HEALTHCHECK docker/Dockerfile
   
   # Verify health check script
   cat docker/healthcheck.js
   ```

3. **Adjust health check parameters:**
   ```dockerfile
   # In Dockerfile, adjust timing
   HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3
   ```

### Port Binding Issues

**Symptoms:**
- `bind: address already in use` errors
- Application not accessible from outside
- Port conflicts

**Solutions:**

1. **Check port usage:**
   ```bash
   # Check what's using the port
   netstat -tlnp | grep :80
   ss -tlnp | grep :80
   
   # Check podman port mappings
   podman port <container-name>
   ```

2. **Stop conflicting services:**
   ```bash
   # Stop conflicting containers
   podman stop $(podman ps -q --filter "publish=80")
   
   # Kill processes using the port
   sudo fuser -k 80/tcp
   ```

3. **Use alternative ports:**
   ```bash
   # Modify deployment script to use different port
   # Edit configs/production.env
   HOST_PORT=8080
   ```

## Monitoring Issues

### Prometheus Not Scraping Targets

**Symptoms:**
- Targets show as "DOWN" in Prometheus
- No metrics data in Grafana
- Alerts not firing

**Solutions:**

1. **Check Prometheus configuration:**
   ```bash
   # Verify Prometheus config
   curl http://192.168.68.89:9090/api/v1/status/config
   
   # Check targets status
   curl http://192.168.68.89:9090/api/v1/targets
   ```

2. **Verify target accessibility:**
   ```bash
   # Test metrics endpoints
   curl http://192.168.68.89:9090/metrics
   curl http://192.168.68.89:3000/metrics
   ```

3. **Restart monitoring stack:**
   ```bash
   cd /opt/monitoring
   podman-compose down
   podman-compose up -d
   ```

### Grafana Dashboard Issues

**Symptoms:**
- Dashboards show no data
- Connection errors to data sources
- Visualization errors

**Solutions:**

1. **Check data source configuration:**
   ```bash
   # Test Prometheus connection
   curl http://prometheus:9090/api/v1/query?query=up
   
   # Check from Grafana container
   podman exec grafana curl http://prometheus:9090/api/v1/query?query=up
   ```

2. **Verify dashboard queries:**
   - Check PromQL syntax in dashboard panels
   - Verify metric names and labels
   - Test queries in Prometheus UI

3. **Restart Grafana:**
   ```bash
   podman restart grafana
   
   # Check Grafana logs
   podman logs grafana
   ```

### Alert Manager Not Sending Notifications

**Symptoms:**
- Alerts firing but no notifications received
- Email/Slack notifications not working
- Alert routing issues

**Solutions:**

1. **Check AlertManager configuration:**
   ```bash
   # Verify AlertManager config
   curl http://192.168.68.89:9093/api/v1/status
   
   # Check alert routing
   curl http://192.168.68.89:9093/api/v1/alerts
   ```

2. **Test notification channels:**
   ```bash
   # Test SMTP configuration
   telnet smtp.company.com 587
   
   # Test Slack webhook
   curl -X POST -H 'Content-type: application/json' \
        --data '{"text":"Test message"}' \
        YOUR_SLACK_WEBHOOK_URL
   ```

3. **Review AlertManager logs:**
   ```bash
   podman logs alertmanager
   ```

## Security Scanning Issues

### Trivy Scan Failures

**Symptoms:**
- Security scans timeout
- Database update failures
- False positive vulnerabilities

**Solutions:**

1. **Update Trivy database:**
   ```bash
   # Update vulnerability database
   trivy image --download-db-only
   
   # Clear cache and retry
   trivy image --clear-cache
   ```

2. **Configure proxy (if behind firewall):**
   ```bash
   # Set proxy environment variables
   export HTTP_PROXY=http://proxy.company.com:8080
   export HTTPS_PROXY=http://proxy.company.com:8080
   ```

3. **Adjust scan configuration:**
   ```yaml
   # In trivy-config.yaml, adjust timeouts
   timeout: 10m
   skip-update: false
   ```

### Secret Detection False Positives

**Symptoms:**
- Test files flagged as containing secrets
- Configuration templates marked as secrets
- Build failures due to false positives

**Solutions:**

1. **Update ignore patterns:**
   ```yaml
   # In trivy-config.yaml
   secret:
     skip-files:
       - "**/*.test.js"
       - "**/test/**"
       - "**/*.example"
   ```

2. **Use secret scanning exceptions:**
   ```bash
   # Add comments to ignore specific lines
   password = "example_password" # trivy:ignore:generic-api-key
   ```

## Network and Connectivity Issues

### DNS Resolution Problems

**Symptoms:**
- Container can't resolve external hostnames
- Database connection failures
- API calls to external services fail

**Solutions:**

1. **Check DNS configuration:**
   ```bash
   # Test DNS resolution
   nslookup google.com
   dig google.com
   
   # Check from container
   podman exec <container-name> nslookup google.com
   ```

2. **Configure custom DNS:**
   ```bash
   # Add DNS servers to container
   podman run --dns=8.8.8.8 --dns=8.8.4.4 <image>
   ```

3. **Check network configuration:**
   ```bash
   # List podman networks
   podman network ls
   
   # Inspect network
   podman network inspect <network-name>
   ```

### Firewall Issues

**Symptoms:**
- External access blocked
- Inter-container communication fails
- Monitoring endpoints not accessible

**Solutions:**

1. **Check firewall rules:**
   ```bash
   # Check firewall status
   sudo firewall-cmd --list-all
   
   # Check iptables rules
   sudo iptables -L -n
   ```

2. **Open required ports:**
   ```bash
   # Open application ports
   sudo firewall-cmd --permanent --add-port=80/tcp
   sudo firewall-cmd --permanent --add-port=8080/tcp
   sudo firewall-cmd --permanent --add-port=3000/tcp
   sudo firewall-cmd --reload
   ```

3. **Configure SELinux (if applicable):**
   ```bash
   # Check SELinux status
   sestatus
   
   # Set SELinux booleans for containers
   sudo setsebool -P container_manage_cgroup on
   ```

## Performance Issues

### High Resource Usage

**Symptoms:**
- High CPU or memory usage
- Slow response times
- Container restarts due to resource limits

**Solutions:**

1. **Monitor resource usage:**
   ```bash
   # Check system resources
   htop
   free -h
   df -h
   
   # Check container resources
   podman stats
   ```

2. **Adjust resource limits:**
   ```bash
   # Modify container resource limits
   podman run --memory=2g --cpus=1.5 <image>
   ```

3. **Optimize application:**
   - Review application logs for performance issues
   - Check database query performance
   - Optimize container image size

### Slow Deployments

**Symptoms:**
- Deployments take too long
- Image pulls timeout
- Health checks fail due to slow startup

**Solutions:**

1. **Optimize container image:**
   ```dockerfile
   # Use multi-stage builds
   # Minimize layers
   # Use .dockerignore
   ```

2. **Implement image caching:**
   ```bash
   # Pre-pull images
   podman pull <image> &
   
   # Use local registry
   podman tag <image> localhost:5000/<image>
   ```

3. **Adjust timeout values:**
   ```bash
   # Increase health check timeouts
   # Adjust deployment script timeouts
   ```

## Backup and Recovery Issues

### Backup Failures

**Symptoms:**
- Backup scripts fail
- Incomplete backups
- Storage space issues

**Solutions:**

1. **Check disk space:**
   ```bash
   # Check available space
   df -h /opt/backups
   
   # Clean old backups
   find /opt/backups -type f -mtime +30 -delete
   ```

2. **Verify backup script permissions:**
   ```bash
   # Check script permissions
   ls -la scripts/backup.sh
   
   # Fix permissions
   chmod +x scripts/backup.sh
   ```

3. **Test backup manually:**
   ```bash
   # Run backup script manually
   ./scripts/backup.sh production data
   
   # Verify backup integrity
   tar -tzf /opt/backups/jobs-app/data-*.tar.gz
   ```

### Recovery Issues

**Symptoms:**
- Restore process fails
- Data corruption after recovery
- Service unavailable during recovery

**Solutions:**

1. **Verify backup integrity:**
   ```bash
   # Test backup files
   tar -tzf backup-file.tar.gz
   gunzip -t backup-file.tar.gz
   ```

2. **Follow recovery procedures:**
   ```bash
   # Stop services before recovery
   podman stop jobs-app-production
   
   # Restore data
   cd /opt/jobs-app
   tar -xzf /opt/backups/jobs-app/data-latest.tar.gz
   
   # Start services
   podman start jobs-app-production
   ```

## Getting Additional Help

### Log Collection

When reporting issues, collect the following logs:

```bash
# System logs
journalctl -u podman --since "1 hour ago" > system-logs.txt

# Container logs
podman logs jobs-app-production > container-logs.txt

# Application logs
cat /opt/jobs-app/logs/application.log > app-logs.txt

# Monitoring logs
podman logs prometheus > prometheus-logs.txt
podman logs grafana > grafana-logs.txt
```

### Health Check Commands

```bash
# Quick system health check
./scripts/health-check.sh production full

# Check all services
curl http://192.168.68.89/health
curl http://192.168.68.89:9090/-/healthy
curl http://192.168.68.89:3001/api/health
```

### Contact Information

- **DevOps Team**: devops@company.com
- **On-Call Engineer**: oncall@company.com
- **Documentation**: https://wiki.company.com/cicd-pipeline
- **Issue Tracker**: https://github.com/company/jobs/issues

### Emergency Procedures

For critical production issues:

1. **Immediate Response:**
   ```bash
   # Execute emergency rollback
   ./scripts/rollback.sh production
   
   # Check system status
   ./scripts/health-check.sh production
   ```

2. **Escalation:**
   - Contact on-call engineer
   - Create incident ticket
   - Notify stakeholders

3. **Recovery:**
   - Follow incident response procedures
   - Document lessons learned
   - Update runbooks and procedures