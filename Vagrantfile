require 'fileutils'
require 'yaml'

# Size of the cluster created by Vagrant
num_instances=3

# Read YAML file with mountpoint details
MOUNT_POINTS = YAML::load_file('synced_folders.yaml')

module OS
  def OS.windows?
    (/cygwin|mswin|mingw|bccwin|wince|emx/ =~ RUBY_PLATFORM) != nil
  end

  def OS.mac?
   (/darwin/ =~ RUBY_PLATFORM) != nil
  end

  def OS.unix?
    !OS.windows?
  end

  def OS.linux?
    OS.unix? and not OS.mac?
  end
end

# Change basename of the VM
instance_name_prefix="calico"

Vagrant.configure("2") do |config|
  # always use Vagrants insecure key
  config.ssh.insert_key = false

  config.vm.box = "coreos-alpha-928.0.0"

  config.vm.provider :virtualbox do |v|
    # On VirtualBox, we don't have guest additions or a functional vboxsf
    # in CoreOS, so tell Vagrant that so it can be smarter.
    v.check_guest_additions = false
    v.memory = 2048 
    v.cpus = 2
    v.functional_vboxsf     = false
  end

  # Set up each box
  (1..num_instances).each do |i|
    vm_name = "%s-%02d" % [instance_name_prefix, i]
    config.vm.define vm_name do |host|
      host.vm.hostname = vm_name
	host.vm.synced_folder ".", "/vagrant", disabled: true
	begin
	  MOUNT_POINTS.each do |mount|
	    mount_options = ""
	    disabled = false
	    nfs =  true
	    if mount['mount_options']
		mount_options = mount['mount_options']
	    end
	    if mount['disabled']
		disabled = mount['disabled']
	    end
	    if mount['nfs']
		nfs = mount['nfs']
	    end
	    if File.exist?(File.expand_path("#{mount['source']}"))
		if mount['destination']
		  host.vm.synced_folder "#{mount['source']}", "#{mount['destination']}",
		    id: "#{mount['name']}",
		    disabled: disabled,
		    mount_options: ["#{mount_options}"],
		    nfs: nfs
		end
	    end
	  end
	rescue
	end
      ip = "172.18.18.#{i+100}"
      host.vm.network :private_network, ip: ip

      host.vm.provision :shell, :inline => "/usr/bin/timedatectl set-timezone Asia/Shanghai ", :privileged => true
      host.vm.provision :shell, :inline => "chmod +x /vagrant/cloud-config/key.sh && /vagrant/cloud-config/key.sh ", :privileged => true
      #host.vm.provision :shell, :inline => "cp /vagrant/cloud-config/network-environment /etc/network-environment", :privileged => true
      host.vm.provision :docker, images: ["busybox:latest", "shenshouer/pause:0.8.0", "calico/node:v0.15.0"]
      sedInplaceArg = OS.mac? ? " ''" : ""
      if i == 1
        # Configure the master.
        system "cp cloud-config/master-config.yaml.tmpl cloud-config/master-config.yaml"
        system "sed -e 's|__HOSTNAMT__|#{vm_name}|g' -i#{sedInplaceArg} ./cloud-config/master-config.yaml"
        host.vm.provision :file, :source => "./manifests/kube-ui-rc.yaml", :destination => "/home/core/kube-ui-rc.yaml"
        host.vm.provision :file, :source => "./manifests/kube-ui-svc.yaml", :destination => "/home/core/kube-ui-svc.yaml"
        host.vm.provision :file, :source => "./manifests/skydns.yaml", :destination => "/home/core/skydns.yaml"
        host.vm.provision :file, :source => "./manifests/busybox.yaml", :destination => "/home/core/busybox.yaml"
        host.vm.provision :file, :source => "./cloud-config/master-config.yaml", :destination => "/tmp/vagrantfile-user-data"
        host.vm.provision :shell, :inline => "mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/", :privileged => true
      else
        # Configure a node.
        system "cp cloud-config/node-config.yaml.tmpl cloud-config/node-config.yaml_#{vm_name}"
        system "sed -e 's|__HOSTNAMT__|#{vm_name}|g' -i#{sedInplaceArg} ./cloud-config/node-config.yaml_#{vm_name}"
        host.vm.provision :file, :source => "./cloud-config/node-config.yaml_#{vm_name}", :destination => "/tmp/vagrantfile-user-data"
        host.vm.provision :shell, :inline => "mv /tmp/vagrantfile-user-data /var/lib/coreos-vagrant/", :privileged => true
      end
    end
  end
end
