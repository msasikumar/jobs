#!/bin/bash

set -euo pipefail

# Configuration
ENVIRONMENT=${1:-production}
IMAGE_TAG=${2:-latest}
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

# Function to get container health status
get_container_health() {
    local container_name=$1
    ssh "${SSH_USER}@${TARGET_SERVER}" "podman inspect ${container_name} --format '{{.State.Health.Status}}' 2>/dev/null || echo 'unknown'"
}

# Function to wait for container to be healthy
wait_for_healthy() {
    local container_name=$1
    local max_attempts=30
    local attempt=1
    
    log "Waiting for container ${container_name} to be healthy..."
    
    while [ $attempt -le $max_attempts ]; do
        local health_status=$(get_container_health "$container_name")
        
        if [ "$health_status" = "healthy" ]; then
            success "Container ${container_name} is healthy"
            return 0
        fi
        
        log "Attempt ${attempt}/${max_attempts}: Container health status is '${health_status}'"
        sleep 10
        ((attempt++))
    done
    
    error "Container ${container_name} failed to become healthy within timeout"
    return 1
}

# Function to perform health check via HTTP
http_health_check() {
    local port=$1
    local max_attempts=10
    local attempt=1
    
    log "Performing HTTP health check on port ${port}..."
    
    while [ $attempt -le $max_attempts ]; do
        if ssh "${SSH_USER}@${TARGET_SERVER}" "curl -f http://localhost:${port}/health >/dev/null 2>&1"; then
            success "HTTP health check passed"
            return 0
        fi
        
        log "Attempt ${attempt}/${max_attempts}: HTTP health check failed"
        sleep 5
        ((attempt++))
    done
    
    error "HTTP health check failed after ${max_attempts} attempts"
    return 1
}

# Function to backup current deployment
backup_current_deployment() {
    log "Creating backup of current deployment..."
    
    # Create backup directory
    ssh "${SSH_USER}@${TARGET_SERVER}" "mkdir -p /opt/backups/jobs-app"
    
    # Backup container data if it exists
    if is_container_running "${CONTAINER_NAME}"; then
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            podman exec ${CONTAINER_NAME} tar -czf /tmp/app-data-backup.tar.gz /app/data 2>/dev/null || true
            podman cp ${CONTAINER_NAME}:/tmp/app-data-backup.tar.gz /opt/backups/jobs-app/data-$(date +%Y%m%d-%H%M%S).tar.gz 2>/dev/null || true
        "
    fi
    
    success "Backup completed"
}

# Function to pull new image
pull_image() {
    log "Pulling new image: ${IMAGE_TAG}"
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman pull ${IMAGE_TAG}
    "
    
    success "Image pulled successfully"
}

# Function to determine current and new colors
determine_colors() {
    if is_container_running "${CONTAINER_NAME}-blue"; then
        CURRENT_COLOR="blue"
        NEW_COLOR="green"
    else
        CURRENT_COLOR="green"
        NEW_COLOR="blue"
    fi
    
    log "Current deployment: ${CURRENT_COLOR}, New deployment: ${NEW_COLOR}"
}

# Function to start new container
start_new_container() {
    local color=$1
    local container_name="${CONTAINER_NAME}-${color}"
    local temp_port=$((HOST_PORT + 1000))
    
    log "Starting new container: ${container_name}"
    
    # Stop and remove existing container if it exists
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman stop ${container_name} 2>/dev/null || true
        podman rm ${container_name} 2>/dev/null || true
    "
    
    # Start new container on temporary port
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman run -d \
            --name ${container_name} \
            --restart unless-stopped \
            -p ${temp_port}:${CONTAINER_PORT} \
            -v /opt/jobs-app/data:/app/data:Z \
            -v /opt/jobs-app/logs:/app/logs:Z \
            --env-file /opt/jobs-app/configs/${ENVIRONMENT}.env \
            --label environment=${ENVIRONMENT} \
            --label version=${IMAGE_TAG} \
            --label deployment-time=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
            ${IMAGE_TAG}
    "
    
    # Wait for container to be healthy
    if ! wait_for_healthy "$container_name"; then
        error "New container failed health check"
        return 1
    fi
    
    # Perform HTTP health check
    if ! http_health_check "$temp_port"; then
        error "New container failed HTTP health check"
        return 1
    fi
    
    success "New container ${container_name} is running and healthy"
}

# Function to switch traffic
switch_traffic() {
    local new_color=$1
    local current_color=$2
    local new_container="${CONTAINER_NAME}-${new_color}"
    local current_container="${CONTAINER_NAME}-${current_color}"
    local temp_port=$((HOST_PORT + 1000))
    
    log "Switching traffic from ${current_color} to ${new_color}"
    
    # Stop current container port mapping
    if is_container_running "$current_container"; then
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            podman stop ${current_container}
            podman rm ${current_container}
        "
    fi
    
    # Start new container on production port
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman stop ${new_container}
        podman rm ${new_container}
        
        podman run -d \
            --name ${new_container} \
            --restart unless-stopped \
            -p ${HOST_PORT}:${CONTAINER_PORT} \
            -v /opt/jobs-app/data:/app/data:Z \
            -v /opt/jobs-app/logs:/app/logs:Z \
            --env-file /opt/jobs-app/configs/${ENVIRONMENT}.env \
            --label environment=${ENVIRONMENT} \
            --label version=${IMAGE_TAG} \
            --label deployment-time=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
            ${IMAGE_TAG}
    "
    
    # Wait for container to be healthy on production port
    if ! wait_for_healthy "$new_container"; then
        error "Container failed health check on production port"
        return 1
    fi
    
    # Perform final HTTP health check
    if ! http_health_check "$HOST_PORT"; then
        error "Final HTTP health check failed"
        return 1
    fi
    
    success "Traffic switched successfully to ${new_color} deployment"
}

# Function to cleanup old deployment
cleanup_old_deployment() {
    local old_color=$1
    local old_container="${CONTAINER_NAME}-${old_color}"
    
    log "Cleaning up old deployment: ${old_color}"
    
    # Keep old container for a few minutes in case of issues
    sleep 60
    
    if is_container_running "$old_container"; then
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            podman stop ${old_container}
            podman rm ${old_container}
        "
    fi
    
    success "Old deployment cleaned up"
}

# Main deployment function
main() {
    log "Starting blue-green deployment for ${ENVIRONMENT} environment"
    log "Image: ${IMAGE_TAG}"
    log "Target server: ${TARGET_SERVER}"
    
    # Validate required variables
    if [[ -z "${TARGET_SERVER}" || -z "${SSH_USER}" || -z "${CONTAINER_NAME}" ]]; then
        error "Missing required environment variables"
        exit 1
    fi
    
    # Create necessary directories on target server
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        mkdir -p /opt/jobs-app/{data,logs,configs}
        mkdir -p /opt/backups/jobs-app
    "
    
    # Copy environment configuration
    scp "${CONFIG_DIR}/${ENVIRONMENT}.env" "${SSH_USER}@${TARGET_SERVER}:/opt/jobs-app/configs/"
    
    # Backup current deployment
    backup_current_deployment
    
    # Pull new image
    pull_image
    
    # Determine deployment colors
    determine_colors
    
    # Start new container
    if ! start_new_container "$NEW_COLOR"; then
        error "Failed to start new container"
        exit 1
    fi
    
    # Switch traffic
    if ! switch_traffic "$NEW_COLOR" "$CURRENT_COLOR"; then
        error "Failed to switch traffic"
        # Rollback logic would go here
        exit 1
    fi
    
    # Cleanup old deployment
    cleanup_old_deployment "$CURRENT_COLOR"
    
    success "Blue-green deployment completed successfully!"
    log "New deployment is running on ${NEW_COLOR} container"
}

# Run main function
main "$@"