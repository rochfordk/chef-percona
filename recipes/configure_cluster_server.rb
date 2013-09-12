percona = node["percona"]
server  = percona["server"]
conf    = percona["conf"]
mysqld  = (conf && conf["mysqld"]) || {}
firstnode = false
headnode = ""

# construct an encrypted passwords helper -- giving it the node and bag name
passwords = EncryptedPasswords.new(node, percona["encrypted_data_bag"])

template "/root/.my.cnf" do
  variables(:root_password => passwords.root_password)
  owner "root"
  group "root"
  mode 0600
  source "my.cnf.root.erb"
end

if server["bind_to"]
  ipaddr = Percona::ConfigHelper.bind_to(node, server["bind_to"])
  if ipaddr && server["bind_address"] != ipaddr
    node.override["percona"]["server"]["bind_address"] = ipaddr
    node.save
  end

  log "Can't find ip address for #{server["bind_to"]}" do
    level :warn
    only_if { ipaddr.nil? }
  end
end

datadir = mysqld["datadir"] || server["datadir"]
user    = mysqld["username"] || server["username"]

# define the service
service "mysql" do
  supports :restart => true
  #If this is the first node we'll change the start and resatart commands to take advantage of the bootstrap-pxc command
  #Get the cluster address and extract the first node IP
  cluster_address = node["percona"]["cluster"]["wsrep_cluster_address"].dup
  cluster_address.slice! "gcomm://"
  cluster_nodes = cluster_address.split(',')
  headnode = cluster_nodes[0] 
  localipaddress=  node["network"]["interfaces"]["eth0"]["addresses"].select {|address, data| data["family"] == "inet" }.first.first
  
  if cluster_nodes[0] == localipaddress
	firstnode = true
	start_command "/usr/bin/service mysql bootstrap-pxc" #if platform?("ubuntu")
	restart_command "/usr/bin/service mysql stop && /usr/bin/service mysql bootstrap-pxc" #if platform?("ubuntu")
  end
  
  
  
  action server["enable"] ? :enable : :disable
end

# this is where we dump sql templates for replication, etc.
directory "/etc/mysql" do
  owner "root"
  group "root"
  mode 0755
end

# setup the data directory
directory datadir do
  owner user
  group user
  recursive true
  action :create
end

# install db to the data directory
execute "setup mysql datadir" do
  command "mysql_install_db --user=#{user} --datadir=#{datadir}"
  not_if "test -f #{datadir}/mysql/user.frm"
end

# setup the main server config file
template percona["main_config_file"] do
  source "my.cnf.#{conf ? "custom" : server["role"]}.erb"
  owner "root"
  group "root"
  mode 0744
  # If this is not the first node wait until the first node becomes available before restarting the service
  if firstnode
	notifies :restart, "service[mysql]", :immediately if node["percona"]["auto_restart"]
  else
	Chef::Log.info("****COE-LOG: Checking for MySQL service on #{headnode}, port 4567")
	while !PortCheck.is_port_open headnode, "4567"
		Chef::Log.info("****COE-LOG: waiting for first cluster node to become available")
		sleep 10
    end
  end
end

# now let's set the root password only if this is the initial install
execute "Update MySQL root password" do
  command "mysqladmin --user=root --password='' password '#{passwords.root_password}'"
  not_if "test -f /etc/mysql/grants.sql"
end

# setup the debian system user config
template "/etc/mysql/debian.cnf" do
  source "debian.cnf.erb"
  variables(:debian_password => passwords.debian_password)
  owner "root"
  group "root"
  mode 0640
  notifies :restart, "service[mysql]", :immediately if node["percona"]["auto_restart"]

  only_if { node["platform_family"] == "debian" }
end


#####################################
## CONFIGURE ACCESS FOR SST REPLICATION
#####################################
if firstnode
	sstAuth = node["percona"]["cluster"]["wsrep_sst_auth"].split(':')
	sstAuthName = sstAuth[0]
	sstauthPass = sstAuth[1]
	# Create thselect user from e user
	execute "add-mysql-user-sstuser" do
		command "/usr/bin/mysql -u root -p#{passwords.root_password} -D mysql -r -B -N -e \"CREATE USER '#{sstAuthName}'@'localhost' IDENTIFIED BY '#{sstauthPass}'\""
		action :run
		#Chef::Log.info('****COE-LOG add-mysql-user-sstuser')
		only_if { `/usr/bin/mysql -u root -p#{passwords.root_password} -D mysql -r -B -N -e \"SELECT COUNT(*) FROM user where User='sstuser' and Host = 'localhost'"`.to_i == 0 }
	end
	# Grant priviledges
	execute "grant-priviledges-to-sstuser" do
		#Chef::Log.info('****COE-LOG grant-priviledges-to-sstuser')
		command "/usr/bin/mysql -u root -p#{passwords.root_password} -D mysql -r -B -N -e \"GRANT RELOAD, LOCK TABLES, REPLICATION CLIENT ON *.* TO '#{sstAuthName}'@'localhost'\""
		action :run
	#DEL    only_if { `/usr/bin/mysql -u root -p#{mysql_password} -D mysql -r -B -N -e \"SELECT COUNT(*) FROM user where User='sstuser' and Host = 'localhost'"`.to_i == 0 }
	end
	# Flush
	execute "flush-mysql-priviledges" do
		#Chef::Log.info('****COE-LOG flush-mysql-priviledges')
		command "/usr/bin/mysql -u root -p#{passwords.root_password} -D mysql -r -B -N -e \"FLUSH PRIVILEGES\""
		action :run
	#DEL    only_if { `/usr/bin/mysql -u root -p#{mysql_password} -D mysql -r -B -N -e \"SELECT COUNT(*) FROM user where User='sstuser' and Host = 'localhost'"`.to_i == 0 }
	end
end
