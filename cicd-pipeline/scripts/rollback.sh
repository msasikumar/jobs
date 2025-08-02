#!/bin/bash

set -euo pipefail

# Configuration
ENVIRONMENT=${1:-production}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/../configs"

# Load environment-specific configuration
source "${CONFIG_DIR}/${ENVIRONMENT}.env"

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

# Function to check if container is running
is_container_running() {
    local container_name=$1
    ssh "${SSH_USER}@${TARGET_SERVER}" "podman ps --format '{{.Names}}' | grep -q '^${container_name}$'"
}

# Function to get container info
get_container_info() {
    local container_name=$1
    ssh "${SSH_USER}@${TARGET_SERVER}" "podman inspect ${container_name} --format '{{.Config.Labels.version}} {{.Config.Labels.deployment-time}}' 2>/dev/null || echo 'unknown unknown'"
}

# Function to list available containers for rollback
list_rollback_options() {
    log "Checking available rollback options..."
    
    local blue_container="${CONTAINER_NAME}-blue"
    local green_container="${CONTAINER_NAME}-green"
    local current_container=""
    local backup_container=""
    
    # Determine current active container
    if is_container_running "$blue_container"; then
        current_container="blue"
        backup_container="green"
    elif is_container_running "$green_container"; then
        current_container="green"
        backup_container="blue"
    else
        error "No active containers found for rollback"
        return 1
    fi
    
    log "Current active container: ${CONTAINER_NAME}-${current_container}"
    
    # Check if backup container exists (stopped)
    local backup_exists=$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman ps -a --format '{{.Names}}' | grep -q '^${CONTAINER_NAME}-${backup_container}$' && echo 'yes' || echo 'no'")
    
    if [ "$backup_exists" = "yes" ]; then
        local backup_info=$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman inspect ${CONTAINER_NAME}-${backup_container} --format '{{.Config.Labels.version}} {{.Config.Labels.deployment-time}}' 2>/dev/null || echo 'unknown unknown'")
        log "Backup container available: ${CONTAINER_NAME}-${backup_container} (${backup_info})"
        echo "$backup_container"
    else
        warning "No backup container available for immediate rollback"
        echo ""
    fi
}

# Function to rollback to previous container
rollback_to_previous() {
    local backup_color=$1
    local backup_container="${CONTAINER_NAME}-${backup_color}"
    local current_color=""
    local current_container=""
    
    # Determine current container
    if [ "$backup_color" = "blue" ]; then
        current_color="green"
    else
        current_color="blue"
    fi
    current_container="${CONTAINER_NAME}-${current_color}"
    
    log "Rolling back from ${current_color} to ${backup_color}"
    
    # Stop current container
    if is_container_running "$current_container"; then
        log "Stopping current container: ${current_container}"
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            podman stop ${current_container}
            podman rm ${current_container}
        "
    fi
    
    # Start backup container on production port
    log "Starting backup container: ${backup_container}"
    
    # Get the image from the backup container
    local backup_image=$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman inspect ${backup_container} --format '{{.Config.Image}}' 2>/dev/null")
    
    if [ -z "$backup_image" ]; then
        error "Could not determine backup container image"
        return 1
    fi
    
    # Remove the stopped backup container and recreate it on production port
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman rm ${backup_container} 2>/dev/null || true
        
        podman run -d \
            --name ${backup_container} \
            --restart unless-stopped \
            -p ${HOST_PORT}:${CONTAINER_PORT} \
            -v /opt/jobs-app/data:/app/data:Z \
            -v /opt/jobs-app/logs:/app/logs:Z \
            --env-file /opt/jobs-app/configs/${ENVIRONMENT}.env \
            --label environment=${ENVIRONMENT} \
            --label version=${backup_image} \
            --label deployment-time=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
            --label rollback=true \
            ${backup_image}
    "
    
    # Wait for container to be healthy
    local max_attempts=30
    local attempt=1
    
    log "Waiting for rollback container to be healthy..."
    
    while [ $attempt -le $max_attempts ]; do
        local health_status=$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman inspect ${backup_container} --format '{{.State.Health.Status}}' 2>/dev/null || echo 'unknown'")
        
        if [ "$health_status" = "healthy" ]; then
            success "Rollback container is healthy"
            break
        fi
        
        log "Attempt ${attempt}/${max_attempts}: Container health status is '${health_status}'"
        sleep 10
        ((attempt++))
        
        if [ $attempt -gt $max_attempts ]; then
            error "Rollback container failed to become healthy"
            return 1
        fi
    done
    
    # Perform HTTP health check
    local http_attempts=10
    local http_attempt=1
    
    log "Performing HTTP health check..."
    
    while [ $http_attempt -le $http_attempts ]; do
        if ssh "${SSH_USER}@${TARGET_SERVER}" "curl -f http://localhost:${HOST_PORT}/health >/dev/null 2>&1"; then
            success "HTTP health check passed"
            break
        fi
        
        log "Attempt ${http_attempt}/${http_attempts}: HTTP health check failed"
        sleep 5
        ((http_attempt++))
        
        if [ $http_attempt -gt $http_attempts ]; then
            error "HTTP health check failed after rollback"
            return 1
        fi
    done
    
    success "Rollback to ${backup_color} completed successfully"
}

# Function to rollback from backup data
rollback_from_backup() {
    log "Rolling back from backup data..."
    
    # Find latest backup
    local latest_backup=$(ssh "${SSH_USER}@${TARGET_SERVER}" "ls -t /opt/backups/jobs-app/data-*.tar.gz 2>/dev/null | head -1 || echo ''")
    
    if [ -z "$latest_backup" ]; then
        warning "No data backups found"
        return 1
    fi
    
    log "Found backup: ${latest_backup}"
    
    # Stop current containers
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman stop ${CONTAINER_NAME}-blue ${CONTAINER_NAME}-green 2>/dev/null || true
        podman rm ${CONTAINER_NAME}-blue ${CONTAINER_NAME}-green 2>/dev/null || true
    "
    
    # Restore data from backup
    log "Restoring data from backup..."
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        cd /opt/jobs-app
        rm -rf data/*
        tar -xzf ${latest_backup} -C data --strip-components=2 2>/dev/null || true
    "
    
    # Get the last known good image
    local last_good_image=$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman images --format '{{.Repository}}:{{.Tag}}' | grep jobs-app | head -1")
    
    if [ -z "$last_good_image" ]; then
        error "No previous image found for rollback"
        return 1
    fi
    
    log "Using image for rollback: ${last_good_image}"
    
    # Start container with restored data
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman run -d \
            --name ${CONTAINER_NAME}-rollback \
            --restart unless-stopped \
            -p ${HOST_PORT}:${CONTAINER_PORT} \
            -v /opt/jobs-app/data:/app/data:Z \
            -v /opt/jobs-app/logs:/app/logs:Z \
            --env-file /opt/jobs-app/configs/${ENVIRONMENT}.env \
            --label environment=${ENVIRONMENT} \
            --label version=${last_good_image} \
            --label deployment-time=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
            --label rollback=true \
            ${last_good_image}
    "
    
    success "Rollback from backup completed"
}

# Function to create incident report
create_incident_report() {
    local rollback_type=$1
    local report_file="/tmp/rollback-incident-$(date +%Y%m%d-%H%M%S).txt"
    
    log "Creating incident report: ${report_file}"
    
    cat > "$report_file" << EOF
ROLLBACK INCIDENT REPORT
========================

Date: $(date)
Environment: ${ENVIRONMENT}
Rollback Type: ${rollback_type}
Target Server: ${TARGET_SERVER}

Container Status Before Rollback:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman ps -a --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'")

Container Status After Rollback:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'")

System Resources:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "free -h && df -h")

Recent Logs:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "journalctl -u podman --since '10 minutes ago' --no-pager" 2>/dev/null || echo "Could not retrieve system logs")

EOF
    
    success "Incident report created: ${report_file}"
    
    # Send report (implement notification logic here)
    log "Incident report should be reviewed and sent to the development team"
}

# Main rollback function
main() {
    log "Starting rollback process for ${ENVIRONMENT} environment"
    log "Target server: ${TARGET_SERVER}"
    
    # Validate required variables
    if [[ -z "${TARGET_SERVER}" || -z "${SSH_USER}" || -z "${CONTAINER_NAME}" ]]; then
        error "Missing required environment variables"
        exit 1
    fi
    
    # Check rollback options
    local backup_color=$(list_rollback_options)
    
    if [ -n "$backup_color" ]; then
        log "Attempting rollback to previous container..."
        if rollback_to_previous "$backup_color"; then
            success "Rollback completed successfully using previous container"
            create_incident_report "container-rollback"
            exit 0
        else
            warning "Container rollback failed, trying backup data rollback..."
        fi
    fi
    
    # If container rollback failed or not available, try backup rollback
    log "Attempting rollback from backup data..."
    if rollback_from_backup; then
        success "Rollback completed successfully using backup data"
        create_incident_report "backup-rollback"
        exit 0
    else
        error "All rollback methods failed"
        create_incident_report "failed-rollback"
        exit 1
    fi
}

# Handle script arguments
case "${1:-}" in
    "list")
        list_rollback_options
        ;;
    "container")
        backup_color=$(list_rollback_options)
        if [ -n "$backup_color" ]; then
            rollback_to_previous "$backup_color"
        else
            error "No container available for rollback"
            exit 1
        fi
        ;;
    "backup")
        rollback_from_backup
        ;;
    *)
        main "$@"
        ;;
esac