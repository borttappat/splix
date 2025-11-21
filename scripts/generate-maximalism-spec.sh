#!/run/current-system/sw/bin/bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly TEMPLATES_DIR="$PROJECT_DIR/templates"
readonly GENERATED_DIR="$PROJECT_DIR/generated"

log() { echo "[$(date +%H:%M:%S)] $*"; }
error() { echo "[ERROR] $*" >&2; exit 1; }

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Generate maximalism specialization that combines router VM + pentest VM autostart

OPTIONS:
    --vm-name NAME          Name of the pentest VM (required)
    --vm-image PATH         Path to VM image (optional, defaults to pentest-vm/result/nixos.qcow2)
    --workspace NUM         Target workspace number (default: 2)
    --username USER         Username for services (default: current user)
    --output-file PATH      Output file path (default: generated/modules/maximalism-spec.nix)
    --help                  Show this help

EXAMPLES:
    # Basic usage with VM name
    $0 --vm-name pentest-vm-new

    # Full customization
    $0 --vm-name kali-vm --workspace 3 --vm-image /path/to/kali.qcow2

    # Use existing pentest VM
    $0 --vm-name pentest-vm --vm-image /home/traum/splix/pentest-vm/result/nixos.qcow2
EOF
}

# Default values
VM_NAME=""
VM_IMAGE_PATH=""
WORKSPACE_NUMBER="2"
USERNAME="${USER:-$(whoami)}"
OUTPUT_FILE=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --vm-name)
            VM_NAME="$2"
            shift 2
            ;;
        --vm-image)
            VM_IMAGE_PATH="$2"
            shift 2
            ;;
        --workspace)
            WORKSPACE_NUMBER="$2"
            shift 2
            ;;
        --username)
            USERNAME="$2"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            error "Unknown option: $1. Use --help for usage information."
            ;;
    esac
done

# Validate required parameters
if [[ -z "$VM_NAME" ]]; then
    error "VM name is required. Use --vm-name option."
fi

# Set default output file if not specified
if [[ -z "$OUTPUT_FILE" ]]; then
    OUTPUT_FILE="$GENERATED_DIR/modules/maximalism-spec.nix"
fi

# Set default VM image path if not specified
if [[ -z "$VM_IMAGE_PATH" ]]; then
    VM_IMAGE_PATH="$PROJECT_DIR/pentest-vm/result/nixos.qcow2"
fi

log "Generating maximalism specialization..."
log "VM Name: $VM_NAME"
log "VM Image: $VM_IMAGE_PATH"
log "Workspace: $WORKSPACE_NUMBER"
log "Username: $USERNAME"
log "Output: $OUTPUT_FILE"

# Check if template exists
TEMPLATE_FILE="$TEMPLATES_DIR/maximalism-specialisation.nix.template"
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    error "Template not found: $TEMPLATE_FILE"
fi

# Create output directory if it doesn't exist
mkdir -p "$(dirname "$OUTPUT_FILE")"

# Generate the specialization by substituting template variables
log "Processing template..."
sed \
    -e "s|{{VM_NAME}}|$VM_NAME|g" \
    -e "s|{{VM_IMAGE_PATH}}|$VM_IMAGE_PATH|g" \
    -e "s|{{WORKSPACE_NUMBER}}|$WORKSPACE_NUMBER|g" \
    -e "s|{{USERNAME}}|$USERNAME|g" \
    "$TEMPLATE_FILE" > "$OUTPUT_FILE"

log "Maximalism specialization generated successfully!"
log "Output file: $OUTPUT_FILE"
echo
log "Next steps:"
log "1. Review the generated configuration:"
log "   cat $OUTPUT_FILE"
log ""
log "2. Add to your NixOS configuration:"
log "   imports = [ ./path/to/maximalism-spec.nix ];"
log ""
log "3. Rebuild with maximalism specialization:"
log "   sudo nixos-rebuild switch --specialisation maximalism"
log ""
log "4. Check status:"
log "   maximalism-status"
log ""
log "Generated configuration includes:"
log "- Router VM autostart service"
log "- $VM_NAME pentest VM autostart service"
log "- Workspace $WORKSPACE_NUMBER assignment for pentest VM"
log "- Combined status and management commands"

# Optional: Create a quick integration script
INTEGRATION_SCRIPT="$GENERATED_DIR/scripts/integrate-maximalism-spec.sh"
mkdir -p "$(dirname "$INTEGRATION_SCRIPT")"

cat > "$INTEGRATION_SCRIPT" << INTEOF
#!/run/current-system/sw/bin/bash
# Quick integration script for maximalism specialization

set -euo pipefail

log() { echo "[Integration] \$*"; }

SPEC_FILE="$OUTPUT_FILE"
DOTFILES_DIR="\${DOTFILES_DIR:-\$HOME/dotfiles}"
TARGET_DIR="\$DOTFILES_DIR/modules/router-generated"

if [[ ! -f "\$SPEC_FILE" ]]; then
    echo "ERROR: Specialization file not found: \$SPEC_FILE"
    exit 1
fi

if [[ ! -d "\$DOTFILES_DIR" ]]; then
    echo "ERROR: Dotfiles directory not found: \$DOTFILES_DIR"
    echo "Set DOTFILES_DIR environment variable or ensure ~/dotfiles exists"
    exit 1
fi

log "Copying maximalism specialization to dotfiles..."
mkdir -p "\$TARGET_DIR"
cp "\$SPEC_FILE" "\$TARGET_DIR/maximalism-spec.nix"

log "Specialization copied to: \$TARGET_DIR/maximalism-spec.nix"
log ""
log "Add this import to your machine configuration:"
log "  imports = [ ./router-generated/maximalism-spec.nix ];"
log ""
log "Then rebuild:"
log "  sudo nixos-rebuild switch --specialisation maximalism"
INTEOF

chmod +x "$INTEGRATION_SCRIPT"
log "Integration helper created: $INTEGRATION_SCRIPT"