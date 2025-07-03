.PHONY: detect test deploy emergency clean status
SHELL := /bin/bash
SCRIPT_DIR := scripts
CONFIG_FILE := detected-hardware.json
detect:
@echo "=== Hardware Detection ==="
@$(SCRIPT_DIR)/hardware-detect.sh
@if [ -f $(CONFIG_FILE) ]; then 
echo "Results:"; 
jq -r '"Score: " + (.compatibility_score|tostring) + "/16"' $(CONFIG_FILE); 
jq -r '"Recommendation: " + .recommendation' $(CONFIG_FILE); 
fi
test: $(CONFIG_FILE)
@echo "=== Running Hardware Tests ==="
@tests/hardware-validation.sh
@echo "=== Testing Emergency Recovery ==="
@tests/recovery-test.sh --dry-run
deploy: test
@echo "=== Generating NixOS Configuration ==="
@$(SCRIPT_DIR)/generate-configs.sh
@echo "=== Building Router VM ==="
@nix build .#routerVM
@echo "=== Ready for nixos-rebuild ==="
@echo "Run: sudo nixos-rebuild switch --flake .#vmRouter"
emergency:
@echo "=== EMERGENCY NETWORK RECOVERY ==="
@$(SCRIPT_DIR)/emergency-recovery.sh
status:
@if [ -f $(CONFIG_FILE) ]; then 
echo "=== Hardware Status ==="; 
jq -r '"Compatibility Score: " + (.compatibility_score|tostring) + "/16"' $(CONFIG_FILE); 
jq -r '"Best Device: " + .best_device.interface + " (" + .best_device.driver + ")"' $(CONFIG_FILE); 
else 
echo "No hardware detection results. Run 'make detect' first."; 
fi
clean:
@echo "=== Cleaning Up ==="
@rm -f $(CONFIG_FILE)
@virsh destroy router-vm 2>/dev/null || true
@virsh undefine router-vm 2>/dev/null || true
@echo "Cleaned up VMs and detection results"
$(CONFIG_FILE):
@echo "Hardware not detected. Run 'make detect' first."
@exit 1
