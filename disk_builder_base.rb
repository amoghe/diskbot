require 'open3'
require 'pp'
require 'ostruct'
require 'tempfile'

require_relative 'base_builder'

#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
# Build disks using images
#
class DiskBuilder < BaseBuilder

	#
	# Constants for the disk build
	#

	GRUB_PARTITION_LABEL      = "GRUB"
	OS_PARTITION_LABEL        = "OS"

	GRUB_PARTITION = OpenStruct.new(
		:label => GRUB_PARTITION_LABEL,
		:fs    => "ext4",
		:size  => 32,
	)

	OS_PARTITION = OpenStruct.new(
		:label => OS_PARTITION_LABEL,
		:fs    => "ext4",
		:size  => (0.75 * 1024.0).to_i,
	)

	# Partitions needed for the system, irrespective of the hardware we're booting on
	COMMON_PARTITIONS = [
		GRUB_PARTITION,
		OS_PARTITION,
	]

	attr_reader :dev
	attr_reader :image_tarball_path
	attr_reader :verbose

	def initialize(image_path, verbose=false)
		raise ArgumentError, "Invalid image specified: #{image_path}" unless File.exists?(image_path)

		@image_tarball_path = image_path
		@verbose = verbose

		# these will be set later
		@dev      = nil
		@tempfile = nil
	end

	##
	# Expects the hardware specific derivative class to implement this.
	#
	def additional_disk_size
		raise RuntimeError, "Not implemented in base class"
	end

	##
	# Expects the hardware specific derivative class to implement this.
	#
	def create_partitions
		raise RuntimeError, "Not implemented in base class"
	end

	##
	# Expects the hardware specific derivative class to implement this.
	#
	def install_bootloader
		raise RuntimeError, "Not implemented in base class"
	end

	##
	#
	#
	def create_vmdk
		raise RuntimeError, "Not implemented in base class"
	end

	##
	# Total disk size we need to allocate
	#
	def total_disk_size
		COMMON_PARTITIONS.inject(0) { |memo, elem| memo + elem.size } + additional_disk_size
	end

	##
	# Image the disk.
	#
	def build
		header("Building disk")

		notice("Creating disk file and loopback device")
		self.create_loopback_disk

		notice("Creating partitions on disk")
		self.create_partitions

		notice("Installing bootloader on disk")
		self.install_bootloader

		notice("Generating bootloader config")
		self.configure_bootloader

		notice("Installing system image on disk partitions")
		self.install_system_image

		notice("Creating vmdk from raw disk")
		self.create_vmdk

	ensure
		notice("Deleting loop disk (and its backing file)")
		self.delete_loopback_disk
	end

	##
	# Create the loopback disk device on which we'll first install the image
	#
	def create_loopback_disk
		@tempfile = "/tmp/tempdisk_#{Time.now.to_i}"
		execute!("fallocate -l #{total_disk_size}MiB #{@tempfile}", false)

		output, _, stat = Open3.capture3("sudo losetup --find")
		raise RuntimeError, 'Failed to find loop device' unless stat.success?

		execute!("losetup #{output.strip} #{@tempfile}")
		@dev = output.strip

		info("Using file  : #{@tempfile}")
		info("Using device: #{dev}")
	end

	##
	# Delete the loopback disk device
	#
	def delete_loopback_disk
		execute!("losetup -d #{dev}") if dev && dev.length > 0
		execute!("rm -f #{@tempfile}", false) if @tempfile && @tempfile.length > 0
	end

	##
	# Configure grub.cfg on the GRUB_PARTITION where it should be picked up
	# irrespective of which hardware configuration we're booting on (bios, uefi).
	#
	def configure_bootloader

		# mount grub partition at some temp location, and operate on it
		Dir.mktmpdir do |mountdir|
			begin
				grub_part = File.join('/dev/disk/by-label', GRUB_PARTITION_LABEL)
				execute!("mount #{grub_part} #{mountdir}")

				grub_dir = File.join(mountdir, 'boot', 'grub')
				execute!("mkdir -p #{grub_dir}")

				# Write out grub.cfg
				info("creating grub.cfg")
				Tempfile.open('grub.conf') do |f|
					f.puts(grub_cfg_contents)
					f.sync; f.fsync # flush ruby buffers, then os buffers
					execute!("cp #{f.path} #{File.join(grub_dir, "grub.cfg")}")
				end
			ensure
				# Always unmount it
				execute!("umount #{mountdir}")
			end
		end
	end

	##
	# Put the image on the disk.
	#
	def install_system_image(num_os=1)
		unless image_tarball_path and File.exists?(image_tarball_path)
			raise RuntimeError, 'Invalid image specified'
		end

		# mount os partition, unpack the image on it, unmount it
		Dir.mktmpdir do |mountdir|
			begin
				execute!("mount #{File.join('/dev/disk/by-label', OS_PARTITION_LABEL)} #{mountdir}")

				execute!(['tar ',
					'--gunzip',
					'--extract',
					"--file=#{image_tarball_path}",
					# Perms from the image should be retained.
					# Our job is to only install image to disk.
					'--preserve-permissions',
					'--numeric-owner',
					"-C #{mountdir} ."
				].join(' '))

				# write out the fstab file
				fstab_file_path = File.join(mountdir, '/etc/fstab')
				Tempfile.open('fstab') do |f|
					f.puts('# This file is autogenerated')
					f.puts(fstab_contents)
					f.sync; f.fsync # flush ruby buffers and OS buffers
					execute!("cp #{f.path} #{fstab_file_path}")
				end

			ensure
				execute!("umount #{mountdir}")
			end
		end

		execute!('sync')

		nil
	end

	##
	# Create a vmdk
	#
	def convert_to_vmdk(dest)
		execute!("qemu-img convert -f raw -O vmdk #{@tempfile} #{dest}")

		orig_user = `whoami`.strip
		execute!("chown #{orig_user} #{dest}")
	end

	##
	# Save the raw disk image we just manipulated.
	# Not really meant to be called from anywhere, but is useful for when you
	# want to save off the raw image at the end of the build
	#
	def save_raw_image(dest)
		execute!("cp #{@tempfile} #{dest}")

		orig_user = `whoami`.strip
		execute!("chown #{orig_user} #{dest}")
	end

	##
	# Contents of grub.cfg
	#
	def grub_cfg_contents
		kernel_opts_normal = [ 'ro', 'quiet', 'splash' ].join(' ')
		kernel_opts_debug  = [ 'ro', 'debug', 'console=tty0' ].join(' ')

		lines = [
			"set default=0",
			"set gfxpayload=1024x768x24",
			"",
			"# #{OS_PARTITION_LABEL}",
			"menuentry \"#{OS_PARTITION_LABEL}\" {",
			"  insmod ext2",
			"  search  --label --set=root --no-floppy #{OS_PARTITION_LABEL}",
			"  linux   /vmlinuz root=LABEL=#{OS_PARTITION_LABEL} #{kernel_opts_normal}",
			"  initrd  /initrd.img",
			"}",
		].join("\n")
	end

	##
	# Contents of load.cfg
	#
	def load_cfg_contents
		[
			"search.fs_label #{GRUB_PARTITION_LABEL} root",
			"set prefix=($root)/boot/grub",
		].join("\n")
	end

	##
	# Contents of the fstab file
	#
	def fstab_contents

		fsopts = "defaults,errors=remount-ro"

		[
			['# <filesystem>'               , '<mnt>', '<type>', '<opts>', '<dump>', '<pass>'],
			["LABEL=#{OS_PARTITION_LABEL}"  , '/'    , 'ext4'  , fsopts  , '0'     , '1'     ],
			["LABEL=#{GRUB_PARTITION_LABEL}", '/grub', 'ext4'  , fsopts  , '0'     , '1'     ],
		].reduce('') { |memo, line_tokens|
			memo << line_tokens.join("\t")
			memo << "\n"
			memo
		}
	end

end
