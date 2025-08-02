#!/bin/bash

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/trivy-config.yaml"
REPORT_DIR="/tmp/security-reports"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

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

# Function to check if trivy is installed
check_trivy_installation() {
    if ! command -v trivy &> /dev/null; then
        log "Trivy not found, installing..."
        
        # Install trivy based on OS
        if [[ "$OSTYPE" == "linux-gnu"* ]]; then
            # Linux installation
            curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin
        elif [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS installation
            if command -v brew &> /dev/null; then
                brew install trivy
            else
                error "Homebrew not found. Please install trivy manually."
                exit 1
            fi
        else
            error "Unsupported operating system"
            exit 1
        fi
        
        success "Trivy installed successfully"
    else
        log "Trivy is already installed"
    fi
}

# Function to update trivy database
update_trivy_db() {
    log "Updating Trivy vulnerability database..."
    
    if trivy image --download-db-only; then
        success "Trivy database updated successfully"
    else
        warning "Failed to update Trivy database, continuing with existing database"
    fi
}

# Function to scan filesystem for vulnerabilities
scan_filesystem() {
    local target_path=${1:-"."}
    local report_file="${REPORT_DIR}/filesystem-scan-${TIMESTAMP}.json"
    
    log "Scanning filesystem: ${target_path}"
    
    mkdir -p "$REPORT_DIR"
    
    # Run filesystem scan
    if trivy fs \
        --config "$CONFIG_FILE" \
        --format json \
        --output "$report_file" \
        --severity CRITICAL,HIGH,MEDIUM \
        --ignore-unfixed \
        "$target_path"; then
        
        success "Filesystem scan completed: $report_file"
        
        # Parse and display summary
        parse_scan_results "$report_file" "filesystem"
        
        echo "$report_file"
    else
        error "Filesystem scan failed"
        return 1
    fi
}

# Function to scan container image
scan_container_image() {
    local image_name=$1
    local report_file="${REPORT_DIR}/image-scan-${TIMESTAMP}.json"
    
    log "Scanning container image: ${image_name}"
    
    mkdir -p "$REPORT_DIR"
    
    # Run image scan
    if trivy image \
        --config "$CONFIG_FILE" \
        --format json \
        --output "$report_file" \
        --severity CRITICAL,HIGH,MEDIUM \
        --ignore-unfixed \
        "$image_name"; then
        
        success "Image scan completed: $report_file"
        
        # Parse and display summary
        parse_scan_results "$report_file" "image"
        
        echo "$report_file"
    else
        error "Image scan failed"
        return 1
    fi
}

# Function to scan for secrets
scan_secrets() {
    local target_path=${1:-"."}
    local report_file="${REPORT_DIR}/secrets-scan-${TIMESTAMP}.json"
    
    log "Scanning for secrets: ${target_path}"
    
    mkdir -p "$REPORT_DIR"
    
    # Run secret scan
    if trivy fs \
        --scanners secret \
        --format json \
        --output "$report_file" \
        "$target_path"; then
        
        success "Secret scan completed: $report_file"
        
        # Parse and display summary
        parse_secret_results "$report_file"
        
        echo "$report_file"
    else
        error "Secret scan failed"
        return 1
    fi
}

# Function to scan for misconfigurations
scan_misconfigurations() {
    local target_path=${1:-"."}
    local report_file="${REPORT_DIR}/misconfig-scan-${TIMESTAMP}.json"
    
    log "Scanning for misconfigurations: ${target_path}"
    
    mkdir -p "$REPORT_DIR"
    
    # Run misconfiguration scan
    if trivy fs \
        --scanners misconfig \
        --format json \
        --output "$report_file" \
        --severity CRITICAL,HIGH,MEDIUM \
        "$target_path"; then
        
        success "Misconfiguration scan completed: $report_file"
        
        # Parse and display summary
        parse_misconfig_results "$report_file"
        
        echo "$report_file"
    else
        error "Misconfiguration scan failed"
        return 1
    fi
}

# Function to parse scan results
parse_scan_results() {
    local report_file=$1
    local scan_type=$2
    
    if [[ ! -f "$report_file" ]]; then
        error "Report file not found: $report_file"
        return 1
    fi
    
    # Extract vulnerability counts
    local critical_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$report_file" 2>/dev/null || echo "0")
    local high_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "$report_file" 2>/dev/null || echo "0")
    local medium_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' "$report_file" 2>/dev/null || echo "0")
    local low_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "LOW")] | length' "$report_file" 2>/dev/null || echo "0")
    
    log "=== ${scan_type^^} SCAN SUMMARY ==="
    log "Critical vulnerabilities: ${critical_count}"
    log "High vulnerabilities: ${high_count}"
    log "Medium vulnerabilities: ${medium_count}"
    log "Low vulnerabilities: ${low_count}"
    
    # Display top critical vulnerabilities
    if [ "$critical_count" -gt 0 ]; then
        warning "Top Critical Vulnerabilities:"
        jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL") | "- \(.VulnerabilityID): \(.Title) (\(.PkgName))"' "$report_file" 2>/dev/null | head -5 | while read -r line; do
            warning "  $line"
        done
    fi
    
    # Set exit code based on critical vulnerabilities
    if [ "$critical_count" -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Function to parse secret scan results
parse_secret_results() {
    local report_file=$1
    
    if [[ ! -f "$report_file" ]]; then
        error "Report file not found: $report_file"
        return 1
    fi
    
    # Extract secret counts
    local secret_count=$(jq '[.Results[]?.Secrets[]?] | length' "$report_file" 2>/dev/null || echo "0")
    
    log "=== SECRET SCAN SUMMARY ==="
    log "Secrets found: ${secret_count}"
    
    # Display found secrets (without revealing the actual secrets)
    if [ "$secret_count" -gt 0 ]; then
        error "Secrets detected in the codebase!"
        jq -r '.Results[]?.Secrets[]? | "- \(.RuleID): \(.Title) (Line: \(.StartLine))"' "$report_file" 2>/dev/null | while read -r line; do
            error "  $line"
        done
        return 1
    else
        success "No secrets found"
    fi
    
    return 0
}

# Function to parse misconfiguration results
parse_misconfig_results() {
    local report_file=$1
    
    if [[ ! -f "$report_file" ]]; then
        error "Report file not found: $report_file"
        return 1
    fi
    
    # Extract misconfiguration counts
    local critical_count=$(jq '[.Results[]?.Misconfigurations[]? | select(.Severity == "CRITICAL")] | length' "$report_file" 2>/dev/null || echo "0")
    local high_count=$(jq '[.Results[]?.Misconfigurations[]? | select(.Severity == "HIGH")] | length' "$report_file" 2>/dev/null || echo "0")
    local medium_count=$(jq '[.Results[]?.Misconfigurations[]? | select(.Severity == "MEDIUM")] | length' "$report_file" 2>/dev/null || echo "0")
    
    log "=== MISCONFIGURATION SCAN SUMMARY ==="
    log "Critical misconfigurations: ${critical_count}"
    log "High misconfigurations: ${high_count}"
    log "Medium misconfigurations: ${medium_count}"
    
    # Display top critical misconfigurations
    if [ "$critical_count" -gt 0 ]; then
        warning "Top Critical Misconfigurations:"
        jq -r '.Results[]?.Misconfigurations[]? | select(.Severity == "CRITICAL") | "- \(.ID): \(.Title)"' "$report_file" 2>/dev/null | head -5 | while read -r line; do
            warning "  $line"
        done
    fi
    
    # Set exit code based on critical misconfigurations
    if [ "$critical_count" -gt 0 ]; then
        return 1
    fi
    
    return 0
}

# Function to generate comprehensive report
generate_comprehensive_report() {
    local report_file="${REPORT_DIR}/comprehensive-security-report-${TIMESTAMP}.html"
    
    log "Generating comprehensive security report..."
    
    cat > "$report_file" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>Security Scan Report - $(date)</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 20px; }
        .header { background-color: #f0f0f0; padding: 20px; border-radius: 5px; }
        .critical { color: #d32f2f; font-weight: bold; }
        .high { color: #f57c00; font-weight: bold; }
        .medium { color: #fbc02d; font-weight: bold; }
        .low { color: #388e3c; }
        .success { color: #4caf50; font-weight: bold; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background-color: #f2f2f2; }
        .summary { background-color: #e3f2fd; padding: 15px; border-radius: 5px; margin: 20px 0; }
    </style>
</head>
<body>
    <div class="header">
        <h1>Security Scan Report</h1>
        <p><strong>Generated:</strong> $(date)</p>
        <p><strong>Scan ID:</strong> ${TIMESTAMP}</p>
    </div>
    
    <div class="summary">
        <h2>Executive Summary</h2>
        <p>This report contains the results of comprehensive security scanning including vulnerability assessment, secret detection, and misconfiguration analysis.</p>
    </div>
    
    <h2>Scan Results</h2>
    <p>Detailed results are available in the following JSON files:</p>
    <ul>
EOF
    
    # Add links to individual reports
    for report in "${REPORT_DIR}"/*-${TIMESTAMP}.json; do
        if [[ -f "$report" ]]; then
            local basename=$(basename "$report")
            echo "        <li><a href=\"$basename\">$basename</a></li>" >> "$report_file"
        fi
    done
    
    cat >> "$report_file" << EOF
    </ul>
    
    <h2>Recommendations</h2>
    <ul>
        <li>Address all CRITICAL and HIGH severity vulnerabilities immediately</li>
        <li>Remove any detected secrets from the codebase and rotate credentials</li>
        <li>Fix critical and high severity misconfigurations</li>
        <li>Implement regular security scanning in your CI/CD pipeline</li>
        <li>Keep dependencies up to date</li>
        <li>Follow security best practices for container images</li>
    </ul>
    
    <h2>Next Steps</h2>
    <ol>
        <li>Review detailed scan results</li>
        <li>Create tickets for vulnerability remediation</li>
        <li>Update security policies and procedures</li>
        <li>Schedule regular security reviews</li>
    </ol>
    
    <footer style="margin-top: 50px; padding-top: 20px; border-top: 1px solid #ddd;">
        <p><small>Generated by Trivy Security Scanner - $(date)</small></p>
    </footer>
</body>
</html>
EOF
    
    success "Comprehensive report generated: $report_file"
    echo "$report_file"
}

# Function to clean old reports
cleanup_old_reports() {
    local retention_days=${1:-7}
    
    log "Cleaning up reports older than ${retention_days} days..."
    
    if [[ -d "$REPORT_DIR" ]]; then
        find "$REPORT_DIR" -type f -name "*.json" -o -name "*.html" | \
        while read -r file; do
            if [[ $(find "$file" -mtime +${retention_days} | wc -l) -gt 0 ]]; then
                log "Removing old report: $(basename "$file")"
                rm -f "$file"
            fi
        done
    fi
    
    success "Cleanup completed"
}

# Main function
main() {
    local scan_type=${1:-"all"}
    local target=${2:-"."}
    
    log "Starting security scan: ${scan_type}"
    log "Target: ${target}"
    
    # Check dependencies
    if ! command -v jq &> /dev/null; then
        error "jq is required but not installed"
        exit 1
    fi
    
    # Install/check trivy
    check_trivy_installation
    
    # Update database
    update_trivy_db
    
    # Create report directory
    mkdir -p "$REPORT_DIR"
    
    local exit_code=0
    local reports=()
    
    case "$scan_type" in
        "filesystem"|"fs")
            if report=$(scan_filesystem "$target"); then
                reports+=("$report")
            else
                exit_code=1
            fi
            ;;
        "image")
            if report=$(scan_container_image "$target"); then
                reports+=("$report")
            else
                exit_code=1
            fi
            ;;
        "secrets")
            if report=$(scan_secrets "$target"); then
                reports+=("$report")
            else
                exit_code=1
            fi
            ;;
        "misconfig")
            if report=$(scan_misconfigurations "$target"); then
                reports+=("$report")
            else
                exit_code=1
            fi
            ;;
        "all")
            # Run all scans
            if report=$(scan_filesystem "$target"); then
                reports+=("$report")
            else
                exit_code=1
            fi
            
            if report=$(scan_secrets "$target"); then
                reports+=("$report")
            else
                exit_code=1
            fi
            
            if report=$(scan_misconfigurations "$target"); then
                reports+=("$report")
            else
                exit_code=1
            fi
            ;;
        *)
            error "Unknown scan type: $scan_type"
            error "Available types: filesystem, image, secrets, misconfig, all"
            exit 1
            ;;
    esac
    
    # Generate comprehensive report
    comprehensive_report=$(generate_comprehensive_report)
    
    # Cleanup old reports
    cleanup_old_reports
    
    log "=== SECURITY SCAN COMPLETED ==="
    log "Reports generated: ${#reports[@]}"
    log "Comprehensive report: $comprehensive_report"
    
    if [ $exit_code -eq 0 ]; then
        success "Security scan passed!"
    else
        error "Security scan failed - critical issues found!"
    fi
    
    exit $exit_code
}

# Handle script arguments
main "$@"