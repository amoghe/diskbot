require 'ostruct'
require 'tmpdir'
require 'rake/file_utils'

#
# Printer
#
class PrettyPrinter
  #- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  # Print prettier messages.
  #

  # 31 red
  # 32 green
  # 33 yellow
  # 34 blue
  # 35 magenta

  def red(line); "\033[0;31m#{line}\033[0m"; end

  def green(line); "\033[0;32m#{line}\033[0m"; end

  def yellow(line); "\033[0;33m#{line}\033[0m"; end

  def blue(line); "\033[0;34m#{line}\033[0m"; end

  def magenta(line); "\033[0;35m#{line}\033[0m"; end

  def info(line)
    line = "[INFO] #{line}"
    line = STDOUT.tty? ? green(line) : line
    puts(line)
    STDOUT.flush() if not STDOUT.tty? # jenkins invocations
  end

  def warn(line)
    line = "[WARN] #{line}"
    line = STDOUT.tty? ? red(line) : line
    puts("\n" + line)
    STDOUT.flush() if not STDOUT.tty? # jenkins invocations
  end

  def notice(line)
    line = "[NOTI] #{line}"
    line = STDOUT.tty? ? blue(line) : line
    puts("\n" + line)
    STDOUT.flush() if not STDOUT.tty? # jenkins invocations
  end

  def header(line)
    l_msg = "- - -[#{line}]"
    r_msg = "- " * ((80 - l_msg.length) / 2)

    puts("")
    puts(STDOUT.tty? ? yellow("#{l_msg}#{r_msg}") : "#{l_msg}#{r_msg}")
    puts("")
    STDOUT.flush() if not STDOUT.tty? # jenkins invocations
  end
end

#
# Base class from which other 'builder' classes can inherit common functionality
#
class BaseBuilder < PrettyPrinter
  # Mix in FileUtils which have been monkeypatched by rake
  include FileUtils

  #- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
  # Helper module to house functions needed during the build.
  #

  # Execute a command using rake 'sh'
  def execute!(cmd, sudo = true, verbose = true)
    cmd = sudo ? "sudo #{cmd}" : cmd
    # `echo '#{cmd}' >> ./cmds.txt` if sudo
    # puts(cmd) if verbose
    # `#{cmd}`
    sh cmd, verbose: verbose do |ok, res|
      if !ok
        warn("Command [#{cmd}] exited with code: #{res.exitstatus}")
        raise RuntimeError, "Failed to execute command: #{cmd}"
      end
    end
  end

  # Insufficient perms for the build
  class PermissionError < StandardError; end

  def ensure_root_privilege
    notice('Triggerring sudo')
    execute!('date', true)
    true
  end

  ##
  # Invoke the specified block with a mounted tmpfs (of the given size)
  #
  def on_mounted_tmpfs(size_mb = 1024, &block)
    return unless block

    size_mb         = ENV.fetch('TMPFS_SIZEMB', size_mb)
    custom_tmpfsdir = ENV.fetch('TMPFS_DIR', '/foobarbaz')

    if Dir.exists?(custom_tmpfsdir)
      notice("Using #{custom_tmpfsdir} for tmpfs (ASSUMING it is large enough)")
      self.__on_custom_tmpfs(custom_tmpfsdir, &block)
    else
      notice("Mounting a tmpfs (size: #{size_mb}M)")
      self.__on_tmpfs(size_mb.to_i, &block)
    end
  end

  # :silent:
  # Assume dir is a tmpfs dir (we don't really care) and invoke block on it
  def __on_custom_tmpfs(dir, &block)
    block.call(dir) if block
  ensure
    execute!("rm -rf #{dir}/*", true)
  end

  # :silent:
  # Mount a tmpfs of given size and invoke the block
  def __on_tmpfs(size_mb = 1024, &block)
    Dir.mktmpdir do |tempdir|
      begin
        cmd = "mount -t tmpfs -o size=#{size_mb}M debootstrap-tmpfs #{tempdir}"
        execute!(cmd, true)
        yield tempdir if block_given?
      ensure
        execute!("umount #{tempdir}", true)
      end
    end
  end

  ##
  # Create a loopback disk and provide it to the specified block.
  # This creates a loopback disk backed by a file on a tmpfs (see funcs that
  # provide the tmpfs above). This means that TMPFSDIR and TMPFSSIZE are
  # honored and the user can control them.
  #
  def with_sized_loopback_disk(disk_size_mb, &block)
    on_mounted_tmpfs(disk_size_mb) do |dir|
      begin
        tempfile = dir + '/loopdisk'
        execute!("fallocate -l #{disk_size_mb}MiB #{tempfile}", false)
        output, _, stat = Open3.capture3("sudo losetup --find")
        raise RuntimeError, 'Failed to find loop device' unless stat.success?

        execute!("losetup #{output.strip} #{tempfile}")
        dev = output.strip
        block.call(dev) if block
      ensure
        execute!("losetup -d #{dev}") if dev && dev.length > 0
        execute!("rm -f #{tempfile}", false) if tempfile && tempfile.length > 0
      end
    end
  end

  def breakpoint
    puts(yellow("[Breakpoint]. Hit ENTER to continue >"))
    STDIN.gets()
  end
end

#
# DeepStruct (Recursive OpenStruct)
#
class DeepStruct < OpenStruct
  def initialize(hash = nil)
    @table = {}
    @hash_table = {}

    if hash and !hash.kind_of?(Hash)
      raise ArgumentError, "Specified arg is not a Hash"
    end

    if hash
      hash.each do |k, v|
        val = nil
        # Try to handle composite structures (Hash/Array) as values
        case
        when v.is_a?(Hash)
          val = self.class.new(v)
        when v.is_a?(Array)
          val = v.map { |elem| elem.is_a?(Hash) ? self.class.new(elem) : elem }
        else
          val = v
        end
        @table[k.to_sym] = val
        @hash_table[k.to_sym] = val

        new_ostruct_member(k)
      end
    end
  end

  def to_h
    @hash_table
  end
end
