# Rake tasks for building the various parts of the system
#

require_relative 'debootstrap_builder'
require_relative 'disk_builder_bios'
require_relative 'disk_builder_uefi'

distro  = "ubuntu" # or "debian"
livecd  = false
verbose = ENV.has_key?('VERBOSE')

PREREQS = {
	# tool:        pkgs_that_provides_it_on_xenial
	'debootstrap': 'debootstrap',
	'fallocate':   'util-linux',
	'losetup':     'mount',
	'qemu-img':    'qemu-utils',
}

# Shorthand
DB  = DebootstrapBuilder
UDB = UefiDiskBuilder
BDB = BiosDiskBuilder

namespace :prereqs do

	desc "Check prerequisite software is present"
	task :check do
		PREREQS.keys.each do |tool|
			sh("which #{tool}") do |ok, res|
				puts "Missing #{tool}." \
					"Run: 'sudo apt-get install #{PREREQS[tool]}'" if not ok
			end
		end
	end

end

namespace :build do

	# How to build up a cache of packages needed for speeding up repeated debootstrap runs.
	file DB::CACHED_DEBOOTSTRAP_PKGS_PATH do
		DB.new(distro, verbose, livecd).create_debootstrap_packages_tarball()
	end

	# How to build a basic rootfs using debootstrap.
	# This relies on a tarball of cached packages that is usable by debootstrap.
	file DB::DEBOOTSTRAP_ROOTFS_PATH => DB::CACHED_DEBOOTSTRAP_PKGS_PATH do
		DB.new(distro, verbose, livecd).create_debootstrap_rootfs()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file UDB::UEFI_VMDK_FILE_PATH => DB::DEBOOTSTRAP_ROOTFS_PATH do
		UDB.new(DB::DEBOOTSTRAP_ROOTFS_PATH, dev: ENV.fetch('dev', nil)).build
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file BDB::BIOS_VMDK_FILE_PATH => DB::DEBOOTSTRAP_ROOTFS_PATH do
		BDB.new(DB::DEBOOTSTRAP_ROOTFS_PATH, dev: ENV.fetch('dev', nil)).build
	end

	file UefiDiskBuilderLvm::VMDK_FILE_PATH => DB::DEBOOTSTRAP_ROOTFS_PATH do
		UefiDiskBuilderLvm.new(DB::DEBOOTSTRAP_ROOTFS_PATH, dev: ENV.fetch('dev', nil)).build
	end

	#
	# Build a tarball of cached deb packages usable by debootstrap.
	#
	desc 'Build debootstrap package cache (env vars: VERBOSE)'
	task :cache => DB::CACHED_DEBOOTSTRAP_PKGS_PATH

	#
	# Build a basic rootfs using debootstrap.
	#
	desc 'Build basic rootfs using debootstrap (env vars: VERBOSE)'
	task :rootfs => DB::DEBOOTSTRAP_ROOTFS_PATH

	#
	# Build disks.
	#
	desc 'Build a bootable UEFI disk using the debootstrap rootfs'
	task :vmdk_uefi => UDB::UEFI_VMDK_FILE_PATH

	desc 'Build a bootable BIOS disk using the debootstrap rootfs'
	task :vmdk_bios => BDB::BIOS_VMDK_FILE_PATH

end

# Clean tasks
namespace :clean do

	desc "Clean the debootstrap rootfs file"
	task :cache do
		sh("rm -f #{DB::CACHED_DEBOOTSTRAP_PKGS_PATH}")
	end

	desc "Clean the debootstrap rootfs file"
	task :rootfs do
		sh("rm -f #{DB::DEBOOTSTRAP_ROOTFS_PATH}")
	end

	desc "Clean the UEFI disk file"
	task :vmdk_uefi do
		sh("rm -f #{UDB::UEFI_VMDK_FILE_PATH}")
	end

	desc "Clean the BIOS disk file"
	task :vmdk_bios do
		sh("rm -f #{BDB::BIOS_VMDK_FILE_PATH}")
	end

	desc "Clean all disk files"
	task :disks => [:vmdk_uefi, :vmdk_bios]
end
