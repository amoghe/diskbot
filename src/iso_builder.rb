require_relative 'base_builder'

require 'tmpdir'

class IsoBuilder < BaseBuilder

  def initialize(rootfs_path, output_path)
    raise ArgumentError, 'Missing rootfs' unless File.exists?(rootfs_path)
    raise ArgumentError, 'Bad output file' unless output_path
    @rootfs_path = rootfs_path
    @output_path = output_path

    @bootloader = "grub" # TODO: make this configurable
    @bootmode   = "bios" # TODO: make this configurable

    @decompress_switch = ''
    if rootfs_path.end_with?('gz')
      @decompress_switch = '-z'
    elsif rootfs_path.end_with?('bz2')
      @decompress_switch = '-j'
    end
   end

  def build
    case @bootloader
    when "isolinux"
      notice "Building ISO using isolinux as bootloader"
      self.build_isolinux()
    when "grub"
      notice("Building ISO using grub as bootloader")
      self.build_grub()
    else
      notice("Building ISO using grub as bootloader")
      self.build_grub()
    end
  end

  ##
  # Build the iso with isolinux as the bootloader
  #
  def build_isolinux()
    info("Ensure (temporary) workspace dirs exist")
    work_dirs = [ 'unpacked', 'iso', 'iso/isolinux', 'iso/live', 'tools' ]
    work_dirs.each { |dir| execute!("mkdir #{dir}", false) }

    info("Unpacking the rootfs to prepare it for live booting")
    execute!("tar #{@decompress_switch} -xf #{@rootfs_path} -C unpacked")

    info("Installing live-boot pkgs")
    execute!("chroot unpacked apt-get --yes install live-boot")
    execute!("chroot unpacked apt-get --yes install live-boot-initramfs-tools")
    execute!("chroot unpacked update-initramfs -u")

    info("Squashing the modified rootfs")
    execute!("mksquashfs unpacked iso/live/root.squashfs -no-progress")

    info("Copying kernel and initrd into iso dir")
    execute!("cp unpacked/vmlinuz iso/live/vmlinuz")
    execute!("cp unpacked/initrd.img iso/live/initrd.img")

    download_unpack_isolinux_tools('tools')
    execute!("cp tools/usr/lib/syslinux/modules/bios/* iso/isolinux/", false)
    execute!("cp tools/usr/lib/ISOLINUX/isolinux.bin iso/isolinux/", false)

    info("Writing out isolinux config file")
    File.open("iso/isolinux/isolinux.cfg", 'w') { |f|
      f.write(self.isolinux_cfg_contents())
    }

    info("Creating ISO (using xorriso)")
    execute!("xorriso "\
      "-as mkisofs "\
      "-r -J "\
      "-joliet-long "\
      "-l -cache-inodes "\
      "-isohybrid-mbr tools/usr/lib/ISOLINUX/isohdpfx.bin "\
      "-partition_offset 16 "\
      "-A 'LiveISO' "\
      "-b isolinux/isolinux.bin "\
      "-c isolinux/boot.cat "\
      "-no-emul-boot "\
      "-boot-load-size 4 "\
      "-boot-info-table "\
      "-o #{@output_path} "\
      "iso")

  ensure
    info("deleting (temporary) work dirs")
    work_dirs.each { |d| execute!("rm -rf #{d}") }
    nil
  end

  ##
  #
  #
  def build_grub
    info("Ensure (temporary) workspace dirs exist")
    work_dirs = [ 'unpacked', 'iso', 'iso/boot/grub', 'iso/live', 'tools' ]
    work_dirs.each { |dir| execute!("mkdir -p #{dir}", false) }

    info("Unpacking the rootfs to prepare it for live booting")
    execute!("tar -xzf #{@rootfs_path} -C unpacked")

    info("Installing live-boot pkgs")
    execute!("chroot unpacked apt-get update")
    execute!("chroot unpacked apt-get --yes install live-boot")
    execute!("chroot unpacked apt-get --yes install live-boot-initramfs-tools")
    execute!("chroot unpacked update-initramfs -u")

    info("Squashing the modified rootfs")
    execute!("mksquashfs unpacked iso/live/root.squashfs -no-progress")

    info("Copying kernel and initrd into iso dir")
    execute!("cp unpacked/vmlinuz iso/live/vmlinuz")
    execute!("cp unpacked/initrd.img iso/live/initrd.img")

    download_unpack_grub_tools('tools')

    info("Writing out isolinux config file")
    File.open("iso/boot/grub/grub.cfg", 'w') { |f|
      f.write(self.grub_cfg_contents())
    }

    grub_arch = (@bootmode == "bios") ? "i386-pc" : "x86_64-efi"
    info("Using grub arch: #{grub_arch}")

    info("Creating ISO (using grub-mkrescue)")
    execute!(["grub-mkrescue",
      "-d tools/usr/lib/grub/#{grub_arch}",
      "-o #{@output_path}",
      "./iso",
      "-- -iso-level 3", # in case the squashfs file is >4GiB
    ].join(" "))

  ensure
    info("deleting (temporary) work dirs")
    work_dirs.each { |d| execute!("rm -rf #{d}") }
    nil
  end

  ##
  # Download and unpack the isolinux tools into the specified dir.
  #
  def download_unpack_isolinux_tools(dir)
    execute!("cd #{dir} && apt-get download isolinux", false)
    execute!("cd #{dir} && apt-get download syslinux-common", false)
    Dir.glob("#{dir}/*.deb") { |pkg| execute!("dpkg-deb --extract #{pkg} #{dir}") }
  end

  def download_unpack_grub_tools(dir)
    grubpkgname = (@bootmode == "bios") ? "grub-pc-bin" : "grub-efi-amd64-bin"
		execute!("mkdir -p #{dir}", false)
		execute!("cd #{dir} && apt-get download grub-common", false)
		execute!("cd #{dir} && apt-get download #{grubpkgname}", false)
		Dir.glob("#{dir}/*.deb") { |pkg| execute!("dpkg-deb --extract #{pkg} #{dir}") }
	end

  ##
  # File contents for the isolinux config file
  #
  def isolinux_cfg_contents
    return [
      "UI menu.c32",
      "PROMPT LiveCD",
      "DEFAULT 1",
      "TIMEOUT 15",
      "MENU RESOLUTION 1024 768",
      "",
      "LABEL 1",
      "  MENU DEFAULT",
      "  MENU LABEL ^LiveCD",
      "  KERNEL /live/vmlinuz",
      "  APPEND initrd=/live/initrd.img boot=live quiet splash",
      "",
      "LABEL 2",
      "  MENU LABEL ^LiveCD (verbose)",
      "  KERNEL /live/vmlinuz",
      "  APPEND initrd=/live/initrd.img boot=live",
      "",
    ].join("\n")
  end

  def grub_cfg_contents
    [
      "set default=0",
      "set timeout=10",
      "set gfxpayload=1024x768x24",
      "",
      "menuentry \"Live CD\" {",
      "  linux  /live/vmlinuz boot=live console=tty0 quiet splash",
      "  initrd /live/initrd.img",
      "}",
      "",
      "menuentry \"Live CD (debug)\" {",
      "  linux  /live/vmlinuz boot=live console=tty0 debug",
      "  initrd /live/initrd.img",
      "}",
    ].join("\n")
  end

end
