{ config, lib, pkgs, ... }:

{
  boot.kernelParams = [
    "intel_iommu=on"
    "vfio-pci.ids=8086:a0f0"
  ];

  boot.kernelModules = [ "vfio" "vfio_iommu_type1" "vfio_pci" ];
  boot.blacklistedKernelModules = [ "iwlwifi" ];

  virtualisation.libvirtd = {
    enable = true;
    qemu = {
      package = pkgs.qemu_kvm;
      runAsRoot = true;
      swtpm.enable = true;
      ovmf = {
        enable = true;
        packages = [ pkgs.OVMFFull.fd ];
      };
    };
  };

  systemd.network.enable = true;
  
  systemd.network.netdevs."10-br0" = {
    netdevConfig = {
      Name = "br0";
      Kind = "bridge";
    };
  };

  systemd.network.networks."10-br0" = {
    matchConfig.Name = "br0";
    networkConfig = {
      DHCP = "no";
      IPForward = "yes";
    };
    addresses = [
      {
        addressConfig.Address = "192.168.100.2/24";
      }
    ];
    routes = [
      {
        routeConfig = {
          Gateway = "192.168.100.1";
          Destination = "0.0.0.0/0";
        };
      }
    ];
    dns = [ "192.168.100.1" ];
  };

  systemd.services.router-vm = {
    description = "Router VM";
    after = [ "libvirtd.service" "systemd-networkd.service" ];
    wantedBy = [ "multi-user.target" ];
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      User = "root";
    };

    script = ''
      if ! ${pkgs.libvirt}/bin/virsh list --all | grep -q router-vm; then
        ${pkgs.libvirt}/bin/virsh define /etc/libvirt/qemu/router-vm.xml
      fi
      
      if ! ${pkgs.libvirt}/bin/virsh list | grep -q "router-vm.*running"; then
        ${pkgs.libvirt}/bin/virsh start router-vm
      fi
    '';

    preStop = ''
      ${pkgs.libvirt}/bin/virsh shutdown router-vm || true
      sleep 10
      ${pkgs.libvirt}/bin/virsh destroy router-vm || true
    '';
  };

  systemd.services.network-emergency = {
    description = "Emergency Network Recovery";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "emergency-recovery" ''
        #!/bin/bash
        echo "Emergency recovery: Restoring network..."
        
        virsh shutdown router-vm || true
        sleep 5
        virsh destroy router-vm || true
        
        systemctl stop systemd-networkd
        ip link set br0 down || true
        ip link del br0 || true
        
        systemctl start NetworkManager || systemctl restart networking
        
        echo "Network recovery complete"
      '';
    };
  };

  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "br0" ];
    allowedTCPPorts = [ 22 5900 5901 5902 ];
  };

  users.users.${builtins.getEnv "SUDO_USER" or "nixos"}.extraGroups = [ "libvirtd" "kvm" ];

  environment.systemPackages = with pkgs; [
    virt-manager
    bridge-utils
    libvirt
  ];
}
