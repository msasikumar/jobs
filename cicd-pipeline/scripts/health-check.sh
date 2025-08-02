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

# Health check configuration
MAX_RESPONSE_TIME=5000  # milliseconds
MIN_SUCCESS_RATE=95     # percentage
HEALTH_ENDPOINT="/health"
METRICS_ENDPOINT="/metrics"

# Function to check container health
check_container_health() {
    local container_name=$1
    
    log "Checking container health: ${container_name}"
    
    # Check if container is running
    local container_status=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman ps --filter name=${container_name} --format '{{.Status}}' 2>/dev/null || echo 'not found'
    ")
    
    if [[ "$container_status" == *"Up"* ]]; then
        success "Container ${container_name} is running"
    else
        error "Container ${container_name} is not running: ${container_status}"
        return 1
    fi
    
    # Check container health status
    local health_status=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman inspect ${container_name} --format '{{.State.Health.Status}}' 2>/dev/null || echo 'no-healthcheck'
    ")
    
    case "$health_status" in
        "healthy")
            success "Container health check: HEALTHY"
            ;;
        "unhealthy")
            error "Container health check: UNHEALTHY"
            return 1
            ;;
        "starting")
            warning "Container health check: STARTING"
            ;;
        "no-healthcheck")
            warning "Container has no health check configured"
            ;;
        *)
            warning "Container health check: UNKNOWN (${health_status})"
            ;;
    esac
    
    return 0
}

# Function to check HTTP endpoint health
check_http_health() {
    local port=${1:-$HOST_PORT}
    local endpoint=${2:-$HEALTH_ENDPOINT}
    
    log "Checking HTTP health endpoint: http://${TARGET_SERVER}:${port}${endpoint}"
    
    # Perform HTTP health check with detailed metrics
    local response=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        curl -s -w '%{http_code}|%{time_total}|%{time_connect}|%{time_starttransfer}' \
             -o /tmp/health_response.json \
             --max-time 10 \
             http://localhost:${port}${endpoint} 2>/dev/null || echo '000|0|0|0'
    ")
    
    IFS='|' read -r http_code total_time connect_time transfer_time <<< "$response"
    
    # Convert times to milliseconds
    total_time_ms=$(echo "$total_time * 1000" | bc -l 2>/dev/null | cut -d. -f1)
    connect_time_ms=$(echo "$connect_time * 1000" | bc -l 2>/dev/null | cut -d. -f1)
    transfer_time_ms=$(echo "$transfer_time * 1000" | bc -l 2>/dev/null | cut -d. -f1)
    
    log "HTTP Response: ${http_code}, Total Time: ${total_time_ms}ms, Connect: ${connect_time_ms}ms, Transfer: ${transfer_time_ms}ms"
    
    # Check HTTP status code
    if [ "$http_code" = "200" ]; then
        success "HTTP health check: PASSED (${http_code})"
    elif [ "$http_code" = "000" ]; then
        error "HTTP health check: FAILED (Connection failed)"
        return 1
    else
        error "HTTP health check: FAILED (${http_code})"
        return 1
    fi
    
    # Check response time
    if [ "$total_time_ms" -gt "$MAX_RESPONSE_TIME" ]; then
        warning "Response time ${total_time_ms}ms exceeds threshold ${MAX_RESPONSE_TIME}ms"
    else
        success "Response time ${total_time_ms}ms is within acceptable range"
    fi
    
    # Parse health response if available
    local health_response=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        cat /tmp/health_response.json 2>/dev/null || echo '{}'
    ")
    
    log "Health response: ${health_response}"
    
    return 0
}

# Function to check application metrics
check_application_metrics() {
    local port=${1:-$HOST_PORT}
    
    log "Checking application metrics..."
    
    # Try to get metrics endpoint
    local metrics_available=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        curl -s --max-time 5 http://localhost:${port}${METRICS_ENDPOINT} >/dev/null 2>&1 && echo 'yes' || echo 'no'
    ")
    
    if [ "$metrics_available" = "yes" ]; then
        success "Metrics endpoint is accessible"
        
        # Get basic metrics
        local metrics=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
            curl -s --max-time 5 http://localhost:${port}${METRICS_ENDPOINT} | head -20
        ")
        
        log "Sample metrics:"
        echo "$metrics" | while read -r line; do
            log "  $line"
        done
    else
        warning "Metrics endpoint not available or not configured"
    fi
}

# Function to check system resources
check_system_resources() {
    log "Checking system resources on ${TARGET_SERVER}..."
    
    # Get system resource usage
    local resources=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        echo 'CPU Usage:'
        top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1
        echo
        echo 'Memory Usage:'
        free -h | grep '^Mem'
        echo
        echo 'Disk Usage:'
        df -h / | tail -1
        echo
        echo 'Container Resource Usage:'
        podman stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null || echo 'No containers running'
    ")
    
    log "System resources:"
    echo "$resources" | while read -r line; do
        log "  $line"
    done
    
    # Check for resource alerts
    local cpu_usage=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        top -bn1 | grep 'Cpu(s)' | awk '{print \$2}' | cut -d'%' -f1 | cut -d'u' -f1
    ")
    
    local memory_usage=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        free | grep '^Mem' | awk '{printf \"%.1f\", \$3/\$2 * 100.0}'
    ")
    
    local disk_usage=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        df / | tail -1 | awk '{print \$5}' | cut -d'%' -f1
    ")
    
    # Resource thresholds
    local cpu_threshold=80
    local memory_threshold=85
    local disk_threshold=90
    
    if (( $(echo "$cpu_usage > $cpu_threshold" | bc -l) )); then
        warning "High CPU usage: ${cpu_usage}%"
    else
        success "CPU usage normal: ${cpu_usage}%"
    fi
    
    if (( $(echo "$memory_usage > $memory_threshold" | bc -l) )); then
        warning "High memory usage: ${memory_usage}%"
    else
        success "Memory usage normal: ${memory_usage}%"
    fi
    
    if [ "$disk_usage" -gt "$disk_threshold" ]; then
        warning "High disk usage: ${disk_usage}%"
    else
        success "Disk usage normal: ${disk_usage}%"
    fi
}

# Function to check container logs for errors
check_container_logs() {
    local container_name=$1
    local lines=${2:-50}
    
    log "Checking recent logs for ${container_name} (last ${lines} lines)..."
    
    # Get recent logs
    local logs=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        podman logs --tail ${lines} ${container_name} 2>&1 || echo 'No logs available'
    ")
    
    # Count error patterns
    local error_count=$(echo "$logs" | grep -i -E "(error|exception|fatal|panic|fail)" | wc -l)
    local warning_count=$(echo "$logs" | grep -i -E "(warn|warning)" | wc -l)
    
    log "Found ${error_count} error(s) and ${warning_count} warning(s) in recent logs"
    
    if [ "$error_count" -gt 0 ]; then
        warning "Recent errors found in logs:"
        echo "$logs" | grep -i -E "(error|exception|fatal|panic|fail)" | tail -5 | while read -r line; do
            warning "  $line"
        done
    else
        success "No recent errors found in logs"
    fi
    
    return 0
}

# Function to perform load test
perform_load_test() {
    local port=${1:-$HOST_PORT}
    local requests=${2:-100}
    local concurrency=${3:-10}
    
    log "Performing load test: ${requests} requests with ${concurrency} concurrent connections"
    
    # Check if ab (Apache Bench) is available
    local ab_available=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        command -v ab >/dev/null 2>&1 && echo 'yes' || echo 'no'
    ")
    
    if [ "$ab_available" = "no" ]; then
        warning "Apache Bench (ab) not available, skipping load test"
        return 0
    fi
    
    # Perform load test
    local load_test_result=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
        ab -n ${requests} -c ${concurrency} -q http://localhost:${port}/ 2>/dev/null | grep -E '(Requests per second|Time per request|Failed requests)'
    ")
    
    log "Load test results:"
    echo "$load_test_result" | while read -r line; do
        log "  $line"
    done
    
    # Check for failed requests
    local failed_requests=$(echo "$load_test_result" | grep "Failed requests" | awk '{print $3}')
    local success_rate=$(echo "scale=2; (${requests} - ${failed_requests:-0}) / ${requests} * 100" | bc -l)
    
    if (( $(echo "$success_rate >= $MIN_SUCCESS_RATE" | bc -l) )); then
        success "Load test passed: ${success_rate}% success rate"
    else
        error "Load test failed: ${success_rate}% success rate (minimum: ${MIN_SUCCESS_RATE}%)"
        return 1
    fi
    
    return 0
}

# Function to generate health report
generate_health_report() {
    local report_file="/tmp/health-report-$(date +%Y%m%d-%H%M%S).txt"
    
    log "Generating health report..."
    
    cat > "$report_file" << EOF
HEALTH CHECK REPORT
===================

Date: $(date)
Environment: ${ENVIRONMENT}
Target Server: ${TARGET_SERVER}
Host Port: ${HOST_PORT}

Container Status:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' | grep -E '(NAMES|${CONTAINER_NAME})' || echo 'No containers found'")

System Resources:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "
    echo 'CPU: '
    top -bn1 | grep 'Cpu(s)' | awk '{print \$2}'
    echo 'Memory:'
    free -h | grep '^Mem'
    echo 'Disk:'
    df -h / | tail -1
")

Network Connectivity:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "
    echo 'Port ${HOST_PORT} status:'
    netstat -tlnp | grep ':${HOST_PORT}' || echo 'Port not listening'
")

Recent System Events:
$(ssh "${SSH_USER}@${TARGET_SERVER}" "journalctl --since '1 hour ago' --no-pager -n 10" 2>/dev/null || echo "Could not retrieve system logs")

EOF
    
    success "Health report generated: ${report_file}"
    cat "$report_file"
}

# Main health check function
main() {
    local check_type=${2:-"full"}
    
    log "Starting health check for ${ENVIRONMENT} environment"
    log "Check type: ${check_type}"
    log "Target server: ${TARGET_SERVER}"
    
    # Validate required variables
    if [[ -z "${TARGET_SERVER}" || -z "${SSH_USER}" ]]; then
        error "Missing required environment variables"
        exit 1
    fi
    
    local health_status=0
    
    case "$check_type" in
        "container")
            if ! check_container_health "${CONTAINER_NAME}-blue" && ! check_container_health "${CONTAINER_NAME}-green"; then
                error "No healthy containers found"
                health_status=1
            fi
            ;;
        "http")
            if ! check_http_health; then
                health_status=1
            fi
            ;;
        "resources")
            check_system_resources
            ;;
        "logs")
            local active_container=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
                podman ps --format '{{.Names}}' | grep '${CONTAINER_NAME}' | head -1 || echo ''
            ")
            if [ -n "$active_container" ]; then
                check_container_logs "$active_container"
            else
                warning "No active containers found for log check"
            fi
            ;;
        "load")
            if ! perform_load_test; then
                health_status=1
            fi
            ;;
        "full")
            # Comprehensive health check
            local active_container=$(ssh "${SSH_USER}@${TARGET_SERVER}" "
                podman ps --format '{{.Names}}' | grep '${CONTAINER_NAME}' | head -1 || echo ''
            ")
            
            if [ -n "$active_container" ]; then
                if ! check_container_health "$active_container"; then
                    health_status=1
                fi
                check_container_logs "$active_container"
            else
                error "No active containers found"
                health_status=1
            fi
            
            if ! check_http_health; then
                health_status=1
            fi
            
            check_application_metrics
            check_system_resources
            
            # Optional load test for production
            if [ "$ENVIRONMENT" = "production" ]; then
                perform_load_test "$HOST_PORT" 50 5
            fi
            ;;
        *)
            error "Unknown check type: ${check_type}"
            error "Available types: container, http, resources, logs, load, full"
            exit 1
            ;;
    esac
    
    # Generate health report
    generate_health_report
    
    if [ $health_status -eq 0 ]; then
        success "Health check completed successfully!"
        exit 0
    else
        error "Health check failed!"
        exit 1
    fi
}

# Handle script arguments
main "$@"