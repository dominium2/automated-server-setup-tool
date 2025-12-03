# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  # Define 3 Debian test servers
  (1..3).each do |i|
    config.vm.define "testserver#{i}" do |server|
      server.vm.box = "debian/bullseye64"
      server.vm.hostname = "testserver#{i}"
      server.vm.network "private_network", ip: "192.168.56.#{10+i}"
      
      server.vm.provider "virtualbox" do |vb|
        vb.name = "HomeLab-TestServer#{i}"
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
        
        # Configure SSH
        sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config
        systemctl restart sshd
        
        echo "Server ready! IP: 192.168.56.#{10+i}"
      SHELL
    end
  end
end
