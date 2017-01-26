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
	PARTITION_TABLE_TYPE      = 'gpt'
	FIRST_PARTITION_OFFSET    = 1 # offset from start of disk (in MiB)

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
	# Return the array of partitions we'd like to create - derived classes will
	# define this per their needs.
	#
	def partition_layout
		raise RuntimeError, "Not implemented in base class"
	end

	##
	# Expects the hardware specific derivative class to implement this.
	#
	def install_bootloader
		raise RuntimeError, "Not implemented in base class"
	end

	##
	# Create the vmdk file from the disk
	#
	def create_vmdk
		raise RuntimeError, "Not implemented in base class"
	end

	##
	# Total disk size we need to allocate (relies on partition_layout)
	# = all partition sizes
	# + first offest (from left end)
	# + 1MB for end since parted uses END as inclusive
	#
	def total_disk_size
		partition_layout.inject(0) { |memo, elem| memo + elem.size_mb } \
			+ FIRST_PARTITION_OFFSET \
			+ 1
	end

	##
	# Expects the hardware specific derivative class to implement this.
	#
	def create_partitions
		info("Creating disk with #{PARTITION_TABLE_TYPE} parition table")
		execute!("parted -s #{dev} mklabel #{PARTITION_TABLE_TYPE}")

		start_size = FIRST_PARTITION_OFFSET
		end_size   = FIRST_PARTITION_OFFSET

		# Create the partitions
		partition_layout.each_with_index do |part, index|
			start_size = end_size
			end_size  += part.size_mb

			info("Creating partition #{part.label} (#{part.fs}, #{part.size_mb}MiB)")
			execute!("parted #{dev} mkpart #{part.label} #{part.fs} #{start_size}MiB #{end_size}MiB")

			(part.flags || {}).each_pair { |k, v|
				info("Setting partition flag #{k} to #{v}")
				execute!("parted #{dev} set #{index+1} #{k} #{v}")
			}

			label_path = "/dev/disk/by-partlabel/#{part.label}"
			if part.fs == 'fat32'
				execute!("mkfs.fat -F32 -n#{part.label} #{label_path}")
			elsif part.fs == 'fat16'
				execute!("mkfs.fat -F16 -n#{part.label} #{label_path}")
			else
				execute!("mkfs.#{part.fs} -L \"#{part.label}\" #{label_path}")
			end

		end
		nil
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
				os_part_path = File.join('/dev/disk/by-label', OS_PARTITION_LABEL)
				execute!("mount #{os_part_path} #{mountdir}")

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
