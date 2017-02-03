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

	def red(line)    ; "\033[0;31m#{line}\033[0m" ; end
	def green(line)  ; "\033[0;32m#{line}\033[0m" ; end
	def yellow(line) ; "\033[0;33m#{line}\033[0m" ; end
	def blue(line)   ; "\033[0;34m#{line}\033[0m" ; end
	def magenta(line); "\033[0;35m#{line}\033[0m" ; end

	def info(line)
		line = "[INFO] #{line}"
		line = STDOUT.tty? ? green(line) : line
		puts(line)
	end

	def warn(line)
		line = "[WARN] #{line}"
		line = STDOUT.tty? ? red(line) : line
		puts("\n" + line)
	end

	def notice(line)
		line = "[NOTI] #{line}"
		line = STDOUT.tty? ? blue(line) : line
		puts("\n" + line)
	end

	def header(line)
		l_msg = "- - -[#{line}]"
		r_msg = "- " * ((80 - l_msg.length)/2)

		puts("")
		puts(yellow("#{l_msg}#{r_msg}"))
		puts("")
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
	def execute!(cmd, sudo=true, verbose=true)
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
	class PermissionError < StandardError ; end

	def ensure_root_privilege
		notice('Triggerring sudo')
		execute!('date', true)
		true
	end

	def on_mounted_tmpfs(size='1G', &block)
		return unless block
		size = ENV.fetch('TMPFSSIZE', size)
		if Dir.exists?(ENV.fetch('TMPFSDIR', '/foobarbaz'))
			self.__on_custom_tmpfs(ENV.fetch('TMPFSDIR', '/foobarbaz'), &block)
		else
			self.__on_tmpfs(size, &block)
		end
	end

	def __on_custom_tmpfs(dir, &block)
		# We're already on a tmpfs, so no need to mount tmpfs on a
		# temp dir, just use the dir instead.
		notice("Using #{dir} for tmpfs")
		block.call(dir) if block
	ensure
		# clean up before we return
		execute!("rm -rf #{dir}/*", true)
	end

	def __on_tmpfs(size='1G', &block)
		Dir.mktmpdir do |tempdir|
			begin
				notice("Mounting tmpfs (size: #{size})")
				# 1G should be sufficient. Our image shouldn't be larger than that ;)
				execute!("mount -t tmpfs -o size=#{size} debootstrap-tmpfs #{tempdir}",	true)
				yield tempdir if block_given?
			ensure
				execute!("umount #{tempdir}", true)
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

  def initialize(hash=nil)
    @table = {}
    @hash_table = {}

		if hash and !hash.kind_of?(Hash)
			raise ArgumentError, "Specified arg is not a Hash"
		end

		if hash
      hash.each do |k,v|
				val = nil
				# Try to handle composite structures (Hash/Array) as values
				case
				when v.is_a?(Hash)
					val = self.class.new(v)
				when v.is_a?(Array)
					val = v.map{ |elem| elem.is_a?(Hash) ? self.class.new(elem) : elem }
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
