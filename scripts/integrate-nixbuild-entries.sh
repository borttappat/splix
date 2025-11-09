#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly GENERATED_DIR="$PROJECT_DIR/generated"
readonly NIXBUILD_SCRIPT="$PROJECT_DIR/nixbuild.sh"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

main() {
    log "=== Integrating Generated nixbuild Entries ==="
    
    if [[ ! -f "$NIXBUILD_SCRIPT" ]]; then
        error "nixbuild.sh not found at $NIXBUILD_SCRIPT"
    fi
    
    if [[ ! -d "$GENERATED_DIR/nixbuild-entries" ]]; then
        log "No nixbuild entries found - nothing to integrate"
        exit 0
    fi
    
    # Create backup
    cp "$NIXBUILD_SCRIPT" "$NIXBUILD_SCRIPT.backup.$(date +%Y%m%d_%H%M%S)"
    log "Created backup: $NIXBUILD_SCRIPT.backup.$(date +%Y%m%d_%H%M%S)"
    
    # Find integration point (before "For other Asus-hosts")
    local integration_line=$(grep -n "# For other Asus-hosts" "$NIXBUILD_SCRIPT" | cut -d: -f1)
    if [[ -z "$integration_line" ]]; then
        error "Could not find integration point in nixbuild.sh"
    fi
    
    log "Integration point found at line $integration_line"
    
    # Create temporary file with integrated entries
    local temp_file=$(mktemp)
    
    # Copy everything before integration point
    head -n $((integration_line - 1)) "$NIXBUILD_SCRIPT" > "$temp_file"
    
    # Add generated entries
    log "Integrating nixbuild entries:"
    for entry_file in "$GENERATED_DIR/nixbuild-entries"/*.sh; do
        if [[ -f "$entry_file" ]]; then
            local machine_name=$(basename "$entry_file" | sed 's/-nixbuild-entry\.sh$//')
            log "  - $machine_name"
            
            # Add newline and entry content
            echo "" >> "$temp_file"
            cat "$entry_file" >> "$temp_file"
            echo "" >> "$temp_file"
        fi
    done
    
    # Add everything from integration point onward
    tail -n +$integration_line "$NIXBUILD_SCRIPT" >> "$temp_file"
    
    # Replace original file
    mv "$temp_file" "$NIXBUILD_SCRIPT"
    chmod +x "$NIXBUILD_SCRIPT"
    
    log "=== Integration Complete ==="
    log "Updated nixbuild.sh with $(find "$GENERATED_DIR/nixbuild-entries" -name "*.sh" | wc -l) new entries"
    log "Backup available at: $NIXBUILD_SCRIPT.backup.*"
}

main "$@"