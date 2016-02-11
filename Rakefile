# Rake tasks for building the various parts of the system
#

require_relative 'disk_builder'
require_relative 'debootstrap_builder'

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
	file DiskBuilder::VMDK_FILE_PATH => DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH do
		DiskBuilder.new(DebootstrapBuilder::DEBOOTSTRAP_ROOTFS_PATH, ENV.has_key?('VERBOSE')).build
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
	desc 'Build a bootable disk using the debootstrap rootfs image (env vars: VERBOSE)'
	task :disk => DiskBuilder::VMDK_FILE_PATH
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

	desc "Clean the disk file"
	task :disk do
		sh("rm -f #{DiskBuilder::VMDK_FILE_PATH}")
	end
end
