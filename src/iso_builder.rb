require_relative 'base_builder'

require 'tmpdir'

class IsoBuilder < BaseBuilder

  def initialize(rootfs_path, output_path)
    raise ArgumentError, 'Missing rootfs' unless File.exists?(rootfs_path)
    raise ArgumentError, 'Bad output file' unless output_path
    @rootfs_path = rootfs_path
    @output_path = output_path
  end

  ##
  #
  #
  def build()
    work_dirs = [ 'unpacked', 'iso', 'iso/isolinux', 'iso/live', 'tools' ]
    work_dirs.each { |dir| execute!("mkdir #{dir}", false) }


    info("Unpacking the rootfs to prepare it for live booting")
    execute!("tar -xzf #{@rootfs_path} -C unpacked")

    info("Installing live-boot pkgs")
    execute!("chroot unpacked apt-get --yes install live-boot")
    execute!("chroot unpacked apt-get --yes install live-boot-initramfs-tools")
    execute!("chroot unpacked update-initramfs -u")

    info("Squashing the modified rootfs")
    execute!("mksquashfs unpacked iso/live/root.squashfs -e boot -no-progress")

    info("Copying kernel and initrd into iso dir")
    execute!("cp unpacked/vmlinuz iso/live/vmlinuz")
    execute!("cp unpacked/initrd.img iso/live/initrd.img")

    download_unpack_isolinux_tools('tools')
    execute!("cp tools/usr/lib/syslinux/modules/bios/* iso/isolinux/", false)
    execute!("cp tools/usr/lib/ISOLINUX/isolinux.bin iso/isolinux/", false)

    info("Writing out isolinux config file")
    File.open("iso/isolinux/isolinux.cfg", 'w') { |f|
      f.write(isolinux_cfg_contents())
    }

    info("Creating ISO (using xorriso)")
    execute!("xorriso "\
      "-as mkisofs "\
      "-r -J "\
      "-joliet-long "\
      "-l -cache-inodes "\
      "-isohybrid-mbr isolinux/usr/lib/ISOLINUX/isohdpfx.bin "\
      "-partition_offset 16 "\
      "-A 'LiveISO' "\
      "-b isolinux/isolinux.bin "\
      "-c isolinux/boot.cat "\
      "-no-emul-boot "\
      "-boot-load-size 4 "\
      "-boot-info-table "\
      "-o #{@output_path} "\
      "./image")

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

  def isolinux_cfg_contents
    return [
      #{}"UI menu.c32",
      "prompt LiveSystem",
      "default LiveSystem",
      "timeout 15",
      "",
      "label LiveSystem",
      " kernel /live/vmlinuz",
      " append initrd=/live/initrd.img boot=live",
      "",
    ].join("\n")
  end

end
