learning_ruby
=============

This repository contains small scripts that I write as I teach myself Ruby programming.

vsphere_helper - Contains a small script which performs various tasks on vSphere 5.5. 
  * Uses the RbVmomi interface to communicate with the vCenter Server - https://github.com/rlane/rbvmomi
  * It can currently perform clone, creating, power on and off operations on VMs.
  * It can dump information regarding the inventory to a JSON file.
  * Uses task-ids and vm-ids passed as strings.
