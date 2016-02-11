require 'tmpdir'
require 'rake/file_utils'

# Base class from which other 'builder' classes can inherit common functionality.

class BaseBuilder

	# Mix in FileUtils which have been monkeypatched by rake
	include FileUtils

	#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
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
		msg = STDOUT.tty? ? green(line) : msg
		puts msg
	end

	def warn(line)
		msg = STDOUT.tty? ? red(line) : msg
		puts msg
	end

	def notice(line)
		msg = STDOUT.tty? ? blue(line) : msg
		puts msg
	end

	def header(line)
		l_msg = "- - -[#{line}]"
		r_msg = "- " * ((80 - l_msg.length)/2)

		puts ""
		puts yellow("#{l_msg}#{r_msg}")
		puts ""
	end

	#- - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -
	# Helper module to house functions needed during the build.
	#

	# Execute a command using rake 'sh'
	def execute!(cmd, sudo=true, verbose=true)
		cmd = sudo ? "sudo #{cmd}" : cmd
		# puts cmd if verbose
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

	def on_mounted_tmpfs(size='1G')
		Dir.mktmpdir do |tempdir|
			begin
				notice('Mounting tmpfs')
				# 1G should be sufficient. Our image shouldn't be larger than that ;)
				execute!("mount -t tmpfs -o size=#{size} debootstrap-tmpfs #{tempdir}",	true)
				yield tempdir if block_given?
			ensure
				execute!("umount #{tempdir}", true)
			end
		end
	end

end
