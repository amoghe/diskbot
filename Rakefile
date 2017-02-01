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

	# How to build a cache of pkgs needed for speeding up debootstrap runs.
	file DB::CACHED_DEBOOTSTRAP_PKGS_PATH do
		builder = DB.new(distro, verbose: verbose, livecd:  livecd)
		builder.create_debootstrap_packages_tarball()
	end

	# How to build a basic rootfs using debootstrap.
	# This relies on a tarball of cached packages that is usable by debootstrap.
	file DB::DEBOOTSTRAP_ROOTFS_PATH => DB::CACHED_DEBOOTSTRAP_PKGS_PATH do
		builder = DB.new(distro,
			customize_script: ENV['CUSTOMIZE_SCRIPT'],
			verbose: verbose,
			livecd:  livecd)
		builder.create_debootstrap_rootfs()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file UDB::UEFI_VMDK_FILE_PATH => DB::DEBOOTSTRAP_ROOTFS_PATH do
		builder = UDB.new(DB::DEBOOTSTRAP_ROOTFS_PATH,
			ENV['PARTITION_LAYOUT'],
			dev: ENV.fetch('dev', nil))
		builder.build()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file BDB::BIOS_VMDK_FILE_PATH => DB::DEBOOTSTRAP_ROOTFS_PATH do
		builder = BDB.new(DB::DEBOOTSTRAP_ROOTFS_PATH,
			ENV['PARTITION_LAYOUT'],
			dev: ENV.fetch('dev', nil))
		builder.build()
	end

	#
	# Build a tarball of cached deb packages usable by debootstrap.
	#
	desc 'Build debootstrap package cache (supports some env vars)'
	task :cache => DB::CACHED_DEBOOTSTRAP_PKGS_PATH

	#
	# Build a basic rootfs using debootstrap.
	#
	desc 'Build basic rootfs using debootstrap (supports some env vars)'
	task :rootfs => DB::DEBOOTSTRAP_ROOTFS_PATH

	#
	# Build vmdks.
	#
	namespace :vmdk do
		desc 'Build a bootable UEFI vmdk disk using the debootstrap rootfs'
		task :uefi => UDB::UEFI_VMDK_FILE_PATH

		desc 'Build a bootable BIOS vmdk disk using the debootstrap rootfs'
		task :bios => BDB::BIOS_VMDK_FILE_PATH
	end

	#
	# Build devices
	#
	namespace :device do
		desc 'Build a bootable UEFI device using the debootstrap rootfs'
		task :uefi do
			if ENV['dev'].nil? or not File.exists?(ENV['dev'])
				raise ArgumentError, "Invalid device specified"
			end
			builder = UDB.new(DB::DEBOOTSTRAP_ROOTFS_PATH,
				ENV['PARTITION_LAYOUT'],
				dev: ENV.fetch('dev', nil))
			builder.build()
		end

		desc 'Build a bootable BIOS device using the debootstrap rootfs'
		task :bios => BDB::BIOS_VMDK_FILE_PATH do
			if ENV['dev'].nil? or not File.exists?(ENV['dev'])
				raise ArgumentError, "Invalid device specified"
			end
			builder = BDB.new(DB::DEBOOTSTRAP_ROOTFS_PATH,
				ENV['PARTITION_LAYOUT'],
				dev: ENV['dev'])
			builder.build()
		end

	end

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
