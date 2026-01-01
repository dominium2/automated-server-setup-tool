# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  
  # Define 2 Linux (Debian) test servers
  (1..2).each do |i|
    config.vm.define "linux#{i}" do |server|
      server.vm.box = "debian/bullseye64"
      server.vm.hostname = "linux#{i}"
      server.vm.network "private_network", ip: "192.168.56.#{10+i}"
      
      server.vm.provider "virtualbox" do |vb|
        vb.name = "HomeLab-Linux#{i}"
        vb.memory = "1024"
        vb.cpus = 1
      end
      
      # Configure SSH and create test user
      server.vm.provision "shell", inline: <<-SHELL
        # Update system
        apt-get update
        
        # Install SSH server
        apt-get install -y openssh-server sudo curl
        
        # Create test user
        useradd -m -s /bin/bash testuser
        echo 'testuser:testpass123' | chpasswd
        usermod -aG sudo testuser
        
        # Allow sudo without password (for testing only!)
        echo 'testuser ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
        
        # Configure SSH to allow password authentication
        sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        
        # Ensure password authentication is enabled
        grep -q "^PasswordAuthentication" /etc/ssh/sshd_config || echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
        
        systemctl restart sshd
        
        echo "Linux server ready! IP: 192.168.56.#{10+i}"
      SHELL
    end
  end
  
  # Define 2 Windows test servers
  (1..2).each do |i|
    config.vm.define "windows#{i}" do |server|
      server.vm.box = "gusztavvargadr/windows-11"
      server.vm.hostname = "windows#{i}"
      server.vm.network "private_network", ip: "192.168.56.#{20+i}"
      
      # Increase boot timeout for Windows VMs
      server.vm.boot_timeout = 600
      
      server.vm.provider "virtualbox" do |vb|
        vb.name = "HomeLab-Windows#{i}"
        vb.memory = "2048"
        vb.cpus = 2
        vb.gui = false
      end
      
      # Configure WinRM
      server.vm.provision "shell", inline: <<-SHELL
        # Enable WinRM
        winrm quickconfig -q
        winrm set winrm/config/service '@{AllowUnencrypted="true"}'
        winrm set winrm/config/service/auth '@{Basic="true"}'
        
        # Create test user
        net user testuser testpass123 /add
        net localgroup Administrators testuser /add
        
        # Configure firewall for WinRM
        netsh advfirewall firewall add rule name="WinRM-HTTP" dir=in localport=5985 protocol=TCP action=allow
        
        # Enable ICMP (ping) in Windows Firewall
        netsh advfirewall firewall add rule name="ICMP Allow incoming V4 echo request" protocol=icmpv4:8,any dir=in action=allow
        
        Write-Host "Windows server ready! IP: 192.168.56.#{20+i}"
      SHELL
    end
  end
end
