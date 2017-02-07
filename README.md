# Diskbot

Build linux (debian) root filesystems / vmdk / disks

## Quick Start

On a 16.04 (ubuntu) system, ensure you have `ruby` installed (as well as `rake`)

Running `rake -T` will list out all the tasks you can run

```
akshay@host:~/diskbot$ rake -T
rake build:cache        # Build debootstrap package cache (supports some env vars)
rake build:device:bios  # Build a bootable BIOS device using the debootstrap rootfs
rake build:device:uefi  # Build a bootable UEFI device using the debootstrap rootfs
rake build:iso          # Build (live cd) ISO using the debootstrap rootfs
rake build:rootfs       # Build basic rootfs using debootstrap (supports some env vars)
rake build:vmdk:bios    # Build a bootable BIOS vmdk disk using the debootstrap rootfs
rake build:vmdk:uefi    # Build a bootable UEFI vmdk disk using the debootstrap rootfs
rake clean:cache        # Clean the debootstrap rootfs file
rake clean:disks        # Clean all disk files
rake clean:iso          # Clean the ISO file
rake clean:rootfs       # Clean the debootstrap rootfs file
rake clean:vmdk_bios    # Clean the BIOS disk file
rake clean:vmdk_uefi    # Clean the UEFI disk file
rake prereqs:check      # Check if prerequisite software is present
```

The `build` set of tasks build stuff. Subtasks under here can build one of:
  - rootfs
  - vmdk (uefi or bios boot)
  - disks (block device) (uefi or bios boot)

The `clean` set of tasks cleans up the corresponding build artifacts.

The `prereqs:check` tasks runs a check for all the necessary software/tools that
are needed for all the tasks to succeed.

Most of the build tasks will need `sudo` permission. Most will run `sudo date`
once in the beginning to force the password prompt once, and then rely on the
fact that sudo won't prompt you for your password for subsequent invocations
till a given timeout.

Assuming the `prereqs:check` task has found all the tools to be present, lets
go ahead and build the rootfs. By default it will build a ubuntu rootfs for
the `xenial` distribution. You can change that by modifying the `Rakefile` (use
the `@distro` variable to control what gets built - `debian` or `ubuntu`).

```
akshay@host:~/diskbot$ rake build:rootfs \
  CUSTOMIZE_PKGS=customize/<additional_pkgs_file> \
  OVERLAY_ROOTFS=<optional_overlay_dir> \
  CUSTOMIZE_SCRIPT=customize/modify_rootfs.sh
```

The above invocation will begin the build of a rootfs. The additional args are
*optional* and can be used to control the following:
  - CUSTOMIZE_PKGS - this file (newline sep, csv or json) contains additional
  packages you want included in the rootfs.
  - OVERLAY_ROOTFS - this dir is copied into the rootfs after it is prepared,
  but before the customize_script is run.
  - CUSTOMIZE_SCRIPT - script that is executed in the rootfs to modify it before
  it is saved. Use this to create additional dirs/users/files etc. You can also
  modify the permissions and ownership of dirs copied from the overlay_dir here.

Et viola, the rootfs should be ready at the end of this. You can use this as
a baseimage for docker containers, or to boot on physical/virtual hardware.

If you'd like to create a virtual disk using this rootfs, use the `build:vmdk`
tasks to create the virtual media that can be used with virtualbox. There are
two flavors of disks you can build - UEFI and BIOS, depending on the type of
virtual hardware you wish to run.

If you'd like create a bootable physical disk using, use the `build:device`
target(s) and specify a `dev` env var (e.g. `dev=/dev/loop0` or `dev=/dev/sdb`).

When creating bootable media (physical or virtual, using `dev` or `vmdk`) you
can specify the partition layout for how you'd like the disk to be parted
using the `PARTITION_LAYOUT` env var. The file specified via this env var is
expected to be a JSON file describing the partition layout as an Array of json
objects. For example, run:

```
akshay@host:~diskbot$ rake build:vmdk:bios \
  PARTITION_LAYOUT=customize/PART_LAYOUT_flat.json
```

Some `PARTITION_LAYOUT` examples are provided in the `customize` dir for you to
get started. Note that the layout must always contain at least one partition
marked as `"os": true`. You can also specify that LVM be used (see the sample
layout file named accordingly).
