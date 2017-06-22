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

# Helper to test if the env contains all the vars specified
def ensure_var(var)
	if not ENV.has_key?(var)
		puts("Please set env var: #{var}")
		exit(1)
	end
end

# Ensure one of the TMPFS_{DIR|SIZEMB} params are specified
def ensure_tmpfs_params()
	if not ENV['TMPFS_SIZEMB'] and not ENV['TMPFS_DIR']
		puts "One of TMPFS_SIZEMB or TMPFS_DIR must be specified"
		puts "* These are used to create a temp dir or use an existing temp dir"
		exit(1)
	end
end

# Helper to ensure that env contains DEVICE or one of TMPFS_{DIR|SIZEMB}
def ensure_device_or_tmpfs_params()
	if not ENV['DEVICE'] and not ENV['TMPFS_SIZEMB'] and not ENV['TMPFS_DIR']
		puts "One of DEVICE or TMPFS_SIZEMB or TMPFS_DIR must be specified"
		puts "* When DEVICE is specified, that block device is as workspace"
		puts "* When TMPFS_{SZ|DIR} are specified, a loopback device is on a tmpfs"
		exit(1)
	end
end

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
		ensure_var('CUSTOMIZE_PKGS')
		ensure_tmpfs_params()
		builder = DebootstrapBuilder.new(distro,
			DEBOOTSTRAP_CACHE_PATH,
			customize_pkgs: ENV['CUSTOMIZE_PKGS'],
			apt_mirror_url: ENV['APT_MIRROR_URL'],
			verbose: verbose)
		builder.create_debootstrap_packages_tarball()
	end

	# How to build a basic rootfs using debootstrap.
	# This relies on a tarball of cached packages that is usable by debootstrap.
	file ROOTFS_TGZ_PATH => DEBOOTSTRAP_CACHE_PATH do
		ensure_var('CUSTOMIZE_PKGS')
		ensure_var('CUSTOMIZE_SCRIPT')
		ensure_var('OVERLAY_ROOTFS')
		ensure_tmpfs_params()

		builder = DebootstrapBuilder.new(distro,
			ROOTFS_TGZ_PATH,
			debootstrap_pkg_cache: DEBOOTSTRAP_CACHE_PATH,
			customize_pkgs:        ENV['CUSTOMIZE_PKGS'],
			customize_rootfs:      ENV['CUSTOMIZE_SCRIPT'],
			overlay_rootfs:        ENV['OVERLAY_ROOTFS'],
			apt_mirror_url:        ENV['APT_MIRROR_URL'],
			verbose: verbose)
		builder.create_debootstrap_rootfs()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file UEFI_VMDK_FILE_PATH => ROOTFS_TGZ_PATH do
		ensure_var('PARTITION_LAYOUT')
		ensure_device_or_tmpfs_params()

		builder = UefiDiskBuilder.new(ROOTFS_TGZ_PATH, ENV['PARTITION_LAYOUT'],
			outfile: UEFI_VMDK_FILE_PATH,
			dev:     ENV['DEVICE'])
		builder.build()
	end

	# How to build a disk (vmdk) given a rootfs (created by debootstrap).
	file BIOS_VMDK_FILE_PATH => ROOTFS_TGZ_PATH do
		ensure_var('PARTITION_LAYOUT')
		ensure_device_or_tmpfs_params()

		builder = BiosDiskBuilder.new(ROOTFS_TGZ_PATH, ENV['PARTITION_LAYOUT'],
			outfile: BIOS_VMDK_FILE_PATH,
			dev:     ENV['DEVICE'])
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
			ensure_env(['DEVICE'])
			builder = UefiDiskBuilder.new(ROOTFS_TGZ_PATH,
				ENV['PARTITION_LAYOUT'],
				dev: ENV['DEVICE'])
			builder.build()
		end

		desc 'Build a bootable BIOS device using the debootstrap rootfs'
		task :bios do
			ensure_env(['DEVICE'])
			builder = BiosDiskBuilder.new(ROOTFS_TGZ_PATH,
				ENV['PARTITION_LAYOUT'],
				dev: ENV['DEVICE'])
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

	namespace :vmdk do

		desc "Clean the UEFI disk file"
		task :uefi do
			sh("rm -f #{UEFI_VMDK_FILE_PATH}")
		end

		desc "Clean the BIOS disk file"
		task :bios do
			sh("rm -f #{BIOS_VMDK_FILE_PATH}")
		end

		desc "Clean all VMDK disk files"
		task :all => [:bios, :uefi]

	end

	task :device do
		ensure_env(["DEVICE"])
		dev = ENV['DEVICE']
		raise ArgumentError, "Invalid device " unless File.exists?(dev)

		pvs = []
		vgs = []
		Dir.glob("#{dev}p*") do |part|
			pv = `sudo pvs -S pv_name=#{part} -o pv_name --noheadings | grep #{part}`.strip
			next if pv.empty? # grep didnt find anything, so this isn't a pv
			pvs << pv

			vg_name = `sudo pvs -S pv_name=#{part} -o vg_name --noheadings`.strip
			next if vg_name.empty?
			vgs << vg_name
		end

		vgs.uniq.each { |vg| sh("sudo vgchange -an #{vg}") }
		vgs.uniq.each { |vg| sh("sudo vgremove -y  #{vg}") }
		pvs.uniq.each { |pv| sh("sudo pvremove #{pv}") }
		sh("sudo partx -d #{dev}")
		sh("sudo dd if=/dev/zero of=#{dev} bs=4M output=progress")
	end

end

# Allow folks to include customizations to this workflow without having to
# maintain their own fork of this repo. For example,
# - you could take any of the rake tasks above and instantiate the worker
#   objects with different params to get different behavior
# - inherit from any of the classes under src/ and override some methods to
#   get different behavior (e.g. different text in grub_cfg_contents)
if Dir.exists?('./tasks')
	Dir.glob('tasks/*.rake').each { |r| import r }
end
