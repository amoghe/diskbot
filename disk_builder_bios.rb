require_relative "disk_builder_base"

class BiosDiskBuilder < DiskBuilder

	BIOS_VMDK_FILE_NAME  = "bios_disk.vmdk"
	BIOS_VMDK_FILE_PATH  = File.join(File.expand_path(File.dirname(__FILE__)), BIOS_VMDK_FILE_NAME)

	PARTITION_TABLE_TYPE = 'gpt'

	GRUB_ARCHITECTURE    = 'i386-pc' # BIOS

	BIOS_EMBED_PARTITION_SIZE  = 32 # MB

	##
	# Additional disk size we need (over and above the common partitions)
	#
	def additional_disk_size
		BIOS_EMBED_PARTITION_SIZE
	end

	##
	# Create the partitions on the disk.
	#
	def create_partitions

		info("Creating disk with #{PARTITION_TABLE_TYPE} parition table")
		execute!("parted -s #{dev} mklabel #{PARTITION_TABLE_TYPE}")

		# Reserve a partition on which grub core.img will reside
		info("Reserving BIOS GRUB boot partition (no fs, #{BIOS_EMBED_PARTITION_SIZE}MB)")
		execute!("parted #{dev} mkpart BIOS_GRUB ext4 1MB #{BIOS_EMBED_PARTITION_SIZE}MB")
		execute!("parted #{dev} set 1 bios_grub on")

		start_size    = BIOS_EMBED_PARTITION_SIZE
		end_size      = BIOS_EMBED_PARTITION_SIZE

		# Create the remaining partitions
		COMMON_PARTITIONS.each_with_index do |part, index|
			start_size = end_size
			end_size += part.size

			info("Creating partition #{part.label} (#{part.fs}, #{part.size}MB)")
			execute!("parted #{dev} mkpart #{part.label} #{part.fs} #{start_size}MB #{end_size}MB")
			execute!("mkfs.#{part.fs} -L \"#{part.label}\" /dev/disk/by-partlabel/#{part.label}")
		end

		nil
	end

	##
	# Install the grub bootloader in a way that BIOS systems can boot it.
	#
	def install_bootloader

		tools_dir = File.join(File.dirname(__FILE__), "scratch")
		execute!("mkdir -p #{tools_dir}", false) # Don't be root for this dir
		self.download_bootloader_tools(tools_dir)

		# mount it at some temp location, and operate on it
		Dir.mktmpdir do |mountdir|
			begin
				grub_part = File.join('/dev/disk/by-label', GRUB_PARTITION_LABEL)
				execute!("mount #{grub_part} #{mountdir}")

				grub_dir = File.join(mountdir, 'boot', 'grub')
				mods_dir = File.join(grub_dir, GRUB_ARCHITECTURE)
				imgs_dir = File.join(grub_dir, 'imgs')

				execute!("mkdir -p #{grub_dir}")
				execute!("mkdir -p #{mods_dir}")
				execute!("mkdir -p #{imgs_dir}")

				core_img_filepath   = File.join(imgs_dir, 'core.img')
				boot_img_filepath   = File.join(imgs_dir, 'boot.img')

				# Setup load.cfg (to be embedded in core.img)
				info("creating core.img (with embedded load.cfg)")
				Tempfile.open('load.cfg') do |f|
					f.puts(load_cfg_contents)
					f.sync; f.fsync # flush ruby buffers and OS buffers

					execute!([ "#{tools_dir}/usr/bin/grub-mkimage",
						"--config=#{f.path}"	,
						"--output=#{core_img_filepath}"	,
						"--directory=#{tools_dir}/usr/lib/grub/#{GRUB_ARCHITECTURE}",
						# core.img needs to know which dir to pick up grub.cfg from
						"--prefix=\"/boot/grub\""	,
						"--format=#{GRUB_ARCHITECTURE}"	,
						# ext2 module handles ext3,4 filesystems
						"biosdisk ext2 part_gpt search" ,
					].join(' '))
				end

				unless File.exists?(core_img_filepath)
					raise RuntimeError, 'No file output from grub-mkimage'
				end

				tools_arch_dir = File.join(tools_dir, "usr/lib/grub/#{GRUB_ARCHITECTURE}")

				# Copy boot.img where it'll be picked up for burning to the disk
				execute!("cp #{tools_arch_dir}/boot.img #{boot_img_filepath}")
				# Copy modules where grub expects to find them
				execute!("cp #{tools_arch_dir}/*.mod #{mods_dir}")
				execute!("cp #{tools_arch_dir}/*.lst #{mods_dir}")

				# Burn boot.img (and core.img) to the disk
				info("Burning boot.img and core.img to the disk")
				execute!([
					"#{tools_dir}/usr/lib/grub/#{GRUB_ARCHITECTURE}/grub-bios-setup",
					"--boot-image=boot.img"    ,
					"--core-image=core.img"    ,
					"--directory=#{imgs_dir} " , # i.e. boot.img & core.img are in this dir
					"--device-map=/dev/null "  ,
					verbose ? '--verbose' : '' ,
					'--skip-fs-probe'          ,
					"#{dev}"                   ,
				].join(' '))

			ensure
				# Always unmount the partition
				execute!("umount #{mountdir}")
			end
		end # Dir.mktempdir , mount partition on tempdir

	ensure
		# Delete the bootloader tools
		execute!("rm -rf #{tools_dir}")
	end

	##
	#
	#
	def create_vmdk
		self.convert_to_vmdk(BIOS_VMDK_FILE_PATH)

		self.save_raw_image(BIOS_VMDK_FILE_PATH + ".raw")
	end

	##
	# Download grub-common and grub-pc-bin instead of relying on the host (on which
	# we're executing) to have these installed.
	# TODO: this still assumes we're on a Debian/Ubuntu host (relies on dpkg and apt-get)
	#
	def download_bootloader_tools(dir)
		execute!("mkdir -p #{dir}", false)
		execute!("cd #{dir} && apt-get download grub-common", false)
		execute!("cd #{dir} && apt-get download grub-pc-bin", false)
		Dir.glob("#{dir}/*.deb") { |pkg| execute!("dpkg-deb --extract #{pkg} #{dir}") }
	end
end
