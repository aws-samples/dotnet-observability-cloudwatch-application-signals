#!/usr/bin/env bash
set -eo pipefail

# Log levels and colors
ERROR_COLOR='\033[0;31m'
SUCCESS_COLOR='\033[0;32m'
WARNING_COLOR='\033[1;33m'
INFO_COLOR='\033[0;34m'
DEBUG_COLOR='\033[0;37m'
NO_COLOR='\033[0m'

# Logging function
log() {
    local level=$(echo "${1}" | tr '[:lower:]' '[:upper:]')
    local message="$2"
    local color
    
    case $level in
        ERROR)   color=$ERROR_COLOR ;;
        SUCCESS) color=$SUCCESS_COLOR ;;
        WARNING) color=$WARNING_COLOR ;;
        INFO)    color=$INFO_COLOR ;;
        DEBUG)   color=$DEBUG_COLOR ;;
        *)       color=$INFO_COLOR ;;
    esac
    
    echo -e "${color}${level}: ${message}${NO_COLOR}" >&2
}

# Error handling
handle_error() {
    log "ERROR" "$1"
    exit 1
}

trap 'handle_error "Error occurred on line $LINENO: $BASH_COMMAND"' ERR

# Set the directory where the deployment files are located
DEPLOYMENT_DIR="kubernetes"

# Check if directory exists
[[ -d "$DEPLOYMENT_DIR" ]] || handle_error "Directory $DEPLOYMENT_DIR not found"

# List of deployment files to annotate
DEPLOYMENT_FILES=(
    "cart-deployment.yaml"
    "delivery-deployment.yaml"
)

annotate_deployment() {
    local file="$1"
    local full_path="$DEPLOYMENT_DIR/$file"
    
    [[ -f "$full_path" ]] || { log "WARNING" "File not found: $full_path"; return 1; }

    log "INFO" "Annotating $full_path"
    
    # Create a backup of the original file
    cp "$full_path" "${full_path}.bak"
    
    # Create temporary file with annotations
    cat > "${full_path}.tmp" << EOF
      annotations:
        instrumentation.opentelemetry.io/inject-dotnet: "true"
        instrumentation.opentelemetry.io/otel-dotnet-auto-runtime: "linux-musl-x64"
EOF

    # Insert annotations after metadata: line
    awk '
    /template:/{template=1}
    /metadata:/{
        if(template) {
            print
            system("cat '"${full_path}.tmp"'")
            template=0
            next
        }
    }
    {print}' "${full_path}.bak" > "$full_path"
    
    # Check if changes were made
    if diff -q "${full_path}.bak" "$full_path" >/dev/null; then
        log "WARNING" "No changes made to $file. Annotations might already exist."
    else
        log "SUCCESS" "Successfully annotated $file"
    fi
    
    # Cleanup temporary files
    rm -f "${full_path}.tmp" "${full_path}.bak"
}

# Main function
main() {
    log "INFO" "Starting deployment annotation process..."
    
    local annotated_count=0
    for file in "${DEPLOYMENT_FILES[@]}"; do
        if annotate_deployment "$file"; then
            ((annotated_count++))
        fi
    done
    
    if [[ $annotated_count -eq ${#DEPLOYMENT_FILES[@]} ]]; then
        log "SUCCESS" "All deployment files annotated successfully"
    else
        log "WARNING" "Annotated $annotated_count out of ${#DEPLOYMENT_FILES[@]} files"
    fi
    
    log "INFO" "Don't forget to apply the changes with:"
    for file in "${DEPLOYMENT_FILES[@]}"; do
        log "INFO" "kubectl apply -f $DEPLOYMENT_DIR/$file"
    done
}


# Run main function
main
