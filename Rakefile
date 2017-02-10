# Rake tasks for building the various parts of the system
#

require_relative 'src/debootstrap_builder'
require_relative 'src/disk_builder_bios'
require_relative 'src/disk_builder_uefi'
require_relative 'src/iso_builder'

distro  = "ubuntu" # or "debian"
livecd  = false
verbose = ENV.has_key?('VERBOSE')

# Rake always ensures CWD is the dir containing the Rakefile
OUTPUT_DIR = 'output'
Dir.mkdir(OUTPUT_DIR) rescue Errno::EEXIST
# File names
DEBOOTSTRAP_CACHE_NAME = "debootstrap_cache.tgz"
ROOTFS_TGZ_NAME        = "rootfs.tgz"
BIOS_VMDK_FILE_NAME    = "bios_disk.vmdk"
UEFI_VMDK_FILE_NAME    = "uefi_disk.vmdk"
LIVECD_ISO_FILE_NAME   = "live-cd.iso"
# File paths (in the output dir)
DEBOOTSTRAP_CACHE_PATH = File.join(OUTPUT_DIR, DEBOOTSTRAP_CACHE_NAME)
ROOTFS_TGZ_PATH        = File.join(OUTPUT_DIR, ROOTFS_TGZ_NAME)
BIOS_VMDK_FILE_PATH    = File.join(OUTPUT_DIR, BIOS_VMDK_FILE_NAME)
UEFI_VMDK_FILE_PATH    = File.join(OUTPUT_DIR, UEFI_VMDK_FILE_NAME)
LIVECD_ISO_FILE_PATH   = File.join(OUTPUT_DIR, LIVECD_ISO_FILE_NAME)

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Prerequisite software check tasks
#
namespace :prereqs do

	desc "Check if prerequisite software is present"
	task :check do
		{
			# tool:        pkgs_that_provides_it_on_xenial
			'blockdev':    'util-linux',
			'debootstrap': 'debootstrap',
			'fallocate':   'util-linux',
			'losetup':     'mount',
			'mkfs.ext4':   'e2fsprogs',
			'parted':      'parted',
			'partx':       'util-linux',
			'qemu-img':    'qemu-utils',
			'mksquashfs':  'squashfs-tools',
			'xorriso':     'xorriso',
		}\
		.each_pair do |tool, pkg|
			sh("which #{tool}") do |ok, res|
				puts "Missing #{tool}." \
				"Run: 'sudo apt-get install #{pkg}'" if not ok
			end
		end
	end

end

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# build tasks
#
namespace :build do

	# How to build a cache of pkgs needed for speeding up debootstrap runs.
	file DEBOOTSTRAP_CACHE_PATH do
		builder = DebootstrapBuilder.new(distro,
			DEBOOTSTRAP_CACHE_PATH,
			customize_pkgs: ENV['CUSTOMIZE_PKGS'],
			verbose: verbose)
		builder.create_debootstrap_packages_tarball()
	end

	# How to build a basic rootfs using debootstrap.
	# This relies on a tarball of cached packages that is usable by debootstrap.
	file ROOTFS_TGZ_PATH => DEBOOTSTRAP_CACHE_PATH do
		builder = DebootstrapBuilder.new(distro,
			ROOTFS_TGZ_PATH,
			debootstrap_pkg_cache: DEBOOTSTRAP_CACHE_PATH,
			customize_pkgs:        ENV['CUSTOMIZE_PKGS'],
			customize_rootfs:      ENV['CUSTOMIZE_SCRIPT'],
			overlay_rootfs:        ENV['OVERLAY_ROOTFS'],
			verbose: verbose)
		builder.create_debootstrap_rootfs()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file UEFI_VMDK_FILE_PATH => ROOTFS_TGZ_PATH do
		builder = UefiDiskBuilder.new(ROOTFS_TGZ_PATH, ENV['PARTITION_LAYOUT'],
			outfile: UEFI_VMDK_FILE_PATH,
			dev:     ENV.fetch('dev', nil))
		builder.build()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file BIOS_VMDK_FILE_PATH => ROOTFS_TGZ_PATH do
		builder = BiosDiskBuilder.new(ROOTFS_TGZ_PATH, ENV['PARTITION_LAYOUT'],
			outfile: BIOS_VMDK_FILE_PATH,
			dev:     ENV.fetch('dev', nil))
		builder.build()
	end

	#
	# Build a tarball of cached deb packages usable by debootstrap.
	#
	desc 'Build debootstrap package cache (supports some env vars)'
	task :cache => DEBOOTSTRAP_CACHE_PATH

	#
	# Build a basic rootfs using debootstrap.
	#
	desc 'Build basic rootfs using debootstrap (supports some env vars)'
	task :rootfs => ROOTFS_TGZ_PATH

	desc 'Build (live cd) ISO using the debootstrap rootfs'
	task :iso => ROOTFS_TGZ_PATH do
			IsoBuilder.new(ROOTFS_TGZ_PATH, LIVECD_ISO_FILE_PATH).build
	end

	#
	# Build vmdks.
	#
	namespace :vmdk do
		desc 'Build a bootable UEFI vmdk disk using the debootstrap rootfs'
		task :uefi => UEFI_VMDK_FILE_PATH

		desc 'Build a bootable BIOS vmdk disk using the debootstrap rootfs'
		task :bios => BIOS_VMDK_FILE_PATH
	end

	#
	# Build devices
	#
	namespace :device do
		desc 'Build a bootable UEFI device using the debootstrap rootfs'
		task :uefi do
			raise ArgumentError, "No device specified" if ENV['dev'].nil?
			raise ArgumentError, "Bad device file" unless File.exists?(ENV['dev'])

			builder = UefiDiskBuilder.new(ROOTFS_TGZ_PATH,
				ENV['PARTITION_LAYOUT'],
				dev: ENV['dev'])
			builder.build()
		end

		desc 'Build a bootable BIOS device using the debootstrap rootfs'
		task :bios do
			if ENV['dev'].nil? or not File.exists?(ENV['dev'])
				raise ArgumentError, "Invalid device specified"
			end
			builder = BiosDiskBuilder.new(ROOTFS_TGZ_PATH,
				ENV['PARTITION_LAYOUT'],
				dev: ENV['dev'])
			builder.build()
		end
	end

end

# - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Clean tasks
#
namespace :clean do

	desc "Clean the debootstrap rootfs file"
	task :cache do
		sh("rm -f #{DEBOOTSTRAP_CACHE_PATH}")
	end

	desc "Clean the debootstrap rootfs file"
	task :rootfs do
		sh("rm -f #{ROOTFS_TGZ_PATH}")
	end

	desc "Clean the ISO file"
	task :iso do
		sh("rm -f #{LIVECD_ISO_FILE_PATH}")
	end

	desc "Clean the UEFI disk file"
	task :vmdk_uefi do
		sh("rm -f #{UEFI_VMDK_FILE_PATH}")
	end

	desc "Clean the BIOS disk file"
	task :vmdk_bios do
		sh("rm -f #{BIOS_VMDK_FILE_PATH}")
	end

	desc "Clean all disk files"
	task :disks => [:vmdk_uefi, :vmdk_bios]
end
