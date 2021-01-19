require 'find'
require 'json'
require 'open3'
require 'pp'

require_relative 'base_builder'

class DebootstrapBuilder < BaseBuilder
  VALID_TAR_COMPRESSORS = {
    'gzip' => 'gz',
    'bzip2' => 'bz2',
    'xz' => 'xz',
    'lzip' => 'lzip',
    'lzop' => 'lzop',
    'lzma' => 'lzma',
  }

  # Additional pacakge we'd like in the rootfs so that its usable
  ADDON_PKGS = [
    'isc-dhcp-client', # dhcp
    'net-tools', # ifconfig
    'ifupdown', # 'ifup, ifdown, /etc/network/interfaces'
    'lvm2',
    'openssh-server',
    'sudo',
    'zile',
  ]

  # What the kernel pks is called in each distro
  KERNEL_PKG_NAME = {
    "ubuntu" => "linux-image-generic",
    "debian" => "linux-image-amd64",
  }

  UBUNTU_APT_ARCHIVE_URL = "http://archive.ubuntu.com/ubuntu"
  DEBIAN_APT_ARCHIVE_URL = "http://debian.osuosl.org/debian"

  attr_reader :verbose

  def initialize(distro,
                 outfile,
                 debootstrap_pkg_cache: nil,
                 customize_pkgs:        nil,
                 customize_rootfs:      nil,
                 overlay_rootfs:        nil,
                 apt_mirror_url:        nil,
                 compressor:            nil,
                 verbose:               false)

    @distro  = distro
    @verbose = !!verbose

    case distro
    when "ubuntu"
      @flavor = "focal"
      @archive_url = UBUNTU_APT_ARCHIVE_URL
    when "debian"
      @flavor = "jessie"
      @archive_url = DEBIAN_APT_ARCHIVE_URL
    else
      raise ArgumentError, "Invalid distro specified"
    end

    if apt_mirror_url
      @archive_url = apt_mirror_url
    end

    @customize_script = nil
    if customize_rootfs
      raise ArgumentError, "Bad script" unless File.exists?(customize_rootfs)

      @customize_script = customize_rootfs
    end

    # This could be nil, we'll check at runtime
    if debootstrap_pkg_cache and File.exists?(debootstrap_pkg_cache)
      @debootstrap_pkg_cache = File.expand_path(debootstrap_pkg_cache)
    end

    if customize_pkgs
      raise ArgumentError, 'Bad pkgs file' unless File.exists?(customize_pkgs)

      c = File.read(customize_pkgs)
      if c.start_with?('[') and c.strip.end_with?(']')
        @customize_pkgs = JSON.parse(c) # JSON
      elsif c.include?(',')
        @customize_pkgs = c.strip.split(',') # CSV
      else
        @customize_pkgs = c.strip.lines() # newline seperated
      end
      @customize_pkgs.map! { |p| p.strip! }
    end

    if overlay_rootfs
      raise ArgumentError, 'Bad overlay dir' unless Dir.exists?(overlay_rootfs)

      @overlay_dir = overlay_rootfs
    end

    if !compressor.nil? and !VALID_TAR_COMPRESSORS.keys.include?(compressor)
      raise ArgumentError, "Invalid compressor specified"
    end

    @compressor = compressor
    @outfile = outfile
  end

  ##
  # Create the rootfs using debootstrap, then perform subsequent operations
  # on it to modify it as needed.
  #
  def create_debootstrap_rootfs()
    header("Creating basic rootfs using debootstrap")

    size_mb = 1024 + (@overlay_dir ? size_of_dir(@overlay_dir) : 0)
    self.on_mounted_tmpfs(size_mb) do |tempdir|
      add_dummy_fstab(tempdir)
      run_debootstrap(tempdir)
      remove_dummy_fstab(tempdir)
      add_apt_sources(tempdir)
      add_eth0_interface(tempdir)
      overlay_files(tempdir)
      customize_rootfs(tempdir)
      package_rootfs(tempdir)
    end
  end

  ##
  # Add a dummy fstab that is read during debootstap to determine which fsck
  # to add into the initrd. Without this, fsck.ext4 is excluded, leading to a
  # cosmetic error message during the boot.
  #
  def add_dummy_fstab(tempdir)
    notice("Adding dummy fstab")

    line1 = ['# <filesys>', '<mnt>', '<type>', '<opts>', '<dump>', '<pass>'].join("\t"),
            line2 = ['/dev/sda42', '/', 'ext4', 'defaults', '0', '1'].join("\t")

    execute!("mkdir -p #{tempdir}/etc")
    execute!("echo #{line1} | sudo tee #{File.join(tempdir, '/etc/fstab')}")
    execute!("echo #{line2} | sudo tee #{File.join(tempdir, '/etc/fstab')}")
  end

  ##
  # Remove the dummy fstab we wrote during debootstrap
  #
  def remove_dummy_fstab(tempdir)
    notice("Removing dummy fstab")
    execute!("rm #{File.join(tempdir, "/etc/fstab")}")
  end

  ##
  # Return all additional pkgs to be installed in the rootfs
  #
  def all_addon_pkgs()
    all_pkgs = []
    all_pkgs = all_pkgs + ADDON_PKGS
    all_pkgs = all_pkgs + [KERNEL_PKG_NAME[@distro]]
    all_pkgs = all_pkgs + @customize_pkgs if @customize_pkgs
    return all_pkgs.uniq
  end

  ##
  # Run debootstrap
  #
  def run_debootstrap(tempdir)
    if @debootstrap_pkg_cache and File.exists?(@debootstrap_pkg_cache)
      cached_pkgs_opt = "--unpack-tarball=#{@debootstrap_pkg_cache}"
      info("Using cached debootstrap pkgs file at: #{@debootstrap_pkg_cache}")
    else
      cached_pkgs_opt = ""
      info("No cached debootstrap packages found.")
    end

    notice('Running debootstrap')
    execute!(["debootstrap",
              verbose ? "--verbose" : "",
              "--variant minbase",
              "--components main,universe",
              cached_pkgs_opt,
              "--include #{all_addon_pkgs.join(",")}",
              @flavor,
              tempdir,
              @archive_url,].join(" "))
  end

  ##
  # Add appropriate entries in the apt sources.list file
  #
  def add_apt_sources(tempdir)
    notice("Adding appropriate apt sources")
    case @distro
    when "ubuntu"
      lines = [
        "deb #{@archive_url} #{@flavor}          main restricted universe",
        "deb #{@archive_url} #{@flavor}-updates  main restricted universe",
        "deb #{@archive_url} #{@flavor}-security main restricted universe",
      ].join("\n")
    when "debian"
      lines = [
        "deb http://ftp.debian.org/debian #{@flavor}         main contrib",
        "deb http://ftp.debian.org/debian #{@flavor}-updates main contrib",
        "deb http://security.debian.org/  #{@flavor}/updates main contrib",
      ].join("\n")
    else
      raise ArgumentError, "Unknown distribution"
    end

    execute!("echo \"#{lines}\" | sudo tee #{tempdir}/etc/apt/sources.list")
  end

  ##
  # Add an 'admin' user so we can log in
  #
  def add_admin_user(tempdir)
    notice("Adding shadow/passwd entries for 'admin' user (password: 'password')")

    useradd_cmd = [
      "useradd",
      "--password '$1$ABCDEFGH$hGGndps75hhROKqu/zh9q1'",
      "--root #{tempdir}",
      "--shell /bin/bash",
      "--create-home",
      "--groups sudo",
      "admin"
    ].join(" ")

    execute!("#{useradd_cmd}")
  end

  ##
  # Ensure that an eth0 entry exists
  #
  def add_eth0_interface(tempdir)
    notice("Adding entry for eth0 interface")

    lines = [
      "auto eth0",
      "iface eth0 inet dhcp",
    ].join("\n")

    execute!("echo -e \"#{lines}\" | sudo tee --append #{tempdir}/etc/network/interfaces")
  end

  ##
  # Run customization script in the rootfs
  #
  def customize_rootfs(tempdir)
    return unless @customize_script

    notice('Running customization script in the rootfs (chroot)')
    execute!("mount -o bind /proc #{tempdir}/proc")
    execute!("cp #{@customize_script} #{tempdir}/tmp/customize.sh")
    execute!("chmod a+x #{tempdir}/tmp/customize.sh")
    execute!("chroot #{tempdir} /tmp/customize.sh")
  ensure
    execute!("umount #{tempdir}/proc")
  end

  ##
  # Overlay files onto the rootfs (if overlay dir was specified)
  #
  def overlay_files(tempdir)
    if not @overlay_dir
      info("No overlay dir specified, skipping overlay step")
      return
    end
    notice("Copying files from the overlay dir: #{@overlay_dir}")
    # Ensure a trailing sep at the end of src and dest paths to get rsync to
    # sync the contents of src to dir.
    execute!("rsync -avx #{@overlay_dir.chomp('/')}/ #{tempdir}/")
  end

  ##
  # Package the rootfs (in the dir argument) (tar.gz)
  #
  def package_rootfs(tempdir)
    notice('Cleaning up packages in the rootfs')
    execute!("chroot #{tempdir} apt-get clean")
    notice('Packaging rootfs')
    ext = (@compressor ? ".#{VALID_TAR_COMPRESSORS[@compressor]}" : '')
    execute!(['tar ',
              '--create',
              @compressor ? "--#{@compressor}" : '',
              "--file=#{@outfile + ext}",
              # preserve perms, else whoever uses the image will have to twidle the perms again.
              '--preserve-permissions',
              '--numeric-owner',
              "-C #{tempdir} ."].join(' '),
             true)
    # Ensure resulting file is owned by the caller
    execute!(["chown", `whoami`.strip, @outfile + ext].join(' '), true)
  end

  ##
  # Create a debootstrap compatible tarball of deb packages.
  #
  def create_debootstrap_packages_tarball()
    header("(Re)creating tarball of packages needed for debootstrap rootfs")

    notice("Ensuring old packages tarball does not exist")
    execute!("rm -f #{@outfile}", false)

    self.on_mounted_tmpfs do |tempdir|
      # create a work dir in the tempdir, because debootstrap wants to delete its work dir when
      # it finishes, but the tempdir is owned by root.

      workdir = File.join(tempdir, "work")
      Dir.mkdir(workdir)

      notice("Invoking debootstrap to create new cached packages tarball")
      execute!(["debootstrap",
                verbose ? "--verbose" : "",
                "--variant minbase",
                "--components main,universe",
                "--include #{all_addon_pkgs.join(",")}",
                "--make-tarball #{@outfile}",
                @flavor,
                workdir,
                @archive_url,].join(" "), false)
    end

    notice("debootstrap packages cached at:" + @outfile)
  end

  ##
  # Returns size of dir tree in MB
  #
  def size_of_dir(dir)
    total_size = 0
    Find.find(dir) do |path|
      if FileTest.directory?(path)
        if File.basename(path)[0] == ?.
          Find.prune       # Don't look any further into this directory.
        else
          next
        end
      else
        total_size += FileTest.size(path)
      end
    end
    return total_size / (1024 * 1024)
  end
end
