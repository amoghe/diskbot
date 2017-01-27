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

	PARTITION_TABLE_TYPE      = 'gpt'
	FIRST_PARTITION_OFFSET    = 1 # offset from start of disk (in MiB)

	##
	# C'tor
	# dev: [string] optionally specify block device to operate on
	#
	def initialize(image_path, dev: nil)
		raise ArgumentError, "Missing image #{image_path}" unless File.exists?(image_path)

		@image_tarball_path = image_path
		@dev      = dev
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
	# From the partition_layout, pick the first partition marked as :grub_cfg
	#
	def first_grub_cfg_partition
		grub_part = partition_layout.select { |p| p.grub_cfg == true }.first
		raise RuntimeError, 'Missing grub partition' unless grub_part
		return grub_part
	end

	##
	# From the #partition_layout, pick the first partition marked as :os
	#
	def first_os_partition
		os_part = partition_layout.detect { |p| p.os == true }
		return os_part if os_part

		# Next look for an OS in a LVM partition
		lvm_part = partition_layout.detect { |p| p.lvm != nil }
		raise RuntimeError, 'OS and LVM partitions missing' unless lvm_part

		os_part = lvm_part.lvm.volumes.detect { |p| p.os == true }
		raise RuntimeError, 'No partitions marked as OS' unless os_part
		return os_part
	end

	##
	# Image the disk.
	#
	def build
		header("Building disk")
		if @dev == nil
			self.with_loopback_disk { self.__build_on_dev }
		else
			self.__build_on_dev
		end
	end

	##
	# Perform the actual build, assuming @dev is setup
	#
	def __build_on_dev
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
	end

	##
	# Execute the specified block having setup a loopback device as @dev
	#
	def with_loopback_disk
		notice("Creating disk file and loopback device")
		self.create_loopback_disk
		yield if block_given?
	ensure
		notice("Deleting loop disk (and its backing file)")
		self.delete_loopback_disk
	end

	##
	# Expects the hardware specific derivative class to implement this.
	#
	def create_partitions
		info("Creating disk with #{PARTITION_TABLE_TYPE} parition table")
		execute!("parted -s #{@dev} mklabel #{PARTITION_TABLE_TYPE}")

		start_size = FIRST_PARTITION_OFFSET
		end_size   = FIRST_PARTITION_OFFSET

		# Create the partitions
		partition_layout.each_with_index do |part, index|
			start_size = end_size
			end_size  += part.size_mb

			info("Creating partition #{part.label} (#{part.fs}, #{part.size_mb}MiB)")
			execute!("parted #{@dev} mkpart #{part.label} #{part.fs} #{start_size}MiB #{end_size}MiB")

			(part.flags || {}).each_pair { |k, v|
				info("Setting partition flag #{k} to #{v}")
				execute!("parted #{@dev} set #{index+1} #{k} #{v}")
			}

			label_path = "/dev/disk/by-partlabel/#{part.label}"
			if not part.fs
				warn("No filesystem specified for #{part.label}. Skipping FS")
			elsif part.fs == 'fat32'
				execute!("mkfs.fat -F32 -n#{part.label} #{label_path}")
			elsif part.fs == 'fat16'
				execute!("mkfs.fat -F16 -n#{part.label} #{label_path}")
			else
				execute!("mkfs.#{part.fs} -L \"#{part.label}\" #{label_path}")
			end

			if part.lvm
				notice("Setting up LVM on #{part.label}")
				setup_lvm_on_partition(part)
			end

		end
		nil
	end

	##
	# Setup LVM on this partition (single PV, VG - multiple LVs)
	#
	def setup_lvm_on_partition(part)
		return unless part.lvm
		pvol = "/dev/disk/by-partlabel/#{part.label}"
		execute!("pvcreate #{pvol}")
		execute!("vgcreate #{part.lvm.vg_name} #{pvol}")

		notice("Creating LVM partitions")
		part.lvm.volumes.each do |vol|
			info("Creating #{vol.label} volume")
			execute!("lvcreate --name #{vol.label} --size #{vol.size_mb}MiB #{part.lvm.vg_name}")
			execute!("mkfs.#{vol.fs} -L \"#{vol.label}\" /dev/#{part.lvm.vg_name}/#{vol.label}")
		end

		breakpoint()
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

		info("Using loop device #{@dev} backed by file #{@tempfile}")
	end

	##
	# Delete the loopback disk device
	#
	def delete_loopback_disk
		execute!("losetup -d #{@dev}") if @dev && @dev.length > 0
		execute!("rm -f #{@tempfile}", false) if @tempfile && @tempfile.length > 0
	end

	##
	# Configure grub.cfg on the partition marked as :grub_cfg. (irrespective
	# of which disk configuration we're booting on - bios or uefi).
	#
	def configure_bootloader

		grub_part = first_grub_cfg_partition()

		# mount grub partition at some temp location, and operate on it
		Dir.mktmpdir do |mountdir|
			begin
				grub_part = File.join('/dev/disk/by-label', grub_part.label)
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
	def install_system_image()
		unless @image_tarball_path and File.exists?(@image_tarball_path)
			raise RuntimeError, 'Invalid image specified'
		end

		# We only install to the first OS partition, for now (TODO)
		os_part = first_os_partition()

		# mount os partition, unpack the image on it, unmount it
		Dir.mktmpdir do |mountdir|
			begin
				os_part_path = File.join('/dev/disk/by-label', os_part.label)
				execute!("mount #{os_part_path} #{mountdir}")

				execute!(['tar ',
					'--gunzip',
					'--extract',
					"--file=#{@image_tarball_path}",
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
					f.puts(fstab_contents(os_part.label))
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
		execute!("qemu-img convert -f raw -O vmdk #{@dev} #{dest}")

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
	# Add as many entries as there are OS partitions (assuming each has a
	# bootable working OS - TODO: install OS on all eligible partitions).
	#
	def grub_cfg_contents
		kernel_opts_normal = [ 'ro', 'quiet', 'splash' ].join(' ')
		kernel_opts_debug  = [ 'ro', 'debug', 'console=tty0' ].join(' ')

		lines = [
			"set default=0",
			"set gfxpayload=1024x768x24",
			""
		]

		partition_layout.select { |p| p.os == true }.each { |os_part|
			lines += [
				"# #{os_part.label}",
				"menuentry \"#{os_part.label}\" {",
				"  insmod ext2",
				"  search  --label --set=root --no-floppy #{os_part.label}",
				"  linux   /vmlinuz root=LABEL=#{os_part.label} #{kernel_opts_normal}",
				"  initrd  /initrd.img",
				"}",
				"",
			]
		}

		return lines.join("\n")
	end

	##
	# Contents of load.cfg
	#
	def load_cfg_contents
		# We assume (safely) that there'll only be ONE grub cfg partition.
		# There can't be more than one since grub cannot read from more than one.
		grub_part = first_grub_cfg_partition
		[
			"search.fs_label #{grub_part.label} root",
			"set prefix=($root)/boot/grub",
		].join("\n")
	end

	##
	# Contents of the fstab file
	# The os_part_label arg tells us which OS this fstab is for, and hence which
	# one to mount at '/'
	#
	def fstab_contents(os_part_label)

		fsopts = "defaults,errors=remount-ro"
		# We assume (safely) that there'll only be ONE grub cfg partition.
		# There can't be more than one since grub cannot read from more than one.
		grub_part = first_grub_cfg_partition

		[
			['# <filesystem>'          , '<mnt>', '<type>', '<opts>', '<dump>', '<pass>'],
			["LABEL=#{os_part_label}"  , '/'    , 'ext4'  , fsopts  , '0'     , '1'     ],
			["LABEL=#{grub_part.label}", '/grub', 'ext4'  , fsopts  , '0'     , '1'     ],
		].reduce('') { |memo, line_tokens|
			memo << line_tokens.join("\t")
			memo << "\n"
			memo
		}
	end

end
