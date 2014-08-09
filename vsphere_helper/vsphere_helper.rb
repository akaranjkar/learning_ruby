require 'rbvmomi'
require 'json'
require 'pp'
require 'trollop'
require 'highline/import'

opts = Trollop::options do 
    opt :server, "vCenter Server hostname/IP address", :required => true, :type => :string
    opt :username, "vCenter Server username", :required => true, :type => :string
    opt :password, "vCenter Server password", :type => :string
    opt :task, "Task to perform: inventory, clone, status, operation, ticket", :required => true, :type => :string
    opt :source, "clone task: Name of the source VM", :type => :string
    opt :vcpu, "clone task: Number of vCPUs", :type => :integer
    opt :vram, "clone task: vRAM in MB", :type => :integer
    opt :portgroup, "clone task: Port Group in which to place vmnic0", :type => :string
    opt :cspec, "clone task: Customization Specification to apply", :type => :string
    opt :fqdn, "clone task: FQDN of the VM", :type => :string
    opt :ip, "clone task: IP address of vmnic0", :type => :string
    opt :subnetmask, "clone task: Subnet mask of vmnic0", :type => :string
    opt :gateway, "clone task: Gateway of vmnic0", :type => :string
    opt :cluster, "clone task: Cluster in which to place VM", :type => :string
    opt :resourcepool, "clone task: Resource Pool in which to place VM", :type => :string
    opt :datastore, "clone task: Datastore in which to place VM", :type => :string
    opt :entity, "status task: Managed object ID of entity", :type => :string
    opt :file, "inventory task: File to write inventory information to", :type => :string
    opt :operation, "operation task: Operation to perform", :type => :string
end

class VSphereHelper
    #Generic functions
    #Initialize class
    def initialize(server, username, password = nil)
        @server = server
        @username = username
        password ||= ask("Password for user '#{@username}': ") { |p| p.echo = "*" }
        @password = password
    end
    #Get vSphere connection
    def connect()
        begin
            @vim = RbVmomi::VIM.connect host: @server, user: @username, password: @password, insecure: true
        rescue RbVmomi::VIM::InvalidLogin
            $stderr.puts "Error: Unable to login with provided credentials. Invalid username or password."
            abort
        rescue Timeout::Error
            $stderr.puts "Error: Timed out while connecting to vCenter Server at #{@server}."
            abort
        end
    end
    #Disconnect from vSphere
    def disconnect()
        begin
            @vim.close
        rescue nil
        end
    end

    #Returns the moid as a string
    def get_moid(moref)
        moref.to_s.split("\"")[1]
    end

    #Find a vm by name and return moref
    def find_vm_by_name(vmname, folder)
        folder.children.each do |entity|
            if entity.is_a? RbVmomi::VIM::Folder
                vm_ref = find_vm_by_name(vmname,entity)
                return vm_ref if vm_ref.is_a? RbVmomi::VIM::VirtualMachine
            elsif entity.is_a? RbVmomi::VIM::VirtualMachine
                return entity if entity.name == vmname
            end
        end
        return nil
    end
    
    #Find a vm by vmid and return moref
    def find_vm_by_vmid(vmid, folder)
        folder.children.each do |entity|
            if entity.is_a? RbVmomi::VIM::Folder
                vm_ref = find_vm_by_vmid(vmid,entity)
                return vm_ref if vm_ref.is_a? RbVmomi::VIM::VirtualMachine
            elsif entity.is_a? RbVmomi::VIM::VirtualMachine
                return entity if get_moid(entity) == vmid
            end
        end
        return nil
    end

    #Faster VM search function. Needs cluster and resource pool to be specified
    def faster_find_vm_by_vmid(vmid, clusterid, respoolid)
        #Find cluster
        cluster_ref = @vim.rootFolder.childEntity[0].hostFolder.childEntity.grep(RbVmomi::VIM::ClusterComputeResource).find { |c| c._ref == clusterid }
        #Find resourcepool
        #Can either be default resource pool or children resource pools
        default_respool_ref = cluster_ref.resourcePool
        if default_respool_ref._ref == respoolid
            respool_ref = default_respool_ref 
        else
            respool_ref = default_respool_ref.resourcePool.grep(RbVmomi::VIM::ResourcePool).find { |r| r._ref == respoolid}
        end
        #Find vmref
        vm_ref = respool_ref.vm.grep(RbVmomi::VIM::VirtualMachine).find { |v| v._ref == vmid }
        return vm_ref if vm_ref
        return nil
    end

    #Acquire clone ticket
    def acquire_clone_ticket
        @vim.serviceContent.sessionManager.AcquireCloneTicket
    end

    #Clone task functions
    def set_vm_config_spec(vcpu, vram, portgroup, source)
        @vcpu = vcpu
        @vram = vram 
        @portgroup = @vim.rootFolder.children[0].network.find { |pg| pg.name == portgroup } or abort ("Error: Specified portgroup #{portgroup} not found.")
        @virtualmachineconfigspec = RbVmomi::VIM.VirtualMachineConfigSpec
        @virtualmachineconfigspec.deviceChange = Array.new
        @virtualmachineconfigspec.numCPUs = @vcpu
        @virtualmachineconfigspec.memoryMB = @vram
        source_vm = @vim.serviceInstance.find_datacenter.find_vm(source) or abort ("Error: Source VM #{source} not found.")
        source_vmnic = source_vm.config.hardware.device.grep(RbVmomi::VIM::VirtualEthernetCard).first
        source_vmnic.backing.deviceName = @portgroup.name
        source_vmnic.connectable.connected = true
        source_vmnic.connectable.startConnected = true
        devicespec = RbVmomi::VIM.VirtualDeviceConfigSpec(:device => source_vmnic, :operation => "edit")
        @virtualmachineconfigspec.deviceChange.push devicespec
        @virtualmachineconfigspec
    end

    def set_vm_customization_spec(cspec, fqdn, ip, subnetmask, gateway)
        begin
            customizationspecitem = @vim.serviceContent.customizationSpecManager.GetCustomizationSpec( {:name => cspec} )
        rescue RbVmomi::VIM::NotFound
            $stderr.puts("Error: Couldn't find customization specification #{cspec}.")
            abort
        end
        @customizationspec = customizationspecitem.spec
        @fqdn = fqdn
        @shortname = fqdn.split('.')[0]
        #@customizationspec.identity.userData.computerName.name = shortname
        @customizationspec.nicSettingMap[0].adapter.ip.ipAddress = ip
        @customizationspec.nicSettingMap[0].adapter.subnetMask = subnetmask
        @customizationspec.nicSettingMap[0].adapter.gateway[0] = gateway
        @customizationspec
    end

    def set_vm_relocate_spec(cluster, resourcepool, datastore)
        @virtualmachinerelocatespec = RbVmomi::VIM.VirtualMachineRelocateSpec
        #@virtualmachinerelocatespec.host = cluster
        @virtualmachinerelocatespec.pool = resourcepool
        @virtualmachinerelocatespec.datastore = datastore
        @virtualmachinerelocatespec
    end

    def set_vm_clone_spec()
        @virtualmachineclonespec = RbVmomi::VIM.VirtualMachineCloneSpec
        @virtualmachineclonespec.config = @virtualmachineconfigspec
        @virtualmachineclonespec.customization = @customizationspec
        @virtualmachineclonespec.location = @virtualmachinerelocatespec
        @virtualmachineclonespec.powerOn = true
        @virtualmachineclonespec.template = false
        @virtualmachineclonespec
    end

    def dump_vm_clone_spec()
        pp @virtualmachineclonespec.inspect
    end

    def clone_vm(source)
        abort ("Destination VM #{@shortname} already exists.") if @vim.serviceInstance.find_datacenter.find_vm(@shortname)
        source_vm = @vim.serviceInstance.find_datacenter.find_vm(source) or abort ("Source VM #{source} not found.")
        @task = source_vm.CloneVM_Task(:folder => source_vm.parent, :name => @shortname, :spec => @virtualmachineclonespec)
        puts "Initiated cloning. Task id: #{get_moid(@task)}"
        #@task.wait_for_completion
    end
    #Inventory task functions
    #better_name returns ObjectClass-moid
    def better_name(vsphere_name)
        vsphere_name.to_s.split("\"")[0][0..-2]+"-"+vsphere_name.to_s.split("\"")[1]
    end
    
    def get_inventory()
        self.connect
        @hierarchy = {}
        #Inventory
        @hierarchy[better_name(@vim.rootFolder)] = { "moid" => @vim.rootFolder.to_s.split("\"")[1], "name" => @vim.rootFolder.name}
        datacenters = @vim.rootFolder.children
        datacenters.each do |dc|
            @hierarchy[better_name(@vim.rootFolder)][better_name(dc)] = { "moid" => dc.to_s.split("\"")[1], "name" => dc.name }
            #Clusters
            host_folder = dc.hostFolder
            @hierarchy[better_name(@vim.rootFolder)][better_name(dc)][better_name(host_folder)] = { "moid" => host_folder.to_s.split("\"")[1], "name" => host_folder.name }
            clusters = host_folder.children
            clusters.each do |cluster|
                @hierarchy[better_name(@vim.rootFolder)][better_name(dc)][better_name(host_folder)][better_name(cluster)] = { "moid" => cluster.to_s.split("\"")[1], "name" => cluster.name }
                #Default resource pool
                default_pool = cluster.resourcePool
                @hierarchy[better_name(@vim.rootFolder)][better_name(dc)][better_name(host_folder)][better_name(cluster)][better_name(default_pool)] = { "moid" => default_pool.to_s.split("\"")[1], "name" => default_pool.name }
                #Children resource pool
                cluster_resource_pools = default_pool.resourcePool
                cluster_resource_pools.each do |resource_pool|
                    @hierarchy[better_name(@vim.rootFolder)][better_name(dc)][better_name(host_folder)][better_name(cluster)][better_name(default_pool)][better_name(resource_pool)] = { "moid" => resource_pool.to_s.split("\"")[1], "name" => resource_pool.name }
                end
                #Datastores
                cluster.datastore.each do |datastore|
                    @hierarchy[better_name(@vim.rootFolder)][better_name(dc)][better_name(host_folder)][better_name(cluster)][better_name(datastore)] = { "moid" => datastore.to_s.split("\"")[1], "name" => datastore.name }
                end
                #Networks
                cluster.network.each do |network|
                    @hierarchy[better_name(@vim.rootFolder)][better_name(dc)][better_name(host_folder)][better_name(cluster)][better_name(network)] = { "moid" => network.to_s.split("\"")[1], "name" => network.name }
                end
            end
        end
        #List customizations
        @hierarchy["ServiceContent"] = {}
        @hierarchy["ServiceContent"][better_name(@vim.serviceContent.customizationSpecManager)] = {}
        @vim.serviceContent.customizationSpecManager.info.each do |cspec|
            @hierarchy["ServiceContent"][better_name(@vim.serviceContent.customizationSpecManager)][cspec.name] = cspec.type
        end
        self.disconnect
    end

    def dump_inventory_to_json(json_file)
        self.get_inventory
        File.open(json_file, 'w') { |f| f << JSON.pretty_generate(@hierarchy) }
    end

    def print_inventory_json()
        self.get_inventory
        JSON.pretty_generate(@hierarchy)
    end

    def print_inventory_hash()
        self.get_inventory
        pp @hierarchy
    end
    #Status task function
    #Return status of a task. Works only on recent tasks that haven't been cleared from the taskManager
    #Returns error, queued, running or success
    def report_task_status(task_id)
        $stderr.puts "No task-id provided." unless task_id 
        found = false
        @vim.serviceInstance.content.taskManager.recentTask.each do |task|
            task_id_string = task.info.task.to_s.split("\"")[1]
            if task_id_string == task_id
                begin
                    found = true
                    state = task.info.state
                    case state
                    when "success"
                        vmid = task.info.result
                        start_time = task.info.startTime
                        complete_time = task.info.completeTime
                        puts "State: #{state}, VM: #{vmid.name}, vmid: #{get_moid(vmid)}, Start time: #{start_time}, Complete time: #{complete_time}"
                    when "running"
                        progress = task.info.progress
                        start_time = task.info.startTime 
                        message = task.info.description.message
                        puts "State: #{state}, Progress: #{progress}% complete, Current step: #{message}, Start time: #{start_time}"
                    when "queued"
                        puts "State #{state}"
                    when "error"
                        error_message = task.info.error.localizedMessage
                        start_time = task.info.startTime
                        complete_time = task.info.completeTime
                        puts "State: #{state}, Message: #{error_message}, Start time: #{start_time}, Complete time: #{complete_time}"
                    end
                    return 
                rescue
                    $stderr.puts "Unknown exception while checking the status of #{task_id}."
                end
            end
        end
        puts "No task '#{task_id}' found." if not found 
    end
    #VM status function
    #Returns various details about a virtual machine
    def return_vm_status(vmid, clusterid, respoolid)
        vm_ref = faster_find_vm_by_vmid(vmid, clusterid, respoolid)
        vm_stats = {}
        vm_stats["name"] = vm_ref.name
        vm_stats["powerState"] = vm_ref.runtime.powerState
        vm_stats["guestHeartbeatStatus"] = vm_ref.guestHeartbeatStatus
        vm_stats["guestFullName"] = vm_ref.guest.guestFullName
        vm_stats["toolsRunningStatus"] = vm_ref.guest.toolsRunningStatus
        vm_stats["toolsStatus"] = vm_ref.guest.toolsStatus
        puts JSON.pretty_generate(vm_stats)
    end

    #VM power operations
    #Power on/off VM, Shutdown,reboot guest
    def change_vm_power_state(vmid, clusterid, respoolid, operation)
        task_id = nil
        if vmid.is_a? String
            vm_ref = faster_find_vm_by_vmid(vmid, clusterid, respoolid)
        elsif vmid.is_a? RbVmomi::VIM::VirtualMachine
            vm_ref = vmid
        end            
        case operation
        when "power_on"
            task_id = vm_ref.PowerOnVM_Task
        when "power_off"
            task_id = vm_ref.PowerOffVM_Task
        when "shutdown_guest"
            task_id = vm_ref.ShutdownGuest
        when "reboot_guest"
            task_id = vm_ref.RebootGuest
        end
        report_task_status(get_moid(task_id))
    end

    #Destroy VM
    def destroy_vm(vmid, clusterid, respoolid)
        task_id = nil
        if vmid.is_a? String
            vm_ref = faster_find_vm_by_vmid(vmid, clusterid, respoolid)
        elsif vmid.is_a? RbVmomi::VIM::VirtualMachine
            vm_ref = vmid
        end
        if vm_ref.run.powerState == "poweredOn"
            task_id = change_vm_power_state(vm_ref, power_off) 
            report_task_status(get_moid(task_id))
        end
        task_id = vm_ref.Destroy_Task
        report_task_status(get_moid(task_id))
    end
end

#Main program
case opts[:task]
when "clone"
    v = VSphereHelper.new(opts[:server], opts[:username], opts[:password])
    v.connect
    v.set_vm_config_spec(opts[:vcpu], opts[:vram], opts[:portgroup], opts[:source])
    v.set_vm_customization_spec(opts[:cspec], opts[:fqdn], opts[:ip], opts[:subnetmask], opts[:gateway])
    v.set_vm_relocate_spec(opts[:cluster], opts[:resourcepool], opts[:datastore])
    v.set_vm_clone_spec
    #v.dump_vm_clone_spec
    v.clone_vm(opts[:source])
    v.disconnect
when "status"
    v = VSphereHelper.new(opts[:server], opts[:username], opts[:password])
    v.connect
    case opts[:entity]
    when /^task-\d+/
        v.report_task_status(opts[:entity])
    when /^vm-\d+/
        v.return_vm_status(opts[:entity])
    else
        $stderr.puts "No/unknown entity-id provided."
    end
    v.disconnect
when "inventory"
    v = VSphereHelper.new(opts[:server], opts[:username], opts[:password])
    v.dump_inventory_to_json(opts[:file])
when "operation"
    v = VSphereHelper.new(opts[:server], opts[:username], opts[:password])
    v.connect
    v.change_vm_power_state(opts[:entity], opts[:cluster], opts[:resourcepool], opts[:operation]) if opts[:entity] =~ /^vm-\d+/
    v.disconnect
when "ticket"
    v = VSphereHelper.new(opts[:server], opts[:username], opts[:password])
    v.connect
    puts v.acquire_clone_ticket
    v.disconnect
end