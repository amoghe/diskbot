require_relative "disk_builder_base"

class UefiDiskBuilder < DiskBuilder

	GRUB_ARCHITECTURE    = 'x86_64-efi' # What grub calls UEFI booting

	##
	# Additional partitions needed to install bootloader
	#
	def bootloader_partitions
		return [
			{
				"label"    => "ESP",
				"fs"       => "fat32",
				"size_mb"  => 512,
				"flags"    => {"boot" => "on"},
				"esp"      => true
			},
			{
				"label"    => "GRUB_CFG",
				"fs"       => "ext4",
				"size_mb"  => 32,
				"flags"    => {},
				"grub_cfg" => true,
			},
		]
	end

	##
	# Install the grub bootloader in a way that UEFI systems can boot it.
	#
	def install_bootloader

		tools_dir = File.join(File.dirname(__FILE__), "tools")
		execute!("mkdir -p #{tools_dir}", false) # Don't be root for this dir
		self.download_bootloader_tools(tools_dir)

		esp_part = @partition_layout.find { |p| p.esp }
		raise RuntimeError, "Missing ESP partition" if not esp_part

		# mount it at some temp location, and write our files to it
		Dir.mktmpdir do |mountdir|
			begin
				grub_part = File.join('/dev/disk/by-label', esp_part.label)
				execute!("mount #{grub_part} #{mountdir}")

				boot_dir = File.join(mountdir, 'EFI', 'BOOT')
				execute!("mkdir -p #{boot_dir}")

				grub_cfg_filepath   = File.join(boot_dir, 'grub.cfg')
				boot_efi_filepath   = File.join(boot_dir, 'bootx64.efi')

				# Create the bootloader with the embedded configutation file (load.cfg)
				info("creating bootx64.efi (with embedded load.cfg)")
				Tempfile.open('load.cfg') do |f|
					f.puts(load_cfg_contents)
					f.sync; f.fsync # flush ruby buffers and OS buffers

					execute!([
						"#{tools_dir}/usr/bin/grub-mkimage",
						"--config=#{f.path}"	,
						"--output=#{boot_efi_filepath}"	,
						"--directory=#{tools_dir}/usr/lib/grub/#{GRUB_ARCHITECTURE}",
						# core.img needs to know which dir to pick up grub.cfg from
						"--prefix=\"/EFI/BOOT\""	,
						"--format=#{GRUB_ARCHITECTURE}"	,
						# modules to bake into the img
						"cat echo ext2 fat search part_gpt part_msdos efifwsetup efi_gop efi_uga",
						"gfxterm gfxterm_background gfxterm_menu test all_video loadenv",
						"normal boot configfile linux linuxefi lvm"
					].join(' '))
				end

				unless File.exists?(boot_efi_filepath)
					raise RuntimeError, 'No file output from grub-mkimage'
				end

			ensure
				# Always unmount it
				execute!("umount #{mountdir}")
			end
		end # Dir.mktempdir, mount partition on tempdir

	ensure
		# Clean up temp dir where we downloaded grub tools
		execute!("rm -rf #{tools_dir}")
	end

	##
	# Download grub-common and grub-pc-bin instead of relying on the host (on which
	# we're executing) to have these installed.
	# TODO: this still assumes we're on a Debian/Ubuntu host (relies on dpkg and apt-get)
	#
	def download_bootloader_tools(dir)
		execute!("mkdir -p #{dir}", false)
		execute!("cd #{dir} && apt-get download grub-common", false)
		execute!("cd #{dir} && apt-get download grub-efi-amd64-bin", false)
		Dir.glob("#{dir}/*.deb") { |pkg| execute!("dpkg-deb --extract #{pkg} #{dir}") }
	end

end
