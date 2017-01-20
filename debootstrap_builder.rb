require 'json'
require 'open3'
require 'pp'

require_relative 'base_builder'

class DebootstrapBuilder < BaseBuilder

	# Additional pacakge we'd like in the rootfs so that its usable
	ADDON_PKGS = [
		'isc-dhcp-client'    , # dhcp
		'net-tools'          , # ifconfig
		'ifupdown'           , # 'ifup, ifdown, /etc/network/interfaces'
		'openssh-server'     ,
		'sudo'               ,
		'zile'               ,
	]
	# Additional packages that the user may specify without modifying code
	ADDON_PKGS_FILE = 'custom_pkgs.json'

	# What the kernel pks is called in each distro
	KERNEL_PKG_NAME = {
		"ubuntu" => "linux-image-generic",
		"debian" => "linux-image-amd64",
	}

	UBUNTU_APT_ARCHIVE_URL = "http://archive.ubuntu.com/ubuntu"
	DEBIAN_APT_ARCHIVE_URL = "http://debian.osuosl.org/debian"

	CWD = File.dirname(__FILE__)

	CACHED_DEBOOTSTRAP_PKGS_NAME = "debootstrap_pkgs.tgz"
	CACHED_DEBOOTSTRAP_PKGS_PATH = File.join(CWD, CACHED_DEBOOTSTRAP_PKGS_NAME)

	DEBOOTSTRAP_ROOTFS_NAME = "debootstrap_rootfs.tgz"
	DEBOOTSTRAP_ROOTFS_PATH = File.join(CWD, DEBOOTSTRAP_ROOTFS_NAME)

	attr_reader :verbose

	def initialize(distro, verbose, islive)
		@distro  = distro
		@verbose = !!verbose
		@islive  = !!islive

		case distro
		when "ubuntu"
			@flavor = "xenial"
			@archive_url = UBUNTU_APT_ARCHIVE_URL
		when "debian"
			@flavor = "jessie"
			@archive_url = DEBIAN_APT_ARCHIVE_URL
		else
			raise ArgumentError, "Invalid distro specified"
		end
	end

	def create_debootstrap_rootfs()
		header("Creating basic rootfs using debootstrap")

		self.on_mounted_tmpfs do |tempdir|
			add_dummy_fstab(tempdir)
			run_debootstrap(tempdir)
			remove_dummy_fstab(tempdir)
			add_apt_sources(tempdir)
			add_admin_user(tempdir)
			add_eth0_interface(tempdir)
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

		line1 = ['# <filesys>', '<mnt>', '<type>', '<opts>'  , '<dump>', '<pass>'].join("\t"),
		line2 = ['/dev/sda42' , '/'    , 'ext4'  , 'defaults', '0'     , '1'     ].join("\t")

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
		all_pkgs = @islive ? ["live-boot", "live-boot-initramfs-tools"] : []
		all_pkgs = all_pkgs + ADDON_PKGS
		all_pkgs = all_pkgs + [KERNEL_PKG_NAME[@distro]]
		all_pkgs = all_pkgs + JSON.parse(File.read(ADDON_PKGS_FILE)) if File.exists?(ADDON_PKGS_FILE)
		return all_pkgs.uniq
	end

	##
	# Run debootstrap
	#
	def run_debootstrap(tempdir)
		if File.exists?(CACHED_DEBOOTSTRAP_PKGS_PATH)
			cached_pkgs_opt = "--unpack-tarball=#{CACHED_DEBOOTSTRAP_PKGS_PATH}"
			info("Cached debootstrap packages found in tarball at: #{CACHED_DEBOOTSTRAP_PKGS_PATH}")
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
			@archive_url,
		].join(" "))
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
			raise ArgumentError, "Unknown flavor"
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

		execute!("sudo #{useradd_cmd}")
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
	# Create a debootstrap compatible tarball of deb packages.
	#
	def create_debootstrap_packages_tarball()
		header("(Re)creating tarball of packages needed for debootstrap rootfs")
		cached_pkgs_tarball = CACHED_DEBOOTSTRAP_PKGS_PATH

		notice("Ensuring old packages tarball does not exist")
		execute!("rm -f #{cached_pkgs_tarball}", false)

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
				"--make-tarball #{cached_pkgs_tarball}",
				@flavor,
				workdir,
				@archive_url,
			].join(" "), false)
		end

		notice("debootstrap packages cached at:" + cached_pkgs_tarball)
	end

	##
	# Package the rootfs (in the dir argument) (tar.gz)
	#
	def package_rootfs(tempdir)
		notice('Packaging rootfs')
		execute!(['tar ',
			'--create',
			'--gzip',
			"--file=#{DEBOOTSTRAP_ROOTFS_PATH}",
			# TODO: preserve perms, else whoever uses the image will have to twidle the perms again.
			#'--owner=0',
			#'--group=0',
			'--preserve-permissions',
			'--numeric-owner',
			"-C #{tempdir} ."
		].join(' '),
		true)
	end

end
