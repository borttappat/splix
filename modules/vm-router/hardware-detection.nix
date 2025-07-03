# modules/vm-router/hardware-detection.nix - Hardware-specific configuration
{ config, lib, pkgs, ... }:

let
  # Read hardware results if available
  hardwareResultsPath = ./../../scripts/hardware-results.json;
  hardwareResults = 
    if builtins.pathExists hardwareResultsPath
    then builtins.fromJSON (builtins.readFile hardwareResultsPath)
    else {
      PRIMARY_INTERFACE = "";
      PRIMARY_PCI = "";
      PRIMARY_ID = "";
      PRIMARY_DRIVER = "";
      IOMMU_ISOLATED = false;
      ALT_INTERFACES = false;
      COMPATIBILITY_SCORE = 0;
      RECOMMENDATION = "HARDWARE_NOT_DETECTED";
    };
in
{
  options.hardware.vmRouter = {
    primaryInterface = lib.mkOption {
      type = lib.types.str;
      default = hardwareResults.PRIMARY_INTERFACE;
      description = "Primary network interface for passthrough";
    };
    
    primaryPCI = lib.mkOption {
      type = lib.types.str;
      default = hardwareResults.PRIMARY_PCI;
      description = "PCI slot of primary network interface";
    };
    
    primaryDeviceId = lib.mkOption {
      type = lib.types.str;
      default = hardwareResults.PRIMARY_ID;
      description = "Vendor:Device ID of primary network interface";
    };
    
    primaryDriver = lib.mkOption {
      type = lib.types.str;
      default = hardwareResults.PRIMARY_DRIVER;
      description = "Driver for primary network interface";
    };
    
    compatibilityScore = lib.mkOption {
      type = lib.types.int;
      default = hardwareResults.COMPATIBILITY_SCORE;
      description = "Hardware compatibility score (0-10)";
    };
    
    recommendation = lib.mkOption {
      type = lib.types.str;
      default = hardwareResults.RECOMMENDATION;
      description = "Hardware compatibility recommendation";
    };
  };
  
  # Configuration warnings and assertions
  config.warnings = lib.optionals (config.hardware.vmRouter.compatibilityScore < 8) [
    "Hardware compatibility score is ${toString config.hardware.vmRouter.compatibilityScore}/10. Consider reviewing hardware requirements."
  ] ++ lib.optionals (config.hardware.vmRouter.recommendation == "HARDWARE_NOT_DETECTED") [
    "Hardware not detected. Run ./scripts/hardware-identify.sh first."
  ];
  
  config.assertions = [
    {
      assertion = config.hardware.vmRouter.recommendation != "REDESIGN_REQUIRED";
      message = "Hardware compatibility too low (${toString config.hardware.vmRouter.compatibilityScore}/10). VM router setup not recommended.";
    }
    {
      assertion = config.hardware.vmRouter.recommendation != "HARDWARE_NOT_DETECTED";
      message = "Hardware not detected. Run ./scripts/hardware-identify.sh before deploying.";
    }
    {
      assertion = config.hardware.vmRouter.primaryInterface != "";
      message = "No primary network interface detected. Check hardware detection results.";
    }
  ];
}
