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

# Configuration
BACKUP_DIR="/opt/backups/jobs-app"
RETENTION_DAYS=30
MAX_BACKUPS=50

# Function to create backup directory structure
create_backup_structure() {
    log "Creating backup directory structure..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        mkdir -p ${BACKUP_DIR}/{data,configs,logs,database,full}
        chmod 755 ${BACKUP_DIR}
        chmod 755 ${BACKUP_DIR}/{data,configs,logs,database,full}
    "
    
    success "Backup directory structure created"
}

# Function to backup application data
backup_application_data() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/data/app-data-${timestamp}.tar.gz"
    
    log "Backing up application data..."
    
    # Check if any container is running
    local running_container=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman ps --format '{{.Names}}' | grep '${CONTAINER_NAME}' | head -1 || echo ''
    ")
    
    if [ -n "$running_container" ]; then
        # Backup from running container
        log "Backing up data from running container: ${running_container}"
        
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            # Create temporary backup inside container
            podman exec ${running_container} tar -czf /tmp/app-data-backup.tar.gz -C /app data logs 2>/dev/null || true
            
            # Copy backup from container to host
            podman cp ${running_container}:/tmp/app-data-backup.tar.gz ${backup_file}
            
            # Cleanup temporary file
            podman exec ${running_container} rm -f /tmp/app-data-backup.tar.gz
        "
    else
        # Backup from host volumes
        log "No running container found, backing up from host volumes"
        
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            if [ -d /opt/jobs-app/data ] || [ -d /opt/jobs-app/logs ]; then
                cd /opt/jobs-app
                tar -czf ${backup_file} data logs 2>/dev/null || true
            else
                echo 'No data directories found to backup' > ${backup_file}.log
            fi
        "
    fi
    
    # Verify backup was created
    local backup_size=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        if [ -f ${backup_file} ]; then
            ls -lh ${backup_file} | awk '{print \$5}'
        else
            echo '0'
        fi
    ")
    
    if [ "$backup_size" != "0" ]; then
        success "Application data backup created: ${backup_file} (${backup_size})"
        echo "$backup_file"
    else
        warning "Application data backup is empty or failed"
        return 1
    fi
}

# Function to backup configuration files
backup_configurations() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/configs/configs-${timestamp}.tar.gz"
    
    log "Backing up configuration files..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        cd /opt/jobs-app
        if [ -d configs ]; then
            tar -czf ${backup_file} configs
        else
            mkdir -p configs
            echo 'No configurations found' > configs/empty.txt
            tar -czf ${backup_file} configs
            rm configs/empty.txt
        fi
    "
    
    success "Configuration backup created: ${backup_file}"
    echo "$backup_file"
}

# Function to backup container images
backup_container_images() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/full/images-${timestamp}.tar"
    
    log "Backing up container images..."
    
    # Get list of jobs-app related images
    local images=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman images --format '{{.Repository}}:{{.Tag}}' | grep -E '(jobs-app|jobs)' || echo ''
    ")
    
    if [ -n "$images" ]; then
        log "Found images to backup: ${images}"
        
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            podman save -o ${backup_file} ${images}
            gzip ${backup_file}
        "
        
        success "Container images backup created: ${backup_file}.gz"
        echo "${backup_file}.gz"
    else
        warning "No container images found to backup"
        return 1
    fi
}

# Function to backup database (if applicable)
backup_database() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/database/db-${timestamp}.sql.gz"
    
    log "Checking for database to backup..."
    
    # Check if there's a database container or connection
    local db_container=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman ps --format '{{.Names}}' | grep -E '(postgres|mysql|mongo|redis)' | head -1 || echo ''
    ")
    
    if [ -n "$db_container" ]; then
        log "Found database container: ${db_container}"
        
        # Determine database type and backup accordingly
        if echo "$db_container" | grep -q postgres; then
            ssh "${SSH_USER}@${TARGET_SERVER}" "
                podman exec ${db_container} pg_dumpall -U postgres | gzip > ${backup_file}
            "
        elif echo "$db_container" | grep -q mysql; then
            ssh "${SSH_USER}@${TARGET_SERVER}" "
                podman exec ${db_container} mysqldump --all-databases -u root | gzip > ${backup_file}
            "
        elif echo "$db_container" | grep -q mongo; then
            ssh "${SSH_USER}@${TARGET_SERVER}" "
                podman exec ${db_container} mongodump --archive | gzip > ${backup_file}
            "
        else
            warning "Unknown database type, skipping database backup"
            return 1
        fi
        
        success "Database backup created: ${backup_file}"
        echo "$backup_file"
    else
        log "No database container found, skipping database backup"
        return 0
    fi
}

# Function to create full system backup
create_full_backup() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_file="${BACKUP_DIR}/full/full-backup-${timestamp}.tar.gz"
    
    log "Creating full system backup..."
    
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        cd /opt
        tar -czf ${backup_file} \
            --exclude='backups' \
            --exclude='*.log' \
            --exclude='tmp' \
            jobs-app
    "
    
    success "Full system backup created: ${backup_file}"
    echo "$backup_file"
}

# Function to cleanup old backups
cleanup_old_backups() {
    log "Cleaning up old backups (retention: ${RETENTION_DAYS} days, max: ${MAX_BACKUPS} files)..."
    
    # Cleanup by age
    ssh "${SSH_USER}@${TARGET_SERVER}" "
        find ${BACKUP_DIR} -type f -name '*.tar.gz' -o -name '*.tar' -o -name '*.sql.gz' | \
        while read file; do
            if [ \$(find \"\$file\" -mtime +${RETENTION_DAYS} | wc -l) -gt 0 ]; then
                echo \"Removing old backup: \$file\"
                rm -f \"\$file\"
            fi
        done
    "
    
    # Cleanup by count (keep only latest MAX_BACKUPS files in each directory)
    for subdir in data configs logs database full; do
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            if [ -d ${BACKUP_DIR}/${subdir} ]; then
                cd ${BACKUP_DIR}/${subdir}
                ls -t *.tar.gz *.tar *.sql.gz 2>/dev/null | tail -n +\$((${MAX_BACKUPS} + 1)) | xargs -r rm -f
            fi
        "
    done
    
    success "Old backups cleaned up"
}

# Function to verify backup integrity
verify_backup_integrity() {
    local backup_file=$1
    
    log "Verifying backup integrity: $(basename $backup_file)"
    
    local result=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        if [[ $backup_file == *.tar.gz ]]; then
            gunzip -t $backup_file 2>/dev/null && echo 'valid' || echo 'invalid'
        elif [[ $backup_file == *.tar ]]; then
            tar -tf $backup_file >/dev/null 2>&1 && echo 'valid' || echo 'invalid'
        else
            echo 'unknown'
        fi
    ")
    
    if [ "$result" = "valid" ]; then
        success "Backup integrity verified"
        return 0
    else
        error "Backup integrity check failed"
        return 1
    fi
}

# Function to generate backup report
generate_backup_report() {
    local report_file="/tmp/backup-report-$(date +%Y%m%d-%H%M%S).txt"
    
    log "Generating backup report..."
    
    cat > "$report_file" << EOF
BACKUP REPORT
=============

Date: $(date)
Environment: ${ENVIRONMENT}
Target Server: ${TARGET_SERVER}

Backup Directory: ${BACKUP_DIR}

Backup Summary:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "
    echo 'Data Backups:'
    ls -lh ${BACKUP_DIR}/data/ 2>/dev/null | tail -n +2 || echo 'None'
    echo
    echo 'Config Backups:'
    ls -lh ${BACKUP_DIR}/configs/ 2>/dev/null | tail -n +2 || echo 'None'
    echo
    echo 'Database Backups:'
    ls -lh ${BACKUP_DIR}/database/ 2>/dev/null | tail -n +2 || echo 'None'
    echo
    echo 'Full Backups:'
    ls -lh ${BACKUP_DIR}/full/ 2>/dev/null | tail -n +2 || echo 'None'
")

Disk Usage:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "df -h ${BACKUP_DIR}")

Total Backup Size:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "du -sh ${BACKUP_DIR}")

EOF
    
    success "Backup report generated: ${report_file}"
    cat "$report_file"
}

# Main backup function
main() {
    local backup_type=${2:-"full"}
    
    log "Starting backup process for ${ENVIRONMENT} environment"
    log "Backup type: ${backup_type}"
    log "Target server: ${TARGET_SERVER}"
    
    # Validate required variables
    if [[ -z "${TARGET_SERVER}" || -z "${SSH_USER}" ]]; then
        error "Missing required environment variables"
        exit 1
    fi
    
    # Create backup directory structure
    create_backup_structure
    
    local backup_files=()
    
    case "$backup_type" in
        "data")
            if backup_file=$(backup_application_data); then
                backup_files+=("$backup_file")
            fi
            ;;
        "config")
            if backup_file=$(backup_configurations); then
                backup_files+=("$backup_file")
            fi
            ;;
        "database")
            if backup_file=$(backup_database); then
                backup_files+=("$backup_file")
            fi
            ;;
        "images")
            if backup_file=$(backup_container_images); then
                backup_files+=("$backup_file")
            fi
            ;;
        "full")
            # Backup everything
            if backup_file=$(backup_application_data); then
                backup_files+=("$backup_file")
            fi
            if backup_file=$(backup_configurations); then
                backup_files+=("$backup_file")
            fi
            if backup_file=$(backup_database); then
                backup_files+=("$backup_file")
            fi
            if backup_file=$(backup_container_images); then
                backup_files+=("$backup_file")
            fi
            if backup_file=$(create_full_backup); then
                backup_files+=("$backup_file")
            fi
            ;;
        *)
            error "Unknown backup type: ${backup_type}"
            error "Available types: data, config, database, images, full"
            exit 1
            ;;
    esac
    
    # Verify backup integrity
    for backup_file in "${backup_files[@]}"; do
        if ! verify_backup_integrity "$backup_file"; then
            warning "Backup verification failed for: $backup_file"
        fi
    done
    
    # Cleanup old backups
    cleanup_old_backups
    
    # Generate report
    generate_backup_report
    
    success "Backup process completed successfully!"
    log "Created ${#backup_files[@]} backup file(s)"
}

# Handle script arguments
case "${2:-full}" in
    "list")
        ssh "${SSH_USER}@${TARGET_SERVER}" "
            echo 'Available backups:'
            find ${BACKUP_DIR} -type f -name '*.tar.gz' -o -name '*.tar' -o -name '*.sql.gz' | sort
        "
        ;;
    "restore")
        # This would be implemented as a separate restore script
        log "Restore functionality should be implemented in a separate restore.sh script"
        ;;
    *)
        main "$@"
        ;;
esac