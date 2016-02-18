# Rake tasks for building the various parts of the system
#

require_relative 'debootstrap_builder'
require_relative 'disk_builder_bios'
require_relative 'disk_builder_uefi'

namespace :build do

	# How to build up a cache of packages needed for speeding up repeated debootstrap runs.
	file DebootstrapBuilder::CACHED_DEBOOTSTRAP_PKGS_PATH do
		DebootstrapBuilder.new("debian", ENV.has_key?('VERBOSE')).create_debootstrap_packages_tarball()
	end

	# How to build a basic rootfs using debootstrap.
	# This relies on a tarball of cached packages that is usable by debootstrap.
	file DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH => DebootstrapBuilder::CACHED_DEBOOTSTRAP_PKGS_PATH do
		DebootstrapBuilder.new("debian", ENV.has_key?('VERBOSE')).create_debootstrap_rootfs()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file UefiDiskBuilder::UEFI_VMDK_FILE_PATH => DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH do
		UefiDiskBuilder.new(DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH, ENV.has_key?('VERBOSE')).build
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file BiosDiskBuilder::BIOS_VMDK_FILE_PATH => DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH do
		BiosDiskBuilder.new(DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH, ENV.has_key?('VERBOSE')).build
	end

	#
	# Build a tarball of cached deb packages usable by debootstrap (created by debootstrap).
	#
	desc 'Build debootstrap package cache (env vars: VERBOSE)'
	task :cache => DebootstrapBuilder::CACHED_DEBOOTSTRAP_PKGS_PATH

	#
	# Build a basic rootfs using debootstrap.
	#
	desc 'Build basic rootfs using debootstrap (env vars: VERBOSE)'
	task :rootfs => DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH

	#
	# Build disk.
	#
	desc 'Build a bootable UEFI disk using the debootstrap rootfs image (env vars: VERBOSE)'
	task :uefi_disk => UefiDiskBuilder::UEFI_VMDK_FILE_PATH

	desc 'Build a bootable BIOS disk using the debootstrap rootfs image (env vars: VERBOSE)'
	task :bios_disk => BiosDiskBuilder::BIOS_VMDK_FILE_PATH
end

# Clean tasks
namespace :clean do

	desc "Clean the debootstrap rootfs file"
	task :cache do
		sh("rm -f #{DebootstrapBuilder::CACHED_DEBOOTSTRAP_PKGS_PATH}")
	end

	desc "Clean the debootstrap rootfs file"
	task :rootfs do
		sh("rm -f #{DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH}")
	end

	desc "Clean the UEFI disk file"
	task :uefi_disk do
		sh("rm -f #{UefiDiskBuilder::UEFI_VMDK_FILE_PATH}")
	end

	desc "Clean the BIOS disk file"
	task :bios_disk do
		sh("rm -f #{BiosDiskBuilder::BIOS_VMDK_FILE_PATH}")
	end

	desc "Clean all disk files"
	task :disks => [:uefi_disk, :bios_disk]
end
