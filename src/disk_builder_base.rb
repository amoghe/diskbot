require 'open3'
require 'pp'
require 'ostruct'
require 'tempfile'
require 'json'

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
  #
  # One of the following must be provided:
  # dev: [string] block device we operate on
  # outfile: [string] save block device as vmdk to this file
  # use_system_grub_tools: [bool] whether to download grub tools or use existing
  #
  def initialize(image_path, playout_path,
                 outfile: nil,
                 dev:     nil,
                 use_system_grub_tools: false)

    @tempfile = nil

    raise ArgumentError, "Missing image file" unless File.exists?(image_path)

    @image_tarball_path = image_path

    raise ArgumentError, "Missing layout file" unless File.exists?(playout_path)

    parts = JSON.parse(File.read(playout_path))

    raise ArgumentError, "Partition not an Array" unless parts.kind_of?(Array)

    @partition_layout = (bootloader_partitions + parts).map { |p| DeepStruct.new(p) }

    self.validate_partition_layout()

    if outfile
      @outfile = outfile
    end

    if dev
      @dev = dev
      self.validate_disk_size
    end

    if dev.nil? and outfile.nil?
      raise ArgumentError, "No output file OR device specified!"
    end

    @use_systemwide_grub_tools = use_system_grub_tools
  end

  ##
  # Platform specific partitions (needed by bootloader)
  #
  def bootloader_partitions
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
    if @outfile.nil?
      info("No output file specified, skipping to output vmdk")
      return
    end

    execute!("qemu-img convert -f raw -O vmdk #{@dev} #{@outfile}")
    orig_user = `whoami`.strip
    execute!("chown #{orig_user} #{@outfile}")
  end

  ##
  # Ensure that the specified disk is big enough
  #
  def validate_disk_size
    return unless @dev

    # we can't use execute!() since we want to capture the output of the cmd
    output, _, stat = Open3.capture3("sudo blockdev --getsize64 #{@dev}")
    raise RuntimeError, 'Unable determine dev size' unless stat.success?

    dev_mib = output.strip.to_i / (1024 * 1024) # space on device (MiB)
    begin
      tot_mib = total_disk_size()
    rescue RuntimeError => e
      warn("Performing lax disk size check (#{e})")
      tot_mib = minimum_disk_size()
    end

    if tot_mib >= dev_mib
      warn("Insufficient space! need MiB: #{tot_mib}, device MiB: #{dev_mib}")
      raise RuntimeError, "Total size #{tot_mib} > block device size #{dev_mib}"
    end

    nil
  end

  ##
  # Validate that the partition layout is usable
  #
  def validate_partition_layout
    # Check for exactly one grub_cfg partition
    grub_parts = @partition_layout.select { |p| p.grub_cfg }
    if grub_parts.empty?
      raise RuntimeError, 'Missing grub_cfg partition in layout'
    elsif grub_parts.count > 1
      raise RuntimeError, 'Multiple grub_cfg partitions in layout'
    end

    if @partition_layout.select { |p| p.lvm }.count == 0
      validate_partition_layout_non_lvm
    else
      validate_partition_layout_lvm
    end
  end

  ##
  # Validate non LVM partition layout
  #
  def validate_partition_layout_non_lvm
    if not @partition_layout.find { |p| p.os }
      raise RuntimeError, 'Missing OS partition (non LVM)'
    end

    if @partition_layout.count { |p| !p.size_mb.is_a?(Integer) } > 1
      raise RuntimeError, 'Only 1 partition can have unspecified size (100%FREE)'
    end

    return
  end

  ##
  # partition layout validation for lvm partition
  #
  def validate_partition_layout_lvm
    lvm_parts = @partition_layout.select { |p| p.lvm }

    # Check for missing VG names
    if lvm_parts.select { |l| l.lvm.vg_name.empty? }.count != 0
      raise RuntimeError, 'One or more LVM partitions are missing vg_name'
    end

    # Check for at least one OS partition
    vols = lvm_parts.map { |l| l.lvm.volumes }.flatten
    if not vols.find { |v| v.os }
      raise RuntimeError, 'Missing OS partition in layout (LVM)'
    end

    # Sanity check each VG
    lvm_parts.each do |p|
      # Can't check VG that is on an "open ended" partition
      if not p.size_mb.is_a?(Integer)
        info("Skipping VG size validation for #{p.lvm.vg_name}")
        next
      end

      # Check if VG has more than one LV which intends to be 100%FREE
      if p.lvm.volumes.count { |v| !v.size_mb.is_a?(Integer) } > 1
        raise RuntimeError, "Only 1 LV can have unspecified size (100%FREE)"
      end

      # Check if VG has enough size to accomodate its LVs
      total_mb = 0
      p.lvm.volumes \
       .select { |v| v.size_mb.is_a?(Integer) } \
       .each   { |v| total_mb += v.size_mb }
      if (total_mb + 4) > p.size_mb # assuming 1 extra PE (of 4MiB)
        raise RuntimeError, "VG #{p.label} has more LVs (size) than capacity"
      end
    end

    # Check for unique partition labels
    vols = lvm_parts.map { |l| l.lvm.volumes }.flatten
    labels = {}
    vols.each do |v|
      raise ArgumentError, "Dup FS label #{v.label}" if labels.has_key?(v.label)

      labels[v.label] = true
    end

    return true
  end

  ##
  # Total disk size we need to allocate
  # = all partition sizes
  # + first offest (from left end)
  # + 1MB for end since parted uses END as inclusive
  #
  def total_disk_size
    if @partition_layout.find { |p| !p.size_mb.is_a?(Integer) }
      raise RuntimeError, "Some partition sizes unspecified, cannot infer "\
            "total size of all partitions"
    end

    @partition_layout.inject(0) { |memo, elem| memo + elem.size_mb } \
      + FIRST_PARTITION_OFFSET \
      + 1
  end

  ##
  # Returns mimimum size of disk needed to hold all the partitions specified
  # (open ended partitions are deemed to be at least 4MiB)
  #
  def minimum_disk_size
    @partition_layout.inject(0) { |memo, elem|
      if elem.size_mb.is_a?(Integer)
        memo + elem.size_mb
      else
        memo + 1 # open ended partitions need to be at least 4MiB (arbitrary)
      end
    } \
    + FIRST_PARTITION_OFFSET \
    + 1
  end

  ##
  # From the partition_layout, pick the first partition marked as :grub_cfg
  #
  def first_grub_cfg_partition
    grub_part = @partition_layout.select { |p| p.grub_cfg == true }.first
    raise RuntimeError, 'Missing grub partition' unless grub_part

    return grub_part
  end

  ##
  # From the #partition_layout, pick the first partition marked as :os
  #
  def first_os_partition
    os_part = @partition_layout.detect { |p| p.os == true }
    return os_part if os_part

    # Next look for an OS in a LVM partition
    lvm_part = @partition_layout.detect { |p| p.lvm != nil }
    raise RuntimeError, 'OS and LVM partitions missing' unless lvm_part

    os_part = lvm_part.lvm.volumes.detect { |p| p.os == true }
    raise RuntimeError, 'No partitions marked as OS' unless os_part

    return os_part
  end

  ##
  #
  #
  def all_os_partitions
    # first all the regular OS partitions
    os_parts = @partition_layout.select { |p| p.os == true }
    # next all the lvm OS partitions
    lvm_parts = @partition_layout.select { |p| p.lvm != nil }
    lvm_parts.each { |lp|
      os_parts += lp.lvm.volumes.select { |v| v.os == true }
    }
    return os_parts
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
  ensure
    notice("Deactivating partitions")
    self.deactivate_partitions
  end

  def with_loopback_disk(&block)
    notice("Creating disk file and loopback device")
    with_sized_loopback_disk(total_disk_size) do |dev|
      @dev = dev
      block.call if block
    end
  end

  ##
  # Creates the specified filesystem (fstype) on the specified file/disk (where)
  #
  def create_filesystem(fstype, where, label)
    if fstype == 'fat32'
      execute!("mkfs.fat -F -F32 -n#{label} #{where}")
    elsif fstype == 'fat16'
      execute!("mkfs.fat -F -F16 -n#{label} #{where}")
    elsif fstype == 'swap'
      execute!("mkswap -L #{label} #{where}")
    else
      execute!("mkfs.#{fstype} -L \"#{label}\" #{where}")
    end
  end

  ##
  # Expects the hardware specific derivative class to implement this.
  #
  def create_partitions
    info("Creating disk with #{PARTITION_TABLE_TYPE} parition table")
    execute!("parted -s #{@dev} mklabel #{PARTITION_TABLE_TYPE}")

    start_size = FIRST_PARTITION_OFFSET
    end_size   = FIRST_PARTITION_OFFSET

    unspec_part = nil

    # Create the partitions
    @partition_layout.each_with_index do |part, index|
      # Deal with any "open ended" partitions last
      if not part.size_mb.is_a?(Integer)
        unspec_part = part
        next
      end

      start_size = end_size
      end_size  += part.size_mb

      info("Creating partition #{part.label} (#{part.fs}, #{part.size_mb}MiB)")
      execute!("parted #{@dev} mkpart #{part.label} #{part.fs} #{start_size}MiB #{end_size}MiB")

      (part.flags || {}).each_pair { |k, v|
        info("Setting partition flag #{k} to #{v}")
        execute!("parted #{@dev} set #{index + 1} #{k} #{v}")
      }

      label_path = "/dev/disk/by-partlabel/#{part.label}"
      self.wait_for_device(label_path)

      if not part.fs
        warn("No filesystem specified for #{part.label}. Skipping FS")
      else
        create_filesystem(part.fs, label_path, part.label)
      end

      if part.lvm
        notice("Setting up LVM on #{part.label}")
        setup_lvm_on_partition(part)
      end
    end

    # Deal with any "open ended" partitions (that have an unspecified size_mb)
    if unspec_part
      part = unspec_part
      info("Creating partition #{part.label} (#{part.fs}, 100% remaining)")
      execute!("parted #{@dev} mkpart #{part.label} #{part.fs} #{end_size}MiB 100%")

      (part.flags || {}).each_pair { |k, v|
        info("Setting partition flag #{k} to #{v}")
        execute!("parted #{@dev} set #{@partition_layout.length} #{k} #{v}")
      }

      label_path = "/dev/disk/by-partlabel/#{part.label}"
      self.wait_for_device(label_path)
      create_filesystem(part.fs, label_path, part.label) if part.fs

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
    execute!("pvcreate -y #{pvol}")
    execute!("vgcreate -y #{part.lvm.vg_name} #{pvol}")

    # any "open ended" volumes (no size specified), we deal with last
    unspec_vol = nil

    notice("Creating LVM partitions")
    part.lvm.volumes.each do |vol|
      if not vol.size_mb.is_a?(Integer)
        unspec_vol = vol
        next
      end

      info("Creating #{vol.label} volume")
      execute!("lvcreate -y --name #{vol.label} --size #{vol.size_mb}MiB #{part.lvm.vg_name}")
      next if not vol.fs

      create_filesystem(vol.fs, "/dev/#{part.lvm.vg_name}/#{vol.label}", vol.label)
    end

    if unspec_vol
      vol = unspec_vol
      info("Creating #{vol.label} volume")
      execute!("lvcreate -y --name #{vol.label} -l 100%FREE #{part.lvm.vg_name}")
      if vol.fs
        create_filesystem(vol.fs, "/dev/#{part.lvm.vg_name}/#{vol.label}", vol.label)
      end
    end
  end

  ##
  # Deactivates partitions (normal and lvm)
  #
  def deactivate_partitions
    # First deactive lvm vgs that may have been setup during
    lvm_parts = @partition_layout.select { |p| p.lvm != nil }
    lvm_parts.each { |p|
      p.lvm.volumes.each { |v|
        execute!("lvchange -an #{p.lvm.vg_name}/#{v.label}")
      }
      execute!("vgchange -an #{p.lvm.vg_name}")
      # Running vgexport seems to be problematic (it reimports LVs!)
      # execute!("vgexport #{p.lvm.vg_name}")
      # Run this if you want to be *sure* all LVs have been removed
      # execute!("dmsetup -v remove /dev/#{p.lvm.vg_name}/* || true")
    }

    # Then deal with removal of normal partitions from the loopback device
    # else we leak /dev/loopNp{1,2,3}
    sleep(2) # avoid race
    execute!("sync")
    # Print some debugging info (in case the following call to partx fails)
    # execute!("dmsetup info || true")
    execute!("partx -d -v #{@dev}")
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

    decompressor = ''
    if @image_tarball_path.end_with?('.tgz')
      decompressor = '--gunzip'
    elsif @image_tarball_path.end_with?('.gz')
      decompressor = '--gunzip'
    elsif @image_tarball_path.end_with?('bz2')
      decompressor = '--bzip2'
    elsif @image_tarball_path.end_with?('lzma')
      decompessor = '--lzma'
    elsif @image_tarball_path.end_with?('lzip')
      decompressor = '--lzip'
    end

    # We only install to the first OS partition, for now (TODO)
    os_part = first_os_partition()

    # mount os partition, unpack the image on it, unmount it
    Dir.mktmpdir do |mountdir|
      begin
        os_part_path = File.join('/dev/disk/by-label', os_part.label)
        execute!("mount #{os_part_path} #{mountdir}")

        execute!(['tar ',
                  decompressor,
                  '--extract',
                  "--file=#{@image_tarball_path}",
                  # Perms from the image should be retained.
                  # Our job is to only install image to disk.
                  '--preserve-permissions',
                  '--numeric-owner',
                  "-C #{mountdir} ."].join(' '))

        # write out the fstab file
        fstab_file_path = File.join(mountdir, '/etc/fstab')
        if File.exists?(fstab_file_path)
          info("Image already contains an fstab file, not generating one")
        else
          Tempfile.open('fstab') { |f|
            f.puts('# This file is autogenerated')
            f.puts(fstab_contents(os_part.label))
            f.sync; f.fsync # flush ruby buffers and OS buffers
            execute!("cp #{f.path} #{fstab_file_path}")
          }
        end
      ensure
        execute!("umount #{mountdir}")
      end
    end

    execute!('sync')

    nil
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
    @old_dev_names = true
    kopts = ['ro']
    kopts = kopts + ['net.ifnames=0', 'biosdevname=0'] if @old_dev_names
    kernel_opts_normal = (kopts + ['quiet', 'splash']).join(' ')
    kernel_opts_debug  = (kopts + ['debug', 'console=tty0']).join(' ')

    lines = [
      "set default=0",
      "set gfxpayload=1024x768x24",
      "set timeout=5",
    ]

    self.all_os_partitions.each { |os_part|
      lines += [
        "# #{os_part.label}",
        "menuentry \"#{os_part.label}\" {",
        "  insmod ext2",
        "  search  --label --set=root --no-floppy #{os_part.label}",
        "  linux   /vmlinuz root=LABEL=#{os_part.label} #{kernel_opts_normal}",
        "  initrd  /initrd.img",
        "}",
        "",
        "# #{os_part.label} (debug)",
        "menuentry \"#{os_part.label} (debug)\" {",
        "  insmod ext2",
        "  search  --label --set=root --no-floppy #{os_part.label}",
        "  linux   /vmlinuz root=LABEL=#{os_part.label} #{kernel_opts_debug}",
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
      ['# <filesystem>', '<mnt>', '<type>', '<opts>', '<dump>', '<pass>'],
      ["LABEL=#{os_part_label}", '/', 'ext4', fsopts, '0', '1'],
      ["LABEL=#{grub_part.label}", '/grub', 'ext4', fsopts, '0', '1'],
    ].reduce('') { |memo, line_tokens|
      memo << line_tokens.join("\t")
      memo << "\n"
      memo
    }
  end

  ##
  # Wait for the give device (file path, really) to show up
  #
  def wait_for_device(dev_path, timeout_secs = 5)
    slept_secs = 0
    quantum = 0.5

    execute!("udevadm trigger")
    while slept_secs <= timeout_secs
      return nil if File.exists?(dev_path)

      sleep(quantum)
      slept_secs += quantum
    end

    # If we reach here we didn't find the file in time
    raise RuntimeError, "Timed out waiting for #{dev_path}"
  end
end
