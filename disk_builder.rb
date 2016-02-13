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

	VMDK_FILE_NAME            = "minbase.vmdk"
	VMDK_FILE_PATH            = File.join(File.expand_path(File.dirname(__FILE__)), VMDK_FILE_NAME)

	PARTITION_TABLE_TYPE      = 'msdos'
	FS_TYPE                   = 'ext4'

	GRUB_ARCHITECTURE         = 'i386-pc' # TODO: infer this?
	GRUB_TIMEOUT              = 5

	GRUB_PARTITION_LABEL      = 'GRUB'
	OS_PARTITION_LABEL        = 'OS'

	PARTITIONS = [
			OpenStruct.new(:type  => :grub,
				:label => GRUB_PARTITION_LABEL,
				:size  => 32),
			OpenStruct.new(:type  => :os,
				:label => OS_PARTITION_LABEL,
				:size  => 4 * 1024),
	]

	TOTAL_DISK_SIZE_MB = PARTITIONS.inject(0) { |memo, elem| memo + elem.size }

	attr_reader :dev
	attr_reader :image_tarball_path
	attr_reader :verbose

	def initialize(image_path, verbose)
		raise ArgumentError, "Invalid image specified: #{image_path}" unless File.exists?(image_path)

		@image_tarball_path = image_path
		@verbose = verbose

		# these will be set later
		@dev      = nil
		@tempfile = nil
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

		notice("Installing grub on disk mbr")
		self.install_grub

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
		execute!("fallocate -l #{TOTAL_DISK_SIZE_MB/1024}G #{@tempfile}", false)

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
		execute!("rm -f #{@tempfile}") if @tempfile && @tempfile.length > 0
	end

	##
	# Create the partitions on the disk.
	#
	def create_partitions
		#TODO: do logical partitions
		if PARTITIONS.count > 4
			raise RuntimeError, 'Cannot create more than 4 partitions'
		end

		execute!("parted -s #{dev} mklabel #{PARTITION_TABLE_TYPE}")

		start_size    = 1 # MB
		end_size      = 1 # MB

		PARTITIONS.each_with_index do |part, index|
			end_size += part.size

			info("Creating partition #{part.label} (#{FS_TYPE}, #{part.size}MB)")

			# create a partition
			execute!("parted #{dev} mkpart primary #{FS_TYPE} #{start_size} #{end_size}MB")

			# put a filesystem and label on it
			execute!("mkfs.#{FS_TYPE} -L \"#{part.label}\" #{dev}p#{index+1}")

			# calculate start for next iteration
			start_size = "#{end_size}MB"
		end

		nil
	end

	##
	# Install the grub bootloader.
	#
	def install_grub

		if not Dir.exists?("/usr/lib/grub/#{GRUB_ARCHITECTURE}")
			raise RuntimeError, 'Cannot perform GRUB2 installation without the '\
			"necessary files (Missing dir #{"/usr/lib/grub/#{GRUB_ARCHITECTURE}"})"
		end

		this_dir = File.dirname(__FILE__)
		temp_dir = File.join(this_dir, "tmp")

		# mount it at some temp location, and operate on it
		Dir.mktmpdir do |mountdir|
			begin
				grub_part = File.join('/dev/disk/by-label', GRUB_PARTITION_LABEL)
				execute!("mount #{grub_part} #{mountdir}")

				# Download grub-common and grub-pc-bin instead of relying on the host (on which
				# we're executing) to have these installed.
				# TODO: this still assumes we're on a Debian/Ubuntu host (relies on dpkg and apt-get)
				info("Downloading grub tools (grub-common, grub-pc-bin)")
				execute!("mkdir -p #{temp_dir}", false)
				execute!("cd #{temp_dir} && apt-get download grub-common", false)
				execute!("cd #{temp_dir} && apt-get download grub-pc-bin", false)
				Dir.glob("#{temp_dir}/*.deb") { |pkg| execute!("dpkg-deb --extract #{pkg} #{temp_dir}") }

				boot_dir = File.join(mountdir, 'boot')
				grub_dir = File.join(boot_dir, 'grub')
				mods_dir = File.join(grub_dir, GRUB_ARCHITECTURE)
				imgs_dir = File.join(grub_dir, 'imgs')

				execute!("mkdir -p #{boot_dir}")
				execute!("mkdir -p #{grub_dir}")
				execute!("mkdir -p #{mods_dir}")
				execute!("mkdir -p #{imgs_dir}")

				load_cfg_filepath   = File.join(grub_dir, 'load.cfg')
				grub_cfg_filepath   = File.join(grub_dir, 'grub.cfg')

				core_img_filepath   = File.join(imgs_dir, 'core.img')
				boot_img_filepath   = File.join(imgs_dir, 'boot.img')

				# Copy boot.img where it'll be picked up for burning to the disk
				execute!("cp #{temp_dir}/usr/lib/grub/#{GRUB_ARCHITECTURE}/boot.img #{boot_img_filepath}")
				# Copy modules where grub expects to find them
				execute!("cp #{temp_dir}/usr/lib/grub/#{GRUB_ARCHITECTURE}/*.mod #{mods_dir}")
				execute!("cp #{temp_dir}/usr/lib/grub/#{GRUB_ARCHITECTURE}/*.lst #{mods_dir}")

				# Setup load.cfg (to be embedded in core.img)
				info("creating load.cfg")
				Tempfile.open('load.cfg') do |f|
					f.puts("search.fs_label #{GRUB_PARTITION_LABEL} root")
					f.puts("set prefix=($root)/boot/grub")

					f.sync; f.fsync # flush ruby buffers and OS buffers
					execute!("cp #{f.path} #{load_cfg_filepath}")
				end

				k_cmdline_opts_normal = [ 'rw', 'quiet', 'splash' ].join(' ')
				k_cmdline_opts_debug  = [ 'rw', 'debug', 'console=tty0' ].join(' ')

				# Setup grub.cfg
				info("creating grub.cfg")
				Tempfile.open('grub.conf') do |f|
					f.puts('set default=0')  # TODO ?
					f.puts('set gfxpayload=1024x768x24')
					f.puts('')

					# OS entry
					f.puts("# #{OS_PARTITION_LABEL}")
					f.puts("menuentry \"#{OS_PARTITION_LABEL}\" {")
					f.puts('  insmod ext2') # also does ext{2,3,4}
					f.puts("  search  --label --set=root --no-floppy #{OS_PARTITION_LABEL}")
					f.puts("  linux   /vmlinuz root=LABEL=#{OS_PARTITION_LABEL} #{k_cmdline_opts_normal}")
					f.puts("  initrd  /initrd.img")
					f.puts('}')
					f.puts('')

					f.sync; f.fsync # flush from ruby buffers, then os buffers

					# Copy it over
					execute!("cp #{f.path} #{grub_cfg_filepath}")
				end

				# create core.img with the embedded configutation file (load.cfg)
				info("Creating core.img")
				execute!([ "#{temp_dir}/usr/bin/grub-mkimage",
					"--config=#{load_cfg_filepath}"	,
					"--output=#{core_img_filepath}"	,
					# Different prefix command (unlike load.cfg)
					"--prefix=\"/boot/grub\""	,
					"--format=#{GRUB_ARCHITECTURE}"	,
					# TODO msdospart? also ext2 covers ext3,4
					"biosdisk ext2 part_msdos search" ,
				].join(' '))

				unless File.exists?(core_img_filepath)
					raise RuntimeError, 'No file output from grub-mkimage'
				end

				# Burn boot.img (and core.img) to the disk
				info("Burning boot.img and core.img to the disk")
				execute!([
					"#{temp_dir}/usr/lib/grub/#{GRUB_ARCHITECTURE}/grub-bios-setup",
					"--boot-image=boot.img"    ,
					"--core-image=core.img"    ,
					"--directory=#{imgs_dir} " , # i.e. boot.img & core.img are in this dir
					"--device-map=/dev/null "  ,
					verbose ? '--verbose' : '' ,
					'--skip-fs-probe'          ,
					"#{dev}"                   ,
				].join(' '))

			ensure
				# Always unmount it
				execute!("umount #{mountdir}")
				execute!("rm -rf #{temp_dir}")
			end
		end

		nil
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

				execute!([ 	'tar ',
					'--gunzip',
					'--extract',
					"--file=#{image_tarball_path}",
					# Perms from the image should be retained.
					# Our job is to only install image to disk.
					'--preserve-permissions',
					'--numeric-owner',
					"-C #{mountdir} ."
				].join(' '))

				fsopts = "defaults,errors=remount-ro"
				fstab_contents = \
				[
					['# <filesystem>'             , '<mnt>', '<type>', '<opts>', '<dump>', '<pass>'],
					["LABEL=#{OS_PARTITION_LABEL}", '/'    , FS_TYPE , fsopts  , '0'     , '1'     ],
				].reduce('') { |memo, line_tokens|
					memo << line_tokens.join("\t")
					memo << "\n"
					memo
				}

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

	def create_vmdk
		execute!("qemu-img convert -f raw -O vmdk #{@tempfile} #{VMDK_FILE_PATH}")

		orig_user = `whoami`.strip
		execute!("chown #{orig_user} #{VMDK_FILE_PATH}")
	end

end
