ifeq ($(SUBTARGET),lgm)

DATE_FMT = +%y-%m-%d
UIMAGE_NAME ?= $(shell date "$(DATE_FMT)")

# Simple hook: copy to common name after secure initramfs is built and inject keys
ifeq ($(CONFIG_INTEL_X86_SECBOOT),y)
$(BIN_DIR)/secure-initramfs.cpio.gz: secure-initramfs
	@echo "#### Copying secure-initramfs to common name"
	@cp -f "$(BIN_DIR)/$(IMG_SECURE_INITRAMFS)" "$@.new"
	@echo "#### Injecting keys into secure-initramfs"
	@{ \
		set -e; \
		IMG_GEN_DIR=$$(find $(BUILD_DIR_BASE)/hostpkg -maxdepth 1 -type d -name "imagegenerator-*" | head -n 1); \
		if [ -z "$$IMG_GEN_DIR" ]; then \
			echo "ERROR: imagegenerator directory not found in $(BUILD_DIR_BASE)/hostpkg"; \
			exit 1; \
		fi; \
		echo "Using imagegenerator at: $$IMG_GEN_DIR"; \
		BUILD_DIR="$$IMG_GEN_DIR/build"; \
		mkdir -p "$$BUILD_DIR"; \
		echo "Copying cpio to $$BUILD_DIR for script processing..."; \
		cp -f "$@.new" "$$BUILD_DIR/$(IMG_SECURE_INITRAMFS)"; \
		cd "$$IMG_GEN_DIR"; \
		for script in scripts/pre-binman/100_initramfs*.sh scripts/pre-binman/200_initramfs*.sh; do \
			if [ -f "$$script" ]; then \
				echo "Running $$script to inject keys..."; \
				bash "$$script"; \
			else \
				echo "Warning: $$script not found, skipping"; \
			fi; \
		done; \
		echo "Copying modified cpio back..."; \
		cp -f "$$BUILD_DIR/$(IMG_SECURE_INITRAMFS)" "$@.new"; \
		rm -f "$$BUILD_DIR/$(IMG_SECURE_INITRAMFS)"; \
		echo "#### Keys successfully injected into secure-initramfs"; \
	}
	#@if cmp -s "$@.new" "$@"; then \
	#	echo "#### secure-initramfs unchanged, skipping kernel rebuild"; \
	#	rm -f "$@.new"; \
	#else \
	#	echo "#### secure-initramfs changed, updating (will trigger kernel rebuild)"; \
	#	mv -f "$@.new" "$@"; \
	#fi
	@echo "#### Updating secure-initramfs (optimization disabled for debug)"
	@mv -f "$@.new" "$@"


# Ensure the common name is created before kernel preparation
kernel_prepare: $(BIN_DIR)/secure-initramfs.cpio.gz
endif

# Fakeroot conf
FAKEROOT_PROG:=$(if $(CONFIG_PACKAGE_ugw-fakeroot), \
	ALTPATH="$(STAGING_DIR_ROOT)" CONFFILE="$(STAGING_DIR_HOST)/share/fakeroot/fakeroot.conf" \
	fakeroot -- $(STAGING_DIR_HOST)/bin/fakeroot.sh)

export STAGING_PREFIX=$(STAGING_DIR_HOST)

ifdef CONFIG_WAVE_700
  export DTS_CPPFLAGS += -D CONFIG_WAVE_700
endif

ifdef CONFIG_WAVE_6X4
  export DTS_CPPFLAGS += -D CONFIG_WAVE_6X4
endif

ifdef CONFIG_OSP_TB341_v1_PON_OVERLAY
  export DTS_CPPFLAGS += -D CONFIG_OSP_TB341_v1_PON_OVERLAY
endif

# Standalone dtb generation. The existing 'append-dtb' does not pass
# additional cflags argument (which is required in lgm for additional
# include flag).
define Build/dtb
	$(call Image/BuildDTB,$(DEVICE_DTS_DIR)/$(1).dts,$@.dtb,-I$(LINUX_DIR)/include,-@)
	cat $@.dtb >> $@
endef

# generates dtb-ovarlay file.
define Build/dtbo
	$(call Image/BuildDTBO,$(DEVICE_DTS_DIR)/$(1).dts,$@.dtbo,-I$(LINUX_DIR)/include,-@)
	cat $@.dtbo >> $@
endef

ifeq ($(CONFIG_INTEL_X86_KERNEL_METADATA),y)
define Build/kernel-metadata
	./kernel_metadata.sh $(LINUX_KERNEL)
	mkenvimage -o $(LINUX_KERNEL).metadata.pad -s $(CONFIG_INTEL_X86_ENV_SZ) -r $(LINUX_KERNEL).metadata
	@mv $(LINUX_KERNEL).metadata.pad $(LINUX_KERNEL).metadata
	mkimage -A x86_64 \
                -O u-boot -T invalid -C none \
		-n "Metadata"\
		-d $(LINUX_KERNEL).metadata $(LINUX_KERNEL).metadata.pad
	mv $(LINUX_KERNEL).metadata.pad $(LINUX_KERNEL).metadata
endef
endif
ifeq ($(CONFIG_INTEL_X86_SECBOOT),y)
ifeq ($(CONFIG_INTEL_X86_EXTERNAL_IMAGE_SIGNING),y)
define Build/sign-image
endef
define Build/sign-rootfs
	mkdir -p $(BIN_DIR)/single-images/non_signed_image
	cp -vf $@ $(BIN_DIR)/single-images/non_signed_image
endef
define Build/fullimage
	# wrap rootfs to uImage
	mkimage -A $(LINUX_KARCH) -O linux -C lzma -T filesystem -a 0x00  \
		-e 0x00 -n 'LEDE RootFS' \
		-d $(2) $@.rootfs.wo_sign
	mkdir -p $(BIN_DIR)/non_signed_image
	mv $@.rootfs.wo_sign $(2).pad
	cp -vf $(2).pad $(BIN_DIR)/non_signed_image
endef
else
define Build/sign-image
	$(CONFIG_INTEL_X86_SIGNTOOL) sign -type BLw -infile $@ \
		-prikey $(CONFIG_INTEL_X86_PRIVATE_KEY) \
		-wrapkey $(CONFIG_INTEL_X86_PROD_UNIQUE_KEY) \
		-cert $(CONFIG_INTEL_X86_CERTIFICATION) \
		-encattr -kdk -sm -secure -pubkeytype otp \
		-algo aes256 \
		-attribute 0x80000000=$(CONFIG_INTEL_X86_KERNEL_BASEADDR) \
		-attribute 0x80000002=$(CONFIG_INTEL_X86_KERNEL_BASEADDR) \
		-attribute 0x80000006=0x0 \
		-attribute 0x80000009=0x00000004 \
		-attribute 0x80000007=$(CONFIG_INTEL_X86_KERNEL_FLEXI_ROLLBACKID) \
		-attribute rollback=$(CONFIG_INTEL_X86_KERNEL_ROLLBACKID) \
		-outfile $@.tmp
	mv $@.tmp $@
endef
define Build/sign-rootfs
	$(CONFIG_INTEL_X86_SIGNTOOL) sign -type BLw \
		-prikey $(CONFIG_INTEL_X86_PRIVATE_KEY) \
		-wrapkey $(CONFIG_INTEL_X86_PROD_UNIQUE_KEY) \
		-cert $(CONFIG_INTEL_X86_CERTIFICATION) \
		-encattr -kdk -sm -secure -pubkeytype otp \
		-algo aes256 \
		-attribute 0x80000000=0x40000000 \
		-attribute 0x80000002=0x40000000 \
		-attribute 0x80000006=0x0 \
		-attribute 0x80000009=0x00000005 \
		-attribute 0x80000007=$(CONFIG_INTEL_X86_ROOTFS_FLEXI_ROLLBACKID) \
		-attribute rollback=$(CONFIG_INTEL_X86_ROOTFS_ROLLBACKID) \
		-infile $@ \
		-outfile $@.tmp
	mv $@.tmp $@
endef
define Build/fullimage
	echo "Creating $@ with dtb file $(3) "
	# wrap rootfs to uImage
	dd if=$(2) of=$@.rootfs bs=$(1) conv=sync;
	mkimage -A $(LINUX_KARCH) -O linux -C lzma -T filesystem -a 0x00  \
		-e 0x00 -n 'LEDE RootFS' \
		-d $@.rootfs $@.rootfs.pad

	echo "Sigining and generating the respective dtb.signed files"
	$(CONFIG_INTEL_X86_SIGNTOOL) sign -type BLw -prikey $(CONFIG_INTEL_X86_PRIVATE_KEY) -wrapkey $(CONFIG_INTEL_X86_PROD_UNIQUE_KEY) -encattr -kdk -sm -secure \
	-pubkeytype otp -algo aes256 -attribute 0x80000000=0x08000000 -attribute 0x80000002=0x0$(4) -attribute 0x80000006=0x0 -attribute 0x80000009=0x00001001 -attribute rollback=$(CONFIG_INTEL_X86_DTB_ROLLBACKID)\
	-cert $(CONFIG_INTEL_X86_CERTIFICATION) -infile $(3) -outfile $@.dtb.signed

	@echo "Waiting for the file to get signed.."
	@echo "Entering for retry mechanism if required dtb is not found...!"
	@tries=0; \
	while [ $$tries -lt 10 ]; do \
		sleep 2; \
		ls -ltr $@.dtb.signed; \
		if [ -f "$@.dtb.signed" ]; then \
			echo "File found...!"; \
			break; \
		fi; \
		echo "File not found..."; \
		$(CONFIG_INTEL_X86_SIGNTOOL) sign -type BLw -prikey $(CONFIG_INTEL_X86_PRIVATE_KEY) -wrapkey $(CONFIG_INTEL_X86_PROD_UNIQUE_KEY) -encattr -kdk -sm -secure \
		-pubkeytype otp -algo aes256 -attribute 0x80000000=0x08000000 -attribute 0x80000002=0x0$(4) -attribute 0x80000006=0x0 -attribute 0x80000009=0x00001001 -attribute rollback=$(CONFIG_INTEL_X86_DTB_ROLLBACKID)\
		-cert $(CONFIG_INTEL_X86_CERTIFICATION) -infile $(3) -outfile $@.dtb.signed; \
		tries=`expr $$tries + 1`; \
		echo "trail value is $$tries"; \
    done; \
	if [ ! -f "$@.dtb.signed" ]; then \
		echo "File not found after 10 tries. please retry the build..!"; \
	fi; \

	# wrap device tree blob to u-boot fit image
#	dd if=$@.dtb.signed of=$@.dtb bs=$(1) conv=sync;

	[ -f "$@.dtb.signed" ] && dd if=$@.dtb.signed of=$@.dtb bs=$(1) conv=sync || sync && dd if=$@.dtb.signed of=$@.dtb bs=$(1) conv=sync || echo "Failed!" > /dev/null

	mkimage -A $(LINUX_KARCH) -O linux -C none -T flat_dt \
		-f auto -n 'Flattened Device Tree' \
		-d $@.dtb $@.dtb.pad

	echo "Concatenating $(IMAGE_KERNEL) $@.rootfs.pad $@.dtb.pad into $@.tmp"
	cat $(IMAGE_KERNEL) $@.rootfs.pad $@.dtb.pad > $@.tmp

	mkimage -A $(LINUX_KARCH) -O linux -T multi -a 0x00 -C none \
		-e 0x00 \
		-n '$(if $(UIMAGE_NAME),$(UIMAGE_NAME),OpenWrt fullimage)' \
		-d $@.tmp $@

	rm -rf $@.rootfs
	rm -rf $@.rootfs.pad
	rm -rf $@.dtb
	rm -rf $@.dtb.pad
endef
endif
else
define Build/sign-image
endef

define Build/sign-rootfs
	echo "" > /dev/null
endef

define Build/fullimage
	dd if=$(2) of=$@.rootfs bs=$(1) conv=sync;
	mkimage -A $(LINUX_KARCH) -O linux -C lzma -T filesystem -a 0x00  \
		-e 0x00 -n 'LEDE RootFS' \
		-d $@.rootfs $@.rootfs.pad

	# wrap device tree blob to u-boot fit image
	dd if=$(3) of=$@.dtb bs=$(1) conv=sync;
	mkimage -A $(LINUX_KARCH) -O linux -C none -T flat_dt \
		-f auto -n 'Flattened Device Tree' \
		-d $@.dtb $@.dtb.pad

	cat $(IMAGE_KERNEL) $@.rootfs.pad $@.dtb.pad > $@.tmp

	mkimage -A $(LINUX_KARCH) -O linux -T multi -a 0x00 -C none \
		-e 0x00 \
		-n '$(if $(UIMAGE_NAME),$(UIMAGE_NAME),OpenWrt fullimage)' \
		-d $@.tmp $@

	rm -rf $@.rootfs
	rm -rf $@.rootfs.pad
	rm -rf $@.dtb
	rm -rf $@.dtb.pad
endef
endif

ifeq ($(CONFIG_INTEL_X86_SECBOOT),y)
ifeq ($(CONFIG_INTEL_X86_EXTERNAL_IMAGE_SIGNING),y)
# generates kernel+dtb in fit format.
define Build/fit-kernel-dtb
	mkdir -p $(BIN_DIR)/single-images/non_signed_image
	cp -vf $(IMAGE_KERNEL) $(BIN_DIR)/single-images/non_signed_image/
	cp -vf $(2) $(BIN_DIR)/single-images/non_signed_image
endef
define Build/fit-fullimage
	echo "" > /dev/null
endef
else
# generates kernel+dtb in fit format.
define Build/fit-kernel-dtb
	#kernel image
	dd if=$(IMAGE_KERNEL) of=$(IMAGE_KERNEL).fitimage bs=64 skip=1

	#dtb image signing and padding
	$(CONFIG_INTEL_X86_SIGNTOOL) sign -type BLw -prikey $(CONFIG_INTEL_X86_PRIVATE_KEY) -wrapkey $(CONFIG_INTEL_X86_PROD_UNIQUE_KEY) -encattr -kdk -sm -secure \
		-pubkeytype otp -algo aes256 -attribute 0x80000000=0x08000000 -attribute 0x80000002=0x0$(3) -attribute 0x80000006=0x0 -attribute 0x80000009=0x00001001 -attribute rollback=$(CONFIG_INTEL_X86_DTB_ROLLBACKID)\
		-cert $(CONFIG_INTEL_X86_CERTIFICATION) -infile $(2) -outfile $@.dtb.signed
	dd if=$@.dtb.signed of=$@.dtb bs=$(1) conv=sync;

	#its file update and fit image creation
	$(eval DTB_BASE_FILE:=$(basename $(notdir $(2))))
	$(eval TIMESTAMP:=$(shell cat $(STAGING_DIR_ROOT)/etc/timestamp))
	$(eval VERSION:=$(shell cat $(STAGING_DIR_ROOT)/etc/version))
	sed -e 's@KERNEL@$(IMAGE_KERNEL).fitimage@g' \
		-e 's@version = .*;@version = "$(VERSION)-$(TIMESTAMP)";@g' \
		-e 's@DTB@$@.dtb@g' kernel-dtb-fit.its > $(KDIR)/tmp/$(DTB_BASE_FILE)_kernel_dtb_fit.its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $(KDIR)/tmp/$(DTB_BASE_FILE)_kernel_dtb_fit.its $(KDIR)/tmp/$(DTB_BASE_FILE)_kernel_dtb.fit
endef
# generates fullimage in fit format.
define Build/fit-fullimage
	$(eval DTB_BASE_FILE:=$(basename $(notdir $@)))
	sed -e "s@KERNEL-DTB@$(1)@g" \
		-e "s@ROOTFS@$(2)@g" fullimage-fit.its > $(KDIR)/tmp/$(DTB_BASE_FILE).its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $(KDIR)/tmp/$(DTB_BASE_FILE).its $@
endef
endif
else
# generates kernel+dtb in fit format.
define Build/fit-kernel-dtb
	gzip -f -9n -c $(KDIR)/vmlinux > $(KDIR)/vmlinux.gz
	$(eval DTB_BASE_FILE:=$(basename $(notdir $(2))))
	$(eval TIMESTAMP:=$(shell cat $(STAGING_DIR_ROOT)/etc/timestamp))
	$(eval VERSION:=$(shell cat $(STAGING_DIR_ROOT)/etc/version))
	sed -e 's@KERNEL@$(KDIR)/vmlinux.gz@g' \
		-e 's@version = .*;@version = "$(VERSION)-$(TIMESTAMP)";@g' \
		-e 's@DTB@$(2)@g' kernel-dtb-fit.its > $(KDIR)/tmp/$(DTB_BASE_FILE)_kernel_dtb_fit.its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $(KDIR)/tmp/$(DTB_BASE_FILE)_kernel_dtb_fit.its $(KDIR)/tmp/$(DTB_BASE_FILE)_kernel_dtb.fit
endef
# generates fullimage in fit format.
define Build/fit-fullimage
	$(eval DTB_BASE_FILE:=$(basename $(notdir $@)))
	sed -e "s@KERNEL-DTB@$(1)@g" \
		-e "s@ROOTFS@$(2)@g" fullimage-fit.its > $(KDIR)/tmp/$(DTB_BASE_FILE).its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $(KDIR)/tmp/$(DTB_BASE_FILE).its $@
endef
endif
# generates rootfs in fit format.
define Build/fit-rootfs
	$(eval TIMESTAMP:=$(shell cat $(STAGING_DIR_ROOT)/etc/timestamp))
	$(eval VERSION:=$(shell cat $(STAGING_DIR_ROOT)/etc/version))
	dd if=$@ of=$@.tmp bs=16 conv=sync;
	mv $@.tmp $@
	sed -e 's@ROOTFS@$@@g' \
		-e 's@version = .*;@version = "$(VERSION)-$(TIMESTAMP)";@g' \
	rootfs-fit.its > $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.its $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit
	mkdir -p $(BIN_DIR)/single-images
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit $(BIN_DIR)/single-images/$(DEVICE_IMG_PREFIX)_rootfs.fit
endef

# generates dtb file with basedtb (eth dtb) and overlay PON dtbo.
define Build/singledtb
	mkdir -p $(BIN_DIR)/single-images
	$(eval DTB_BASE_FILE:=$(basename $(notdir $@)))
	sed -e 's@DTBO_FILE@$(1)@g' -e 's@DTB_FILE@$(2)@g' overlay_pon.its > $(KDIR)/tmp/$(DTB_BASE_FILE).its
	PATH=$(LINUX_DIR)/scripts/dtc:$(PATH) mkimage -f $(KDIR)/tmp/$(DTB_BASE_FILE).its $(KDIR)/tmp/$(DTB_BASE_FILE).itb
	mv -v $(KDIR)/tmp/$(DTB_BASE_FILE).itb $(KDIR)/tmp/$(DTB_BASE_FILE).dtb
	cp -vf $(KDIR)/tmp/$(DTB_BASE_FILE).dtb $(BIN_DIR)/single-images/
endef

ifeq ($(CONFIG_INTEL_X86_SECBOOT),y)
ifeq ($(CONFIG_INTEL_X86_EXTERNAL_IMAGE_SIGNING),y)
define Build/sign-rootfs
	mkdir -p $(BIN_DIR)/non_signed_image
	cp -vf $@ $(BIN_DIR)/non_signed_image
endef
define Build/imagegenerator-init
	echo "" > /dev/null
endef
define Build/update-binman
	mkdir -p $(BIN_DIR)/non_signed_image
	cp -vf $(IMAGE_KERNEL) $(BIN_DIR)/non_signed_image/
endef
define Build/update-sw-description
	echo "" > /dev/null
endef
define Build/binman
	echo "" > /dev/null
endef
define Build/swugenerator
	echo "" > /dev/null
endef
define Build/swugenerator-mxl
	echo "" > /dev/null
endef
define Build/build-fullimage
	echo "" > /dev/null
endef
else
define Build/update-binman
	$(eval TIMESTAMP:=$(shell cat $(STAGING_DIR_ROOT)/etc/timestamp))
	$(eval VERSION:=$(shell cat $(STAGING_DIR_ROOT)/etc/version))
	#kernel image
	dd if=$(IMAGE_KERNEL) of=$(IMAGE_KERNEL).fitimage bs=64 skip=1

	#initramfs kernel image (strip mkimage header)
	@if [ "$(CONFIG_TARGET_ROOTFS_INITRAMFS)" = "y" ]; then \
		echo "Stripping header from initramfs kernel"; \
		dd if=$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-initramfs-kernel.bin of=$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-initramfs-kernel.bin.fitimage bs=64 skip=1; \
	fi

	#dtb image signing and padding
	$(CONFIG_INTEL_X86_SIGNTOOL) sign -type BLw -prikey $(CONFIG_INTEL_X86_PRIVATE_KEY) -wrapkey $(CONFIG_INTEL_X86_PROD_UNIQUE_KEY) -encattr -kdk -sm -secure \
		-pubkeytype otp -algo aes256 -attribute 0x80000000=0x08000000 -attribute 0x80000002=0x08100000 -attribute 0x80000006=0x0 -attribute 0x80000009=0x00001001 -attribute rollback=$(CONFIG_INTEL_X86_DTB_ROLLBACKID)\
		-cert $(CONFIG_INTEL_X86_CERTIFICATION) -infile $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1) -outfile $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1).signed
	dd if=$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1).signed of=$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1) bs=16 conv=sync;

	#dtbo image signing and padding
	$(CONFIG_INTEL_X86_SIGNTOOL) sign -type BLw -prikey $(CONFIG_INTEL_X86_PRIVATE_KEY) -wrapkey $(CONFIG_INTEL_X86_PROD_UNIQUE_KEY) -encattr -kdk -sm -secure \
		-pubkeytype otp -algo aes256 -attribute 0x80000000=0x08000000 -attribute 0x80000002=0x08000000 -attribute 0x80000006=0x0 -attribute 0x80000009=0x00001001 -attribute rollback=$(CONFIG_INTEL_X86_DTB_ROLLBACKID)\
		-cert $(CONFIG_INTEL_X86_CERTIFICATION) -infile $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo -outfile $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo.signed
	dd if=$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo.signed of=$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo bs=16 conv=sync;

	@echo "Updating binman config"
	@if [ "$(CONFIG_TARGET_ROOTFS_INITRAMFS)" = "y" ]; then \
		echo "Using initramfs kernel for FIT image"; \
		sed -e 's@KERNEL@$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-initramfs-kernel.bin.fitimage@g' \
			-e 's@DTB@$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)@g' \
			-e 's@OVERLAY@$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo@g' \
			-e 's@ROOTFS@$(IMG_GEN_DIR)/build/$(DEVICE_IMG_PREFIX)-squashfs-fs.rootfs@g' \
			-e 's@version = ".*";@version = "$(VERSION)-$(TIMESTAMP)";@g' \
			-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
			imagegenerator/configs/binman/binman-sec-config.dts > $(IMG_GEN_DIR)/build/binman-config.dts; \
	else \
		echo "Using regular kernel for FIT image"; \
		sed -e 's@KERNEL@$(IMAGE_KERNEL).fitimage@g' \
			-e 's@DTB@$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)@g' \
			-e 's@OVERLAY@$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo@g' \
			-e 's@ROOTFS@$(IMG_GEN_DIR)/build/$(DEVICE_IMG_PREFIX)-squashfs-fs.rootfs@g' \
			-e 's@version = ".*";@version = "$(VERSION)-$(TIMESTAMP)";@g' \
			-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
			imagegenerator/configs/binman/binman-sec-config.dts > $(IMG_GEN_DIR)/build/binman-config.dts; \
	fi
endef
define Build/update-sw-description
	@echo "Updating sw-description file for $(1)"
	sed -e 's@board_name@$(1)@g' \
		-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
		imagegenerator/configs/swugenerator/sw-description-sec-config > $(IMG_GEN_DIR)/build/sw-description-config
endef

# func: swugenerator-mxl
# Generates Total SWU image and Full SWU image.
# Total SWU image contains the RBE, U-Boot, TEP firmware (for secureboot), kernel, dtb and rootfs in a single swu file.
# Full SWU image contains the kernel, dtb and rootfs in a single swu file.

define Build/swugenerator-mxl
	sed -e 's@board_name@$(1)@g' \
		-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
		imagegenerator/configs/swugenerator/sw-description-sec-config-total > $(IMG_GEN_DIR)/build/sw-description-config
	ln -sf sw-description-config $(IMG_GEN_DIR)/build/sw-description
	cd $(IMG_GEN_DIR) && ./scripts/gen_swu.sh
	cp $(IMG_GEN_DIR)/build/image.swu $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-totalimage.swu
	sed -e 's@board_name@$(1)@g' \
		-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
		imagegenerator/configs/swugenerator/sw-description-sec-config-full > $(IMG_GEN_DIR)/build/sw-description-config
	ln -sf sw-description-config $(IMG_GEN_DIR)/build/sw-description
	cd $(IMG_GEN_DIR) && ./scripts/gen_swu.sh
	cp $(IMG_GEN_DIR)/build/image.swu $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-fullimage.swu
endef
define Build/build-fullimage
	@echo "Building fullimage for $(1) with binman"
	cp -vf imagegenerator/configs/binman/binman-fullimage.dts $(IMG_GEN_DIR)/build/
	cp -vf imagegenerator/scripts/gen_binman_fullimage.sh $(IMG_GEN_DIR)/scripts/
	cd $(IMG_GEN_DIR) && ./scripts/gen_binman_fullimage.sh
	cp -vf $(IMG_GEN_DIR)/build/fullimage.itb $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage.itb
	cp -vf $(IMG_GEN_DIR)/build/fullimage.itb $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage.itb
endef
endif
else
define Build/update-binman
	$(eval TIMESTAMP:=$(shell cat $(STAGING_DIR_ROOT)/etc/timestamp))
	$(eval VERSION:=$(shell cat $(STAGING_DIR_ROOT)/etc/version))

	gzip -f -9n -c $(KDIR)/vmlinux > $(IMG_GEN_DIR)/build/vmlinux.gz

	#strip the header from rbe.
	dd if=$(IMG_GEN_DIR)/build/u-boot-spl-emmc.bin of=$(IMG_GEN_DIR)/build/u-boot-spl-emmc.bin.stripped bs=64 skip=1
	mv -vf $(IMG_GEN_DIR)/build/u-boot-spl-emmc.bin.stripped $(IMG_GEN_DIR)/build/u-boot-spl-emmc.bin

	@echo "Updating binman config"
	sed -e 's@INITRAMFS@$(IMG_GEN_DIR)/build/$(IMG_PREFIX)-secure-initramfs.cpio.gz@g' \
		-e 's@DTB@$(IMG_GEN_DIR)/build/$(DEVICE_IMG_PREFIX)-$(1)@g' \
		-e 's@OVERLAY@$(IMG_GEN_DIR)/build/$(DEVICE_IMG_PREFIX)-overlay.dtbo@g' \
		-e 's@ROOTFS@$(IMG_GEN_DIR)/build/$(DEVICE_IMG_PREFIX)-squashfs-fs.rootfs@g' \
		-e 's@version = ".*";@version = "$(VERSION)-$(TIMESTAMP)";@g' \
		-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
		imagegenerator/configs/binman/binman-config.dts > $(IMG_GEN_DIR)/build/binman-config.dts
endef
define Build/update-sw-description
	@echo "Updating sw-description file for $(1)"
	sed -e 's@board_name@$(1)@g' \
		-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
		imagegenerator/configs/swugenerator/sw-description-config > $(IMG_GEN_DIR)/build/sw-description-config
endef

# func: swugenerator-mxl
# Generates Total SWU image and Full SWU image.
# Total SWU image contains the RBE, U-Boot, TEP firmware (for secureboot), kernel, dtb and rootfs in a single swu file.
# Full SWU image contains the kernel, dtb and rootfs in a single swu file.

define Build/swugenerator-mxl
	sed -e 's@board_name@$(1)@g' \
		-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
		imagegenerator/configs/swugenerator/sw-description-config-total > $(IMG_GEN_DIR)/build/sw-description-config
	ln -sf sw-description-config $(IMG_GEN_DIR)/build/sw-description
	cd $(IMG_GEN_DIR) && ./scripts/gen_swu.sh
	cp $(IMG_GEN_DIR)/build/image.swu $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-totalimage.swu
	sed -e 's@board_name@$(1)@g' \
		-e 's@version = PRPLOS_VERSION;@version = "$(strip $(shell $(SCRIPT_DIR)/prplos_version.sh))";@g' \
		imagegenerator/configs/swugenerator/sw-description-config-full > $(IMG_GEN_DIR)/build/sw-description-config
	ln -sf sw-description-config $(IMG_GEN_DIR)/build/sw-description
	cd $(IMG_GEN_DIR) && ./scripts/gen_swu.sh
	cp $(IMG_GEN_DIR)/build/image.swu $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-fullimage.swu
endef
define Build/build-fullimage
	$(if $(findstring 10g,$(1)),@echo "Skipping fullimage for $(1) (10g target)",\
	@echo "Building fullimage for $(1) with binman" && \
	cp -vf imagegenerator/configs/binman/binman-fullimage.dts $(IMG_GEN_DIR)/build/ && \
	cp -vf imagegenerator/scripts/gen_binman_fullimage.sh $(IMG_GEN_DIR)/scripts/ && \
	cd $(IMG_GEN_DIR) && ./scripts/gen_binman_fullimage.sh && \
	cp -vf $(IMG_GEN_DIR)/build/fullimage.itb $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage.itb && \
	cp -vf $(IMG_GEN_DIR)/build/fullimage.itb $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage.itb)
endef
endif

define Build/custom
	$(eval board := $(word 1,$(1)))
	$(eval uboot := $(word 2,$(1)))

	if [ -f $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-u-boot.itb ] ; then \
		mv -vf $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-u-boot.itb $(BIN_DIR)/uboot-$(uboot)/u-boot.itb ; \
	fi
	if [ -f $(IMG_GEN_DIR)/build/tep_fw.itb ] ; then \
		cp -vf $(IMG_GEN_DIR)/build/tep_fw.itb $(BIN_DIR)/tep_fw.itb; \
	fi
	if [ -f $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-totalimage.swu ] ; then \
		cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-totalimage.swu $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(board)-totalimage.swu ; \
	fi
	if [ -f $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-fullimage.swu ] ; then \
		cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-fullimage.swu $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(board)-fullimage.swu ; \
	fi
	if [ -f $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-image.swu ] ; then \
		cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-image.swu $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(board)-image.swu ; \
	fi
	$(if $(findstring 10g,$(board)),,\
	if [ -f $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-kernel.itb ] ; then \
		mv -vf $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-kernel.itb $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(board)-kernel.itb ; \
	fi ; \
	if [ -f $(IMG_GEN_DIR)/build/ext4.img ] ; then \
		cp -vf $(IMG_GEN_DIR)/build/ext4.img $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(board)-ext4.img ; \
	fi)

endef

define Build/update-script
	@echo "Running Build/update-script"
	mkimage -f update_script.its $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-update_script.itb
endef

define Build/generate-ext4fs
	[ ! -f "$(BIN_DIR)/ext4.fs" ] && dd if=/dev/zero of="$(BIN_DIR)/ext4.fs" bs=1M count=112 && mkfs.ext4 -v -b 4096 -O ^metadata_csum,^64bit "$(BIN_DIR)/ext4.fs" || echo "" > /dev/null
endef

# Customized build script for kernel/dtb.
# This is taken from default Device/Build/image, with the removal
# of rootfs since it should not be linked with kernel/dtb.
ifeq ($(CONFIG_INTEL_X86_EXTERNAL_IMAGE_SIGNING),y)
define Device/Build/image-non-rootfs
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs
  $(eval $(call Device/Export,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs,$(1)))

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs: $$(KDIR_KERNEL_IMAGE)
	@rm -rf $$@
	[ -f $$(word 1,$$^) ]
	$$(call concat_cmd,$(IMAGE/$(1)))

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs
	mkdir -p $(BIN_DIR)/non_signed_image
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs $(BIN_DIR)/non_signed_image/$(DEVICE_IMG_PREFIX)-$(1)
	rm -rf $(BIN_DIR)/non_signed_image/$(DEVICE_IMG_PREFIX)-kernel.bin

endef
else
define Device/Build/image-non-rootfs
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs
  $(eval $(call Device/Export,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs,$(1)))

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs: $$(KDIR_KERNEL_IMAGE)
	@rm -rf $$@
	[ -f $$(word 1,$$^) ]
	$$(call concat_cmd,$(IMAGE/$(1)))

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-image-non-rootfs $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)

endef
endif

define Device/Build/singledtb
  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 5,$(IMAGE/$(1))): $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo-image-non-rootfs $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 4,$(IMAGE/$(1)))-image-non-rootfs
	@rm -rf $$@
	[ -f $$(word 1,$$^) ]
	$$(call Build/singledtb,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-overlay.dtbo-image-non-rootfs,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 4,$(IMAGE/$(1)))-image-non-rootfs)

endef

define Device/Build/fullimage
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage
  $(eval $(call Device/Export,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage,$(1)))

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage: $$(KDIR_KERNEL_IMAGE) $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-squashfs-$$(ROOTFS) $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 4,$(IMAGE/$(1)))-image-non-rootfs
	@rm -rf $$@
	[ -f $$(word 1,$$^) ]
	$$(call Build/fullimage,$(word 2,$(IMAGE/$(1))),$(BIN_DIR)/$(DEVICE_IMG_PREFIX)-squashfs-$$(ROOTFS),$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 4,$(IMAGE/$(1)))-image-non-rootfs,8000000)

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage
	mkdir -p $(BIN_DIR)/dual-images
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage $(BIN_DIR)/dual-images/$(DEVICE_IMG_PREFIX)-$(1)

  .NOTPARALLEL: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage

endef

define Device/Build/singlefullimage
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage
  $(eval $(call Device/Export,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage,$(1)))

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage: $$(KDIR_KERNEL_IMAGE) $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-squashfs-$$(ROOTFS) $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 5,$(IMAGE/$(1)))
	@rm -rf $$@
	[ -f $$(word 1,$$^) ]
	$$(call Build/fullimage,$(word 2,$(IMAGE/$(1))),$(BIN_DIR)/$(DEVICE_IMG_PREFIX)-squashfs-$$(ROOTFS),$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 5,$(IMAGE/$(1))),8100000)

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage
	mkdir -p $(BIN_DIR)/single-images
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(1)-fullimage $(BIN_DIR)/single-images/$(DEVICE_IMG_PREFIX)-$(1)

  .NOTPARALLEL: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(1)-fullimage

endef
define Device/Build/fitimage
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit: $$(KDIR_KERNEL_IMAGE) $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 4,$(IMAGE/$(1)))-image-non-rootfs
	$$(call Build/fit-kernel-dtb,$(word 2,$(IMAGE/$(1))),$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 4,$(IMAGE/$(1)))-image-non-rootfs,8000000)

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-squashfs-$$(ROOTFS) $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit
	$$(call Build/fit-fullimage,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit)

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-squashfs-$$(ROOTFS) $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit
	mkdir -p $(BIN_DIR)/dual-images
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit $(BIN_DIR)/dual-images/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit $(BIN_DIR)/dual-images/$(DEVICE_IMG_PREFIX)_rootfs.fit

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit
	mkdir -p $(BIN_DIR)/dual-images
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit $(BIN_DIR)/dual-images/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit

  .NOTPARALLEL: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_kernel_dtb.fit
  .NOTPARALLEL: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 4,$(IMAGE/$(1))))_fullimage.fit

endef

define Device/Build/singlefitimage
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit
  $$(_TARGET): $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit: $$(KDIR_KERNEL_IMAGE) $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 5,$(IMAGE/$(1)))
	$$(call Build/fit-kernel-dtb,$(word 2,$(IMAGE/$(1))),$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(word 5,$(IMAGE/$(1))),8100000)

  $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-squashfs-$$(ROOTFS) $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit
	$$(call Build/fit-fullimage,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit,$(KDIR)/tmp/$(DEVICE_IMG_PREFIX)_rootfs.fit)

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit
	mkdir -p $(BIN_DIR)/single-images
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit $(BIN_DIR)/single-images/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit

  .IGNORE: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit

  $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit: $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit
	mkdir -p $(BIN_DIR)/single-images
	cp -vf $(KDIR)/tmp/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit $(BIN_DIR)/single-images/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit

  .NOTPARALLEL: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_kernel_dtb.fit
  .NOTPARALLEL: $(BIN_DIR)/$(DEVICE_IMG_PREFIX)-$(basename $(word 5,$(IMAGE/$(1))))_fullimage.fit

endef

# Default openwrt image script builds different images (kernel/dtb) per
# rootfs. This is not ideal for our usecase, which should only need
# different image for the rootfs itself (kernel/dtb should be common).
# We use customized build script for this reason.
define Device/Build
  $(if $(CONFIG_TARGET_ROOTFS_INITRAMFS),$(call Device/Build/initramfs,$(1)))
  $(call Device/Build/kernel,$(1))

  $$(eval $$(foreach compile,$$(COMPILE), \
    $$(call Device/Build/compile,$$(compile),$(1))))

  $$(eval $$(foreach fs,$$(filter $(TARGET_FILESYSTEMS),$$(FILESYSTEMS)), \
    $$(call Device/Build/image,$$(fs),$$(ROOTFS),$(1))))

  $$(eval $$(foreach image,$$(IMAGES), \
    $$(call Device/Build/image-non-rootfs,$$(image),$(1))))

  $$(eval $$(foreach artifact,$$(ARTIFACTS), \
    $$(call Device/Build/artifact,$$(artifact),$(1))))

endef

define Device/LGM_GENERIC
  KERNEL_LOADADDR := 0x2000000
  KERNEL_ENTRY := 0x2000000
  KERNEL := kernel-bin | gzip | uImage-x86_64 gzip | pad-offset 16 0
  KERNEL_INITRAMFS := kernel-bin | gzip | uImage-x86_64 gzip | pad-offset 16 0
  DEVICE_DTS_DIR := ../dts
  IMAGE/kernel.bin := append-kernel
  IMAGE/fs.rootfs := append-rootfs  | sign-rootfs | generate-ext4fs
  UIMAGE_NAME:=$(if $(UIMAGE_NAME),LGM-$(UIMAGE_NAME))
  ARTIFACT/update_script.itb := update-script
  ARTIFACTS += update_script.itb
  IMG_GEN_DIR := $$(wildcard $$(BUILD_DIR_BASE)/hostpkg/imagegenerator-*)
endef

# Device/SWUPDATE_INIT - Generates a SWUpdate (.swu) image image for a board.
#
# This macro sets up the full SWUpdate image generation pipeline by:
#   1. Collecting binman input files (u-boot, TEP firmware, kernel, DTB,
#      overlay DTBO, initramfs, rootfs, and post-binman scripts)
#   2. Initializing the image generator workspace
#   3. Updating and running binman to produce FIT images (kernel.itb, rootfs.itb, etc.)
#   4. Building the fullimage (fullimage.itb)
#   5. Updating sw-description and running swugenerator to produce the final .swu image
#   6. Copying final images to the output directory
#
# Arguments:
#   $(1) - Target name, used as artifact prefix.
#   $(2) - Board name, sw-description board identifier for the SWUpdate image.
#   $(3) - DTB filename.
#   $(4) - U-Boot directory name.
define Device/SWUPDATE_INIT
  $(if $(wildcard $(KDIR)/$(4)),\
  BINMAN_INPUT_$(1) := $$(KDIR)/$(4)/u-boot-*/u-boot.lzimg \
		$$(KDIR)/$(4)/u-boot-*/spl/u-boot-spl-emmc.bin \
		$$(KDIR)/tep_fw-*/tep_fw.bin \
		$$(KDIR)/tmp/$$(DEVICE_IMG_PREFIX)-$(3) \
		$$(KDIR)/tmp/$$(DEVICE_IMG_PREFIX)-overlay.dtbo \
		$$(BIN_DIR)/$(IMG_PREFIX)-secure-initramfs.cpio.gz \
		$$(KDIR)/tmp/$$(DEVICE_IMG_PREFIX)-squashfs-fs.rootfs \
		imagegenerator/./scripts/post-binman/100_gen_ext4.sh
  ARTIFACT/$(1)-image.swu := imagegenerator-init $$(BINMAN_INPUT_$(1)) | \
		update-binman $(3) | \
		binman binman-config.dts | \
		build-fullimage $(1) | \
		update-sw-description $(2) | \
		swugenerator sw-description-config | \
		$(if $(CONFIG_INTEL_X86_MXL_SWU_IMAGE),swugenerator-mxl $(2) |) \
		custom $(1) $(4)
  ARTIFACTS += $(1)-image.swu)
endef

define Device/CBSP_B0
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM CBSP B-Step Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/simics_datapath.dtb := dtb lgm_simics_datapath
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_851_wan_phy.dtb := dtb octopus_851_wan_phy
  IMAGE/octopus_851_fixedlink.dtb := dtb octopus_851_fixedlink
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/simics_b0_fullimage.img := fullimage 16 squashfs simics_datapath.dtb
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_851_wan_phy_fullimage.img := fullimage 16 squashfs octopus_851_wan_phy.dtb
  IMAGES += kernel.bin \
	simics_datapath.dtb \
	lgp_b0.dtb octopus_851.dtb octopus_641.dtb octopus_851_wan_phy.dtb octopus_851_fixedlink.dtb
  FULLIMAGES := \
	simics_b0_fullimage.img \
	lgp_b0_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img \
	octopus_851_wan_phy_fullimage.img
  ROOTFS := fs.rootfs
endef
TARGET_DEVICES += CBSP_B0

define Device/EVM_CBSP_B0
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := EVM CBSP B 0 device
  IMAGE/lgm_evm_b0.dtb := dtb lgm_evm_b0
  IMAGES += kernel.bin lgm_evm_b0.dtb
  ROOTFS := fs.rootfs
  DEVICE_PACKAGES :=
endef
TARGET_DEVICES += EVM_CBSP_B0

define Device/CBSP_MINIFS_B0
  $(Device/CBSP_B0)
  DEVICE_TITLE := LGM CBSP minifs B-step model
  DEVICE_PACKAGES :=
endef
TARGET_DEVICES += CBSP_MINIFS_B0

define Device/CBSP_C0
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM CBSP C-Step Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgm_haps.dtb := dtb lgm_haps
  IMAGE/lgm_haps_datapath.dtb := dtb lgm_haps_datapath
  IMAGE/lgm_haps_pcie.dtb := dtb lgm_haps_pcie
  IMAGE/lgm_haps_emmc.dtb := dtb lgm_haps_emmc
  IMAGE/lgmc_haps_fullimage.img := fullimage 16 squashfs lgm_haps_datapath.dtb
  IMAGES += kernel.bin \
	simics_datapath.dtb \
	lgp_b0.dtb \
	lgm_haps.dtb \
	lgm_haps_datapath.dtb \
	lgm_haps_pcie.dtb \
	lgm_haps_emmc.dtb
  FULLIMAGES := lgmc_haps_fullimage.img
  ROOTFS := fs.rootfs
endef
TARGET_DEVICES += CBSP_C0

define Device/CBSP_HAPS_C0
  $(Device/CBSP_C0)
  DEVICE_TITLE := LGM CBSP HAPS C-step model
  DEVICE_PACKAGES := $(CBSP_WAV700_UGW_PACKAGES_UCI) $(CBSP_WAV700_PACKAGES_UCI) $(UGW_PACKAGE_DCDP) $(PCIUTILS_PACKAGE)
endef
TARGET_DEVICES += CBSP_HAPS_C0

define Device/CBSP_MINIFS_WAVE_B0
  $(Device/CBSP_B0)
  DEVICE_TITLE := LGM CBSP minifs B-step model with WAVE
  DEVICE_PACKAGES := $(CBSP_WAV600_UGW_PACKAGES_UCI) $(WAV600_PACKAGES_UCI) $(UGW_PACKAGE_DCDP)
endef
TARGET_DEVICES += CBSP_MINIFS_WAVE_B0

define Device/LGM_UGW
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM UGW Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fixedlink.dtb := dtb lgp_b0_fixedlink
  IMAGE/lgm_evm_b0.dtb := dtb lgm_evm_b0
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_851_nand.dtb := dtb octopus_851_nand
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_641_pon.dtb := dtb octopus_641_pon
  IMAGE/octopus_641_10g_lan_pon.dtb := dtb octopus_641_10g_lan_pon
  IMAGE/octopus_641_10g_lan_eth.dtb := dtb octopus_641_10g_lan_eth
  IMAGE/octopus_641_10g_lan_eth_nand.dtb := dtb octopus_641_10g_lan_eth_nand
  IMAGE/octopus_641_wav700_eth.dtb := dtb octopus_641_wav700_eth
  IMAGE/octopus_641_wav700_pon.dtb := dtb octopus_641_wav700_pon
  IMAGE/octopus_641_pm.dtb := dtb octopus_641_pm
  IMAGE/octopus_641_aic_10g_eth.dtb := dtb octopus_641_aic_10g_eth
  IMAGE/octopus_641_aic_gsw140.dtb := dtb octopus_641_aic_gsw140
  IMAGE/octopus_641_aic_moca.dtb := dtb octopus_641_aic_moca
  IMAGE/octopus_641_docsis.dtb := dtb octopus_641_docsis
  IMAGE/octopus_851_wan_phy.dtb := dtb octopus_851_wan_phy
  IMAGE/octopus_851_pon.dtb := dtb octopus_851_pon
  IMAGE/octopus_851_docsis.dtb := dtb octopus_851_docsis
  IMAGE/octopus_851_fixedlink.dtb := dtb octopus_851_fixedlink
  IMAGE/octopus_851_wav700_eth.dtb := dtb octopus_851_wav700_eth
  IMAGE/octopus_851_wav700_pon.dtb := dtb octopus_851_wav700_pon
  IMAGE/octopus_851_wav700_eth_pm.dtb := dtb octopus_851_wav700_eth_pm
  IMAGE/octopus_851_wav700_pon_pm.dtb := dtb octopus_851_wav700_pon_pm
  IMAGE/octopus_851_wav700_docsis.dtb := dtb octopus_851_wav700_docsis
  IMAGE/octopus_851_pm.dtb := dtb octopus_851_pm
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/lgp_b0_docsis.dtb := dtb lgp_b0_docsis
  IMAGE/lgp_b0_wav700_docsis.dtb := dtb lgp_b0_wav700_docsis
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/lgm_c0_1GB_DDR_mxl86249.dtb := dtb octopus_640_1GB_DDR_mxl86249
  IMAGE/lgm_c0_1GB_DDR_10g_lan.dtb := dtb octopus_640_1GB_DDR_10g_lan
  IMAGE/lgm_c0_1GB_DDR_mxl86249_qspinand.dtb := dtb octopus_640_1GB_DDR_mxl86249_qspinand
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_641_pon_fullimage.img := fullimage 16 squashfs octopus_641_pon.dtb
  IMAGE/octopus_641_10g_lan_pon_fullimage.img := fullimage 16 squashfs octopus_641_10g_lan_pon.dtb
  IMAGE/octopus_641_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_641_wav700_eth.dtb
  IMAGE/octopus_641_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_641_wav700_pon.dtb
  IMAGE/octopus_641_pm_fullimage.img := fullimage 16 squashfs octopus_641_pm.dtb
  IMAGE/octopus_851_wan_phy_fullimage.img := fullimage 16 squashfs octopus_851_wan_phy.dtb
  IMAGE/octopus_851_pon_fullimage.img := fullimage 16 squashfs octopus_851_pon.dtb
  IMAGE/octopus_851_docsis_fullimage.img := fullimage 16 squashfs octopus_851_docsis.dtb
  IMAGE/octopus_851_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth.dtb
  IMAGE/octopus_851_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon.dtb
  IMAGE/octopus_851_wav700_eth_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth_pm.dtb
  IMAGE/octopus_851_wav700_pon_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon_pm.dtb
  IMAGE/octopus_851_wav700_docsis_fullimage.img := fullimage 16 squashfs octopus_851_wav700_docsis.dtb
  IMAGE/octopus_851_pm_fullimage.img := fullimage 16 squashfs octopus_851_pm.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/octopus_641_aic_10g_eth_fullimage.img := fullimage 16 squashfs octopus_641_aic_10g_eth.dtb
  IMAGE/octopus_641_aic_gsw140_fullimage.img := fullimage 16 squashfs octopus_641_aic_gsw140.dtb
  IMAGE/octopus_641_aic_moca_fullimage.img := fullimage 16 squashfs octopus_641_aic_moca.dtb
  IMAGE/lgm_c0_1GB_DDR_mxl86249_fullimage.img := fullimage 16 squashfs lgm_c0_1GB_DDR_mxl86249.dtb
  IMAGE/lgm_c0_1GB_DDR_10g_lan_fullimage.img := fullimage 16 squashfs lgm_c0_1GB_DDR_10g_lan.dtb
  IMAGES += kernel.bin lgp_b0.dtb lgp_b0_pon.dtb lgm_evm_b0.dtb octopus_851.dtb octopus_641.dtb octopus_641_pon.dtb octopus_641_10g_lan_pon.dtb octopus_641_10g_lan_eth.dtb octopus_641_wav700_eth.dtb octopus_641_wav700_pon.dtb octopus_851_wan_phy.dtb octopus_851_fixedlink.dtb octopus_851_wav700_eth.dtb octopus_851_wav700_pon.dtb lgp_b0_fixedlink.dtb \
		lgp_b0_docsis.dtb \
		lgp_b0_wav700_docsis.dtb \
		octopus_851_docsis.dtb \
		octopus_851_wav700_docsis.dtb \
		octopus_851_pm.dtb \
		octopus_641_aic_10g_eth.dtb \
		octopus_641_aic_gsw140.dtb \
		octopus_641_aic_moca.dtb \
		octopus_641_pm.dtb \
		octopus_641_docsis.dtb \
		octopus_851_wav700_eth_pm.dtb \
		octopus_851_wav700_pon_pm.dtb \
		octopus_851_pon.dtb \
		octopus_641_10g_lan_eth_nand.dtb \
		octopus_851_nand.dtb \
		lgm_c0_1GB_DDR_mxl86249.dtb \
		lgm_c0_1GB_DDR_10g_lan.dtb \
		lgm_c0_1GB_DDR_mxl86249_qspinand.dtb

  FULLIMAGES := lgp_b0_fullimage.img lgp_b0_pon_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img octopus_641_pon_fullimage.img \
		octopus_851_wan_phy_fullimage.img octopus_851_pon_fullimage.img octopus_851_wav700_eth_fullimage.img octopus_851_wav700_pon_fullimage.img octopus_641_10g_lan_pon_fullimage.img octopus_641_wav700_eth_fullimage.img octopus_641_wav700_pon_fullimage.img \
		octopus_851_docsis_fullimage.img \
		octopus_851_wav700_docsis_fullimage.img \
		octopus_851_pm_fullimage.img \
		octopus_641_aic_10g_eth_fullimage.img \
		octopus_641_aic_gsw140_fullimage.img \
		octopus_641_pm_fullimage.img \
		octopus_641_aic_moca_fullimage.img \
		octopus_851_wav700_eth_pm_fullimage.img \
		octopus_851_wav700_pon_pm_fullimage.img \
		lgm_c0_1GB_DDR_mxl86249_fullimage.img \
		lgm_c0_1GB_DDR_10g_lan_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES) \
		     $(DSL_CPE_GFAST_PACKAGES_PRX) $(DSL_CPE_GFAST_PACKAGES_RELEASE) \
		     $(PM_PACKAGES)\
		     $(WAV600_UGW_PACKAGES_UCI) $(WAV600_PACKAGES_UCI) \
		     $(UGW_DIAG_DSL_PACKAGES)
endef
TARGET_DEVICES += LGM_UGW

define Device/LGM_UGW_WLANOSP
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM UGW Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fixedlink.dtb := dtb lgp_b0_fixedlink
  IMAGE/lgm_evm_b0.dtb := dtb lgm_evm_b0
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_851_nand.dtb := dtb octopus_851_nand
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_641_pon.dtb := dtb octopus_641_pon
  IMAGE/octopus_641_10g_lan_pon.dtb := dtb octopus_641_10g_lan_pon
  IMAGE/octopus_641_10g_lan_eth.dtb := dtb octopus_641_10g_lan_eth
  IMAGE/octopus_641_10g_lan_eth_nand.dtb := dtb octopus_641_10g_lan_eth_nand
  IMAGE/octopus_641_wav700_eth.dtb := dtb octopus_641_wav700_eth
  IMAGE/octopus_641_wav700_pon.dtb := dtb octopus_641_wav700_pon
  IMAGE/octopus_641_pm.dtb := dtb octopus_641_pm
  IMAGE/octopus_641_aic_10g_eth.dtb := dtb octopus_641_aic_10g_eth
  IMAGE/octopus_641_aic_gsw140.dtb := dtb octopus_641_aic_gsw140
  IMAGE/octopus_641_aic_moca.dtb := dtb octopus_641_aic_moca
  IMAGE/octopus_641_docsis.dtb := dtb octopus_641_docsis
  IMAGE/octopus_851_wan_phy.dtb := dtb octopus_851_wan_phy
  IMAGE/octopus_851_pon.dtb := dtb octopus_851_pon
  IMAGE/octopus_851_docsis.dtb := dtb octopus_851_docsis
  IMAGE/octopus_851_fixedlink.dtb := dtb octopus_851_fixedlink
  IMAGE/octopus_851_wav700_eth.dtb := dtb octopus_851_wav700_eth
  IMAGE/octopus_851_wav700_pon.dtb := dtb octopus_851_wav700_pon
  IMAGE/octopus_851_wav700_eth_pm.dtb := dtb octopus_851_wav700_eth_pm
  IMAGE/octopus_851_wav700_pon_pm.dtb := dtb octopus_851_wav700_pon_pm
  IMAGE/octopus_851_wav700_docsis.dtb := dtb octopus_851_wav700_docsis
  IMAGE/octopus_851_pm.dtb := dtb octopus_851_pm
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/lgp_b0_docsis.dtb := dtb lgp_b0_docsis
  IMAGE/lgp_b0_wav700_docsis.dtb := dtb lgp_b0_wav700_docsis
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_641_pon_fullimage.img := fullimage 16 squashfs octopus_641_pon.dtb
  IMAGE/octopus_641_10g_lan_pon_fullimage.img := fullimage 16 squashfs octopus_641_10g_lan_pon.dtb
  IMAGE/octopus_641_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_641_wav700_eth.dtb
  IMAGE/octopus_641_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_641_wav700_pon.dtb
  IMAGE/octopus_641_pm_fullimage.img := fullimage 16 squashfs octopus_641_pm.dtb
  IMAGE/octopus_851_wan_phy_fullimage.img := fullimage 16 squashfs octopus_851_wan_phy.dtb
  IMAGE/octopus_851_pon_fullimage.img := fullimage 16 squashfs octopus_851_pon.dtb
  IMAGE/octopus_851_docsis_fullimage.img := fullimage 16 squashfs octopus_851_docsis.dtb
  IMAGE/octopus_851_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth.dtb
  IMAGE/octopus_851_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon.dtb
  IMAGE/octopus_851_wav700_eth_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth_pm.dtb
  IMAGE/octopus_851_wav700_pon_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon_pm.dtb
  IMAGE/octopus_851_wav700_docsis_fullimage.img := fullimage 16 squashfs octopus_851_wav700_docsis.dtb
  IMAGE/octopus_851_pm_fullimage.img := fullimage 16 squashfs octopus_851_pm.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/octopus_641_aic_10g_eth_fullimage.img := fullimage 16 squashfs octopus_641_aic_10g_eth.dtb
  IMAGE/octopus_641_aic_gsw140_fullimage.img := fullimage 16 squashfs octopus_641_aic_gsw140.dtb
  IMAGE/octopus_641_aic_moca_fullimage.img := fullimage 16 squashfs octopus_641_aic_moca.dtb
  IMAGES += kernel.bin lgp_b0.dtb lgp_b0_pon.dtb lgm_evm_b0.dtb octopus_851.dtb octopus_641.dtb octopus_641_pon.dtb octopus_641_10g_lan_pon.dtb octopus_641_10g_lan_eth.dtb octopus_641_wav700_eth.dtb octopus_641_wav700_pon.dtb octopus_851_wan_phy.dtb octopus_851_fixedlink.dtb octopus_851_wav700_eth.dtb octopus_851_wav700_pon.dtb lgp_b0_fixedlink.dtb \
		lgp_b0_docsis.dtb \
		lgp_b0_wav700_docsis.dtb \
		octopus_851_docsis.dtb \
		octopus_851_wav700_docsis.dtb \
		octopus_851_pm.dtb \
		octopus_641_aic_10g_eth.dtb \
		octopus_641_aic_gsw140.dtb \
		octopus_641_aic_moca.dtb \
		octopus_641_pm.dtb \
		octopus_641_docsis.dtb \
		octopus_851_wav700_eth_pm.dtb \
		octopus_851_wav700_pon_pm.dtb \
		octopus_851_pon.dtb \
		octopus_641_10g_lan_eth_nand.dtb \
		octopus_851_nand.dtb

  FULLIMAGES := lgp_b0_fullimage.img lgp_b0_pon_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img octopus_641_pon_fullimage.img \
		octopus_851_wan_phy_fullimage.img octopus_851_pon_fullimage.img octopus_851_wav700_eth_fullimage.img octopus_851_wav700_pon_fullimage.img octopus_641_10g_lan_pon_fullimage.img octopus_641_wav700_eth_fullimage.img octopus_641_wav700_pon_fullimage.img \
		octopus_851_docsis_fullimage.img \
		octopus_851_wav700_docsis_fullimage.img \
		octopus_851_pm_fullimage.img \
		octopus_641_aic_10g_eth_fullimage.img \
		octopus_641_aic_gsw140_fullimage.img \
		octopus_641_pm_fullimage.img \
		octopus_641_aic_moca_fullimage.img \
		octopus_851_wav700_eth_pm_fullimage.img \
		octopus_851_wav700_pon_pm_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES) \
		     $(DSL_CPE_GFAST_PACKAGES_PRX) $(DSL_CPE_GFAST_PACKAGES_RELEASE) \
		     $(PM_PACKAGES)\
		     $(WAV700_UGW_PACKAGES_UCI_OSP) $(WAV700_PACKAGES_UCI_OSP) \
		     $(UGW_DIAG_DSL_PACKAGES)
endef
TARGET_DEVICES += LGM_UGW_WLANOSP

define Device/LGM_PRPL
  $(Device/LGM_GENERIC)
  UIMAGE_NAME:=$(if $(UIMAGE_NAME),PRPL-$(UIMAGE_NAME))
  DEVICE_TITLE := LGM Model for prplOS
  IMAGE/overlay.dtbo := dtbo overlay_pon
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/lgp.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/lgp_fullimage.img := fullimage 16 squashfs lgp_b0.dtb lgp.dtb
  IMAGES += kernel.bin \
        overlay.dtbo \
        lgp_b0.dtb \
        lgp_b0_pon.dtb
  FULLIMAGES := lgp_b0_fullimage.img lgp_b0_pon_fullimage.img
  SINGLE_FULLIMAGE := lgp_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(PM_PACKAGES)\
		     $(UGW_DIAG_PACKAGES)
endef
TARGET_DEVICES += LGM_PRPL

define Device/LGM_C0_HAPS_PRPL
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM C0 HAPS Model for prplOS
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGES += kernel.bin \
        lgp_b0.dtb
  FULLIMAGES := lgp_b0_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(PM_PACKAGES)\
             $(UGW_DIAG_PACKAGES)
endef
TARGET_DEVICES += LGM_C0_HAPS_PRPL

define Device/PRPL_C0
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM C Model for prplOS
  IMAGE/2GB_DDR_10g_lan.dtb := dtb octopus_640_2GB_DDR_10g_lan
  IMAGE/2GB_DDR_10g_lan_pon.dtb := dtb octopus_640_10g_lan_pon
  IMAGE/2GB_DDR_10g_lan_wav700_eth_fullimage.img := fullimage 16 squashfs 2GB_DDR_10g_lan.dtb
  IMAGE/2GB_DDR_10g_lan_wav700_pon_fullimage.img := fullimage 16 squashfs 2GB_DDR_10g_lan_pon.dtb
  IMAGES += kernel.bin \
            2GB_DDR_10g_lan.dtb \
      	    2GB_DDR_10g_lan_pon.dtb
  FULLIMAGES := 2GB_DDR_10g_lan_wav700_eth_fullimage.img 2GB_DDR_10g_lan_wav700_pon_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(PM_PACKAGES)\
             $(UGW_DIAG_PACKAGES)
endef
TARGET_DEVICES += PRPL_C0

define Device/PRPL_OSP_TB341
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM Model for prplOS osp tb341
  IMAGE/overlay.dtbo := dtbo overlay_pon
  IMAGE/osp_tb341.dtb := dtb osp_tb341
  IMAGE/osp_tb341_pon.dtb := dtb osp_tb341_pon
  IMAGE/osp_v1.dtb := dtb osp_tb341
  IMAGE/osp_tb341_fullimage.img := fullimage 16 squashfs osp_tb341.dtb
  IMAGE/osp_tb341_pon_fullimage.img := fullimage 16 squashfs osp_tb341_pon.dtb
  IMAGE/osp_v1_fullimage.img := fullimage 16 squashfs osp_tb341.dtb osp_v1.dtb
  IMAGES += kernel.bin \
        overlay.dtbo \
        osp_tb341.dtb \
        osp_tb341_pon.dtb
  FULLIMAGES := osp_tb341_fullimage.img osp_tb341_pon_fullimage.img
  SINGLE_FULLIMAGE := osp_v1_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(PM_PACKAGES)\
		     $(UGW_DIAG_PACKAGES)
endef
TARGET_DEVICES += PRPL_OSP_TB341

define Device/PRPL_OSP_v2
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM Model for prplOS osp v2(a and b step)
  IMAGE/overlay.dtbo := dtbo overlay_pon
  IMAGE/tb341_wav700_eth.dtb := dtb osp_tb341_v2_wav700_eth
  IMAGE/wgrtd159be_b_wav700_eth.dtb := dtb osp_wgrtd159be_b_v2_wav700_eth
  $(call Device/SWUPDATE_INIT,tb341_wav700,ospv2,tb341_wav700_eth.dtb,octopus-urx641-overlay-fit-p34x-phy-emmc-prpl)
  $(call Device/SWUPDATE_INIT,wgrtd159be_b_wav700,ospv2,wgrtd159be_b_wav700_eth.dtb,octopus-urx641-4GB-ddr-overlay-fit-p34x-phy-emmc-prpl)
  IMAGES += kernel.bin \
		overlay.dtbo \
		tb341_wav700_eth.dtb \
		wgrtd159be_b_wav700_eth.dtb
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(PM_PACKAGES)\
                     $(UGW_DIAG_PACKAGES)
endef
TARGET_DEVICES += PRPL_OSP_v2

define Device/PRPL_MB_URX_MINIFS
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM CBSP B-Step minifs Model
  IMAGE/851_eth.dtb := dtb octopus_851_wav700_eth
  IMAGE/851_eth_fullimage.img := fullimage 16 squashfs 851_eth.dtb
  IMAGES += kernel.bin \
         851_eth.dtb
  FULLIMAGES := 851_eth_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(PM_PACKAGES)\
		     $(UGW_DIAG_PACKAGES)
endef
TARGET_DEVICES += PRPL_MB_URX_MINIFS

define Device/PRPL_MB_URX
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM CBSP B-Step Model for prplos
  IMAGE/overlay.dtbo := dtbo overlay_pon
  IMAGE/641_wav700_eth.dtb := dtb octopus_641_wav700_eth
  IMAGE/851_wav700_eth.dtb := dtb octopus_851_wav700_eth
  $(if $(CONFIG_INTEL_X86_SECBOOT),\
  $(call Device/SWUPDATE_INIT,641_wav700,urx641,641_wav700_eth.dtb,octopus-urx641-sec-overlay-fit-p34x-phy-emmc-prpl),\
  $(call Device/SWUPDATE_INIT,641_wav700,urx641,641_wav700_eth.dtb,octopus-urx641-overlay-fit-p34x-phy-emmc-prpl))
  $(if $(CONFIG_INTEL_X86_SECBOOT),\
  $(call Device/SWUPDATE_INIT,851_wav700,urx851,851_wav700_eth.dtb,octopus-urx851-sec-overlay-fit-p34x-phy-emmc-prpl),\
  $(call Device/SWUPDATE_INIT,851_wav700,urx851,851_wav700_eth.dtb,octopus-urx851-overlay-fit-p34x-phy-emmc-prpl))
  IMAGES += kernel.bin \
		overlay.dtbo \
		641_wav700_eth.dtb \
		851_wav700_eth.dtb
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(PM_PACKAGES)\
		     $(UGW_DIAG_PACKAGES)
endef
TARGET_DEVICES += PRPL_MB_URX

define Device/LGM_UGW_SDL
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM UGW SDL Model
  FAKED_ENV := $(FAKEROOT_PROG)
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_851_pon.dtb := dtb octopus_851_pon
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_641_pon.dtb := dtb octopus_641_pon
  IMAGE/octopus_641_10g_lan_pon.dtb := dtb octopus_641_10g_lan_pon
  IMAGE/lgp_b0_emmc_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_851_pon_fullimage.img := fullimage 16 squashfs octopus_851_pon.dtb
  IMAGE/octopus_641_aic_10g_eth.dtb := dtb octopus_641_aic_10g_eth
  IMAGE/octopus_641_aic_gsw140.dtb := dtb octopus_641_aic_gsw140
  IMAGE/octopus_641_aic_moca.dtb := dtb octopus_641_aic_moca
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_641_pon_fullimage.img := fullimage 16 squashfs octopus_641_pon.dtb
  IMAGE/octopus_641_10g_lan_pon_fullimage.img := fullimage 16 squashfs octopus_641_10g_lan_pon.dtb
  IMAGES += kernel.bin \
        lgp_b0.dtb lgp_b0_pon.dtb octopus_851.dtb octopus_641.dtb octopus_851_pon.dtb octopus_641_pon.dtb \
	octopus_641_aic_10g_eth.dtb \
	octopus_641_aic_gsw140.dtb \
	octopus_641_aic_moca.dtb
  FULLIMAGES := lgp_b0_emmc_fullimage.img lgp_b0_pon_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img \
		octopus_851_pon_fullimage.img octopus_641_pon_fullimage.img octopus_641_10g_lan_pon_fullimage.img

  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES_SEC) \
		     $(DSL_CPE_GFAST_PACKAGES_PRX) $(DSL_CPE_GFAST_PACKAGES_RELEASE) \
		     $(UGW_DIAG_DSL_PACKAGES) $(PM_PACKAGES)\
		     $(WAV600_UGW_PACKAGES_UCI) $(WAV600_PACKAGES_UCI)
endef
TARGET_DEVICES += LGM_UGW_SDL

define Device/LGM_UGW_SDL_DEBUG
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := LGM UGW SDL DEBUG Model
  FAKED_ENV := $(FAKEROOT_PROG)
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_851_pon.dtb := dtb octopus_851_pon
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_641_pon.dtb := dtb octopus_641_pon
  IMAGE/octopus_641_10g_lan_pon.dtb := dtb octopus_641_10g_lan_pon
  IMAGE/lgp_b0_emmc_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_851_pon_fullimage.img := fullimage 16 squashfs octopus_851_pon.dtb
  IMAGE/octopus_641_aic_10g_eth.dtb := dtb octopus_641_aic_10g_eth
  IMAGE/octopus_641_aic_gsw140.dtb := dtb octopus_641_aic_gsw140
  IMAGE/octopus_641_aic_moca.dtb := dtb octopus_641_aic_moca
  IMAGE/octopus_641_pon_fullimage.img := fullimage 16 squashfs octopus_641_pon.dtb
  IMAGE/octopus_641_10g_lan_pon_fullimage.img := fullimage 16 squashfs octopus_641_10g_lan_pon.dtb
  IMAGES += kernel.bin \
        lgp_b0.dtb lgp_b0_pon.dtb octopus_851.dtb octopus_851_pon.dtb octopus_641.dtb octopus_641_pon.dtb \
	octopus_641_aic_10g_eth.dtb \
	octopus_641_aic_gsw140.dtb \
	octopus_641_aic_moca.dtb
  FULLIMAGES := lgp_b0_emmc_fullimage.img lgp_b0_pon_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img \
		octopus_851_pon_fullimage.img octopus_641_pon_fullimage.img octopus_641_10g_lan_pon_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES_SEC)\
		     $(DSL_CPE_GFAST_PACKAGES_PRX) $(DSL_CPE_GFAST_PACKAGES_DEBUG)\
		     $(PM_DEBUG_PACKAGES) $(PM_PACKAGES)\
		     $(WAV600_UGW_PACKAGES_UCI_DEBUG) $(WAV600_PACKAGES_UCI_DEBUG) \
		     $(UGW_DIAG_DSL_PACKAGES)
endef
TARGET_DEVICES += LGM_UGW_SDL_DEBUG


define Device/URX851_UGW_DEBUG
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := URX851 UGW DEBUG Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fixedlink.dtb := dtb lgp_b0_fixedlink
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_641_pon.dtb := dtb octopus_641_pon
  IMAGE/octopus_641_10g_lan_pon.dtb := dtb octopus_641_10g_lan_pon
  IMAGE/octopus_641_wav700_eth.dtb := dtb octopus_641_wav700_eth
  IMAGE/octopus_641_wav700_pon.dtb := dtb octopus_641_wav700_pon
  IMAGE/octopus_641_docsis.dtb := dtb octopus_641_docsis
  IMAGE/octopus_851_wan_phy.dtb := dtb octopus_851_wan_phy
  IMAGE/octopus_851_pon.dtb := dtb octopus_851_pon
  IMAGE/octopus_851_docsis.dtb := dtb octopus_851_docsis
  IMAGE/octopus_851_pm.dtb := dtb octopus_851_pm
  IMAGE/octopus_851_fixedlink.dtb := dtb octopus_851_fixedlink
  IMAGE/octopus_851_wav700_eth.dtb := dtb octopus_851_wav700_eth
  IMAGE/octopus_851_wav700_eth_pm.dtb := dtb octopus_851_wav700_eth_pm
  IMAGE/octopus_851_wav700_pon.dtb := dtb octopus_851_wav700_pon
  IMAGE/octopus_851_wav700_pon_pm.dtb := dtb octopus_851_wav700_pon_pm
  IMAGE/octopus_851_wav700_docsis.dtb := dtb octopus_851_wav700_docsis
  IMAGE/octopus_641_aic_10g_eth.dtb := dtb octopus_641_aic_10g_eth
  IMAGE/octopus_641_aic_gsw140.dtb := dtb octopus_641_aic_gsw140
  IMAGE/octopus_641_aic_moca.dtb := dtb octopus_641_aic_moca
  IMAGE/octopus_641_pm.dtb := dtb octopus_641_pm
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/lgp_b0_docsis.dtb := dtb lgp_b0_docsis
  IMAGE/lgp_b0_wav700_docsis.dtb := dtb lgp_b0_wav700_docsis
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/lgm_c0_1GB_DDR_mxl86249.dtb := dtb octopus_640_1GB_DDR_mxl86249
  IMAGE/lgm_c0_1GB_DDR_10g_lan.dtb := dtb octopus_640_1GB_DDR_10g_lan
  IMAGE/lgm_c0_10g_lan_pon.dtb := dtb octopus_640_10g_lan_pon
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_851_wan_phy_fullimage.img := fullimage 16 squashfs octopus_851_wan_phy.dtb
  IMAGE/octopus_851_pon_fullimage.img := fullimage 16 squashfs octopus_851_pon.dtb
  IMAGE/octopus_851_docsis_fullimage.img := fullimage 16 squashfs octopus_851_docsis.dtb
  IMAGE/octopus_641_pon_fullimage.img := fullimage 16 squashfs octopus_641_pon.dtb
  IMAGE/octopus_641_10g_lan_pon_fullimage.img := fullimage 16 squashfs octopus_641_10g_lan_pon.dtb
  IMAGE/octopus_641_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_641_wav700_eth.dtb
  IMAGE/octopus_641_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_641_wav700_pon.dtb
  IMAGE/octopus_641_pm_fullimage.img := fullimage 16 squashfs octopus_641_pm.dtb
  IMAGE/octopus_851_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth.dtb
  IMAGE/octopus_851_wav700_eth_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth_pm.dtb
  IMAGE/octopus_851_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon.dtb
  IMAGE/octopus_851_wav700_pon_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon_pm.dtb
  IMAGE/octopus_851_wav700_docsis_fullimage.img := fullimage 16 squashfs octopus_851_wav700_docsis.dtb
  IMAGE/octopus_851_pm_fullimage.img := fullimage 16 squashfs octopus_851_pm.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/lgm_c0_1GB_DDR_mxl86249_fullimage.img := fullimage 16 squashfs lgm_c0_1GB_DDR_mxl86249.dtb
  IMAGE/lgm_c0_1GB_DDR_10g_lan_fullimage.img := fullimage 16 squashfs lgm_c0_1GB_DDR_10g_lan.dtb
  IMAGE/lgm_c0_10g_lan_pon_fullimage.img := fullimage 16 squashfs lgm_c0_10g_lan_pon.dtb
  IMAGES += kernel.bin lgp_b0.dtb lgp_b0_pon.dtb octopus_851.dtb octopus_641.dtb octopus_641_pon.dtb octopus_641_wav700_eth.dtb octopus_641_wav700_pon.dtb octopus_851_wan_phy.dtb octopus_851_fixedlink.dtb octopus_851_wav700_eth.dtb octopus_851_wav700_pon.dtb lgp_b0_fixedlink.dtb \
		lgp_b0_docsis.dtb \
		lgp_b0_wav700_docsis.dtb \
		octopus_851_docsis.dtb \
		octopus_851_wav700_docsis.dtb \
		octopus_851_pm.dtb \
		octopus_641_aic_10g_eth.dtb \
		octopus_641_aic_gsw140.dtb \
		octopus_641_aic_moca.dtb \
		octopus_641_pm.dtb \
		octopus_641_docsis.dtb \
		octopus_851_wav700_eth_pm.dtb \
		octopus_851_wav700_pon_pm.dtb \
		octopus_851_pon.dtb \
		lgm_c0_1GB_DDR_mxl86249.dtb \
		lgm_c0_1GB_DDR_10g_lan.dtb \
		lgm_c0_10g_lan_pon.dtb
  FULLIMAGES := lgp_b0_fullimage.img lgp_b0_pon_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img \
		octopus_851_wan_phy_fullimage.img octopus_851_pon_fullimage.img octopus_641_pon_fullimage.img octopus_851_wav700_eth_fullimage.img octopus_851_wav700_pon_fullimage.img octopus_641_10g_lan_pon_fullimage.img octopus_641_wav700_eth_fullimage.img octopus_641_wav700_pon_fullimage.img \
		octopus_851_docsis_fullimage.img \
		octopus_641_pm_fullimage.img \
		octopus_851_pm_fullimage.img \
		octopus_851_wav700_eth_pm_fullimage.img \
		octopus_851_wav700_pon_pm_fullimage.img \
		octopus_851_wav700_docsis_fullimage.img \
		lgm_c0_1GB_DDR_mxl86249_fullimage.img \
		lgm_c0_1GB_DDR_10g_lan_fullimage.img \
		lgm_c0_10g_lan_pon_fullimage.img

  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES) \
		      $(DSL_CPE_GFAST_PACKAGES_PRX) $(DSL_CPE_GFAST_PACKAGES_DEBUG) \
		      $(PM_DEBUG_PACKAGES) $(PM_PACKAGES)\
		      $(WAV600_UGW_PACKAGES_UCI_DEBUG) $(WAV600_PACKAGES_UCI_DEBUG) \
		      $(UGW_DIAG_DSL_PACKAGES)
endef
TARGET_DEVICES += URX851_UGW_DEBUG

define Device/LGM_UGW_WLANOSP_DEBUG
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := URX851 UGW DEBUG Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fixedlink.dtb := dtb lgp_b0_fixedlink
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_641_pon.dtb := dtb octopus_641_pon
  IMAGE/octopus_641_10g_lan_pon.dtb := dtb octopus_641_10g_lan_pon
  IMAGE/octopus_641_wav700_eth.dtb := dtb octopus_641_wav700_eth
  IMAGE/octopus_641_wav700_pon.dtb := dtb octopus_641_wav700_pon
  IMAGE/octopus_641_docsis.dtb := dtb octopus_641_docsis
  IMAGE/octopus_851_wan_phy.dtb := dtb octopus_851_wan_phy
  IMAGE/octopus_851_pon.dtb := dtb octopus_851_pon
  IMAGE/octopus_851_docsis.dtb := dtb octopus_851_docsis
  IMAGE/octopus_851_pm.dtb := dtb octopus_851_pm
  IMAGE/octopus_851_fixedlink.dtb := dtb octopus_851_fixedlink
  IMAGE/octopus_851_wav700_eth.dtb := dtb octopus_851_wav700_eth
  IMAGE/octopus_851_wav700_eth_pm.dtb := dtb octopus_851_wav700_eth_pm
  IMAGE/octopus_851_wav700_pon.dtb := dtb octopus_851_wav700_pon
  IMAGE/octopus_851_wav700_pon_pm.dtb := dtb octopus_851_wav700_pon_pm
  IMAGE/octopus_851_wav700_docsis.dtb := dtb octopus_851_wav700_docsis
  IMAGE/octopus_641_aic_10g_eth.dtb := dtb octopus_641_aic_10g_eth
  IMAGE/octopus_641_aic_gsw140.dtb := dtb octopus_641_aic_gsw140
  IMAGE/octopus_641_aic_moca.dtb := dtb octopus_641_aic_moca
  IMAGE/octopus_641_pm.dtb := dtb octopus_641_pm
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/lgp_b0_docsis.dtb := dtb lgp_b0_docsis
  IMAGE/lgp_b0_wav700_docsis.dtb := dtb lgp_b0_wav700_docsis
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/lgm_c0_1GB_DDR_mxl86249.dtb := dtb octopus_640_1GB_DDR_mxl86249
  IMAGE/lgm_c0_1GB_DDR_10g_lan.dtb := dtb octopus_640_1GB_DDR_10g_lan
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_851_wan_phy_fullimage.img := fullimage 16 squashfs octopus_851_wan_phy.dtb
  IMAGE/octopus_851_pon_fullimage.img := fullimage 16 squashfs octopus_851_pon.dtb
  IMAGE/octopus_851_docsis_fullimage.img := fullimage 16 squashfs octopus_851_docsis.dtb
  IMAGE/octopus_641_pon_fullimage.img := fullimage 16 squashfs octopus_641_pon.dtb
  IMAGE/octopus_641_10g_lan_pon_fullimage.img := fullimage 16 squashfs octopus_641_10g_lan_pon.dtb
  IMAGE/octopus_641_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_641_wav700_eth.dtb
  IMAGE/octopus_641_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_641_wav700_pon.dtb
  IMAGE/octopus_641_pm_fullimage.img := fullimage 16 squashfs octopus_641_pm.dtb
  IMAGE/octopus_851_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth.dtb
  IMAGE/octopus_851_wav700_eth_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth_pm.dtb
  IMAGE/octopus_851_wav700_pon_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon.dtb
  IMAGE/octopus_851_wav700_pon_pm_fullimage.img := fullimage 16 squashfs octopus_851_wav700_pon_pm.dtb
  IMAGE/octopus_851_wav700_docsis_fullimage.img := fullimage 16 squashfs octopus_851_wav700_docsis.dtb
  IMAGE/octopus_851_pm_fullimage.img := fullimage 16 squashfs octopus_851_pm.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/lgm_c0_1GB_DDR_mxl86249_fullimage.img := fullimage 16 squashfs lgm_c0_1GB_DDR_mxl86249.dtb
  IMAGE/lgm_c0_1GB_DDR_10g_lan_fullimage.img := fullimage 16 squashfs lgm_c0_1GB_DDR_10g_lan.dtb
  IMAGES += kernel.bin lgp_b0.dtb lgp_b0_pon.dtb octopus_851.dtb octopus_641.dtb octopus_641_pon.dtb octopus_641_wav700_eth.dtb octopus_641_wav700_pon.dtb octopus_851_wan_phy.dtb octopus_851_fixedlink.dtb octopus_851_wav700_eth.dtb octopus_851_wav700_pon.dtb lgp_b0_fixedlink.dtb \
		lgp_b0_docsis.dtb \
		lgp_b0_wav700_docsis.dtb \
		octopus_851_docsis.dtb \
		octopus_851_wav700_docsis.dtb \
		octopus_851_pm.dtb \
		octopus_641_aic_10g_eth.dtb \
		octopus_641_aic_gsw140.dtb \
		octopus_641_aic_moca.dtb \
		octopus_641_pm.dtb \
		octopus_641_docsis.dtb \
		octopus_851_wav700_eth_pm.dtb \
		octopus_851_wav700_pon_pm.dtb \
		octopus_851_pon.dtb \
		lgm_c0_1GB_DDR_mxl86249.dtb \
		lgm_c0_1GB_DDR_10g_lan.dtb
  FULLIMAGES := lgp_b0_fullimage.img lgp_b0_pon_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img \
		octopus_851_wan_phy_fullimage.img octopus_851_pon_fullimage.img octopus_641_pon_fullimage.img octopus_851_wav700_eth_fullimage.img octopus_851_wav700_pon_fullimage.img octopus_641_10g_lan_pon_fullimage.img octopus_641_wav700_eth_fullimage.img octopus_641_wav700_pon_fullimage.img \
		octopus_851_docsis_fullimage.img \
		octopus_641_pm_fullimage.img \
		octopus_851_pm_fullimage.img \
		octopus_851_wav700_eth_pm_fullimage.img \
		octopus_851_wav700_pon_pm_fullimage.img \
		octopus_851_wav700_docsis_fullimage.img \
		lgm_c0_1GB_DDR_mxl86249_fullimage.img \
		lgm_c0_1GB_DDR_10g_lan_fullimage.img

  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES) \
		      $(DSL_CPE_GFAST_PACKAGES_PRX) $(DSL_CPE_GFAST_PACKAGES_DEBUG) \
		      $(PM_DEBUG_PACKAGES) $(PM_PACKAGES)\
		      $(WAV700_UGW_PACKAGES_UCI_OSP_DEBUG) $(WAV700_PACKAGES_UCI_OSP_DEBUG) \
		      $(UGW_DIAG_DSL_PACKAGES)
endef
TARGET_DEVICES += LGM_UGW_WLANOSP_DEBUG

define Device/URX851_UGW_DEBUG_PD
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := URX851 UGW DEBUG PD Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fixedlink.dtb := dtb lgp_b0_fixedlink
  IMAGE/lgp_b0_no_fan.dtb := dtb lgp_b0_no_fan
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/lgp_wav700_eth.dtb := dtb lgp_wav700_eth
  IMAGE/lgp_wav700_pon.dtb := dtb lgp_wav700_pon
  IMAGE/lgm_evm_b0_ebu_nand.dtb := dtb lgm_evm_b0_ebu_nand
  IMAGE/lgm_evm_b0_3band_ebu_nand.dtb := dtb lgm_evm_b0_3band_ebu_nand
  IMAGE/lgm_evm_b0_qspi_nand.dtb := dtb lgm_evm_b0_qspi_nand
  IMAGE/lgm_evm_b0_slic200_cibb_ebu_nand.dtb := dtb lgm_evm_b0_slic200_cibb_ebu_nand
  IMAGE/lgm_evm_b0_slic200_cibb_qspi_nand.dtb := dtb lgm_evm_b0_slic200_cibb_qspi_nand
  IMAGE/lgm_evm_b0_slic200_cifb_ebu_nand.dtb := dtb lgm_evm_b0_slic200_cifb_ebu_nand
  IMAGE/lgm_evm_b0_slic200_cifb_qspi_nand.dtb := dtb lgm_evm_b0_slic200_cifb_qspi_nand
  IMAGE/lgm_evm_b0_slic200_ifb_ebu_nand.dtb := dtb lgm_evm_b0_slic200_ifb_ebu_nand
  IMAGE/lgm_evm_b0_slic200_ifb_qspi_nand.dtb := dtb lgm_evm_b0_slic200_ifb_qspi_nand
  IMAGE/lgm_evm_b0_slic200_ib_ebu_nand.dtb := dtb lgm_evm_b0_slic200_ib_ebu_nand
  IMAGE/lgm_evm_b0_slic200_ib_qspi_nand.dtb := dtb lgm_evm_b0_slic200_ib_qspi_nand
  IMAGE/lgm_evm_b0_slic200_cib_ebu_nand.dtb := dtb lgm_evm_b0_slic200_cib_ebu_nand
  IMAGE/lgm_evm_b0_slic200_cib_qspi_nand.dtb := dtb lgm_evm_b0_slic200_cib_qspi_nand
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/lgp_wav700_eth_fullimage.img := fullimage 16 squashfs lgp_wav700_eth.dtb
  IMAGE/lgp_wav700_pon_fullimage.img := fullimage 16 squashfs lgp_wav700_pon.dtb
  IMAGE/lgm_evm_b0_ebu_nand_fullimage.img := fullimage 16 squashfs lgm_evm_b0_ebu_nand.dtb
  IMAGES += kernel.bin \
        lgp_b0.dtb \
        lgp_b0_fixedlink.dtb \
        lgp_b0_no_fan.dtb \
        lgp_b0_pon.dtb \
        lgp_wav700_eth.dtb \
        lgp_wav700_pon.dtb \
        lgm_evm_b0_ebu_nand.dtb \
        lgm_evm_b0_3band_ebu_nand.dtb \
        lgm_evm_b0_qspi_nand.dtb \
        lgm_evm_b0_slic200_cibb_ebu_nand.dtb \
        lgm_evm_b0_slic200_cibb_qspi_nand.dtb \
        lgm_evm_b0_slic200_cifb_ebu_nand.dtb \
        lgm_evm_b0_slic200_cifb_qspi_nand.dtb \
        lgm_evm_b0_slic200_ifb_ebu_nand.dtb \
        lgm_evm_b0_slic200_ifb_qspi_nand.dtb \
        lgm_evm_b0_slic200_ib_ebu_nand.dtb \
        lgm_evm_b0_slic200_ib_qspi_nand.dtb \
        lgm_evm_b0_slic200_cib_ebu_nand.dtb \
        lgm_evm_b0_slic200_cib_qspi_nand.dtb
  FULLIMAGES := lgp_b0_fullimage.img lgp_b0_pon_fullimage.img lgm_evm_b0_ebu_nand_fullimage.img \
                lgp_wav700_eth_fullimage.img lgp_wav700_pon_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES)
endef
TARGET_DEVICES += URX851_UGW_DEBUG_PD

define Device/URX851_UGW_DEBUG_FPGA
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := URX851 UGW DEBUG FPGA Model
  IMAGE/lgp_b0.dtb := dtb lgp_b0
  IMAGE/lgp_b0_fixedlink.dtb := dtb lgp_b0_fixedlink
  IMAGE/lgp_wav700_eth.dtb := dtb lgp_wav700_eth
  IMAGE/lgp_wav700_pon.dtb := dtb lgp_wav700_pon
  IMAGE/octopus_851.dtb := dtb octopus_851
  IMAGE/octopus_641.dtb := dtb octopus_641
  IMAGE/octopus_851_wan_phy.dtb := dtb octopus_851_wan_phy
  IMAGE/octopus_851_pon.dtb := dtb octopus_851_pon
  IMAGE/octopus_851_fixedlink.dtb := dtb octopus_851_fixedlink
  IMAGE/octopus_851_wav700_eth.dtb := dtb octopus_851_wav700_eth
  IMAGE/lgp_b0_pon.dtb := dtb lgp_b0_pon
  IMAGE/lgp_b0_fullimage.img := fullimage 16 squashfs lgp_b0.dtb
  IMAGE/octopus_851_fullimage.img := fullimage 16 squashfs octopus_851.dtb
  IMAGE/octopus_641_fullimage.img := fullimage 16 squashfs octopus_641.dtb
  IMAGE/octopus_851_wan_phy_fullimage.img := fullimage 16 squashfs octopus_851_wan_phy.dtb
  IMAGE/octopus_851_pon_fullimage.img := fullimage 16 squashfs octopus_851_pon.dtb
  IMAGE/octopus_851_wav700_eth_fullimage.img := fullimage 16 squashfs octopus_851_wav700_eth.dtb
  IMAGE/lgp_b0_pon_fullimage.img := fullimage 16 squashfs lgp_b0_pon.dtb
  IMAGE/lgp_wav700_eth_fullimage.img := fullimage 16 squashfs lgp_wav700_eth.dtb
  IMAGE/lgp_wav700_pon_fullimage.img := fullimage 16 squashfs lgp_wav700_pon.dtb
  IMAGES += kernel.bin lgp_b0.dtb lgp_b0_pon.dtb octopus_851.dtb octopus_641.dtb octopus_851_wan_phy.dtb octopus_851_fixedlink.dtb lgp_b0_fixedlink.dtb \
                lgp_wav700_eth.dtb \
                lgp_wav700_pon.dtb \
                octopus_851_wav700_eth.dtb \
                octopus_851_pon.dtb
  FULLIMAGES := lgp_b0_fullimage.img lgp_b0_pon_fullimage.img octopus_851_fullimage.img octopus_641_fullimage.img \
                octopus_851_wan_phy_fullimage.img octopus_851_pon_fullimage.img lgp_wav700_pon_fullimage.img \
		 lgp_wav700_eth_fullimage.img octopus_851_wav700_eth_fullimage.img
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  DEVICE_PACKAGES := $(UGW_PACKAGES) $(DSL_CPE_GFAST_PACKAGES_PRX) \
                     $(WAV700_PACKAGES_UCI_DEBUG) $(WAV700_UGW_PACKAGES_UCI_DEBUG) $(DSL_CPE_GFAST_PACKAGES_DEBUG) \
                     $(PM_DEBUG_PACKAGES) $(WAV700-FPGA_PACKAGES) $(EXTRA_OPENWRT_PACKAGES) \
                     $(UGW_DIAG_DSL_PACKAGES)
endef
TARGET_DEVICES += URX851_UGW_DEBUG_FPGA

define Device/URX851_UGW_DEBUG_DXS
  $(Device/LGM_GENERIC)
  DEVICE_TITLE := URX851 UGW DEBUG Model with Voice DXS TID
  IMAGE/lgm_evm_b0_ebu_nand.dtb := dtb lgm_evm_b0_ebu_nand
  IMAGE/lgm_evm_b0_dxs_ebu_nand.dtb := dtb lgm_evm_b0_dxs_ebu_nand
  IMAGE/lgm_evm_b0_dxs_qspi_nand.dtb := dtb lgm_evm_b0_dxs_qspi_nand
  IMAGE/lgm_evm_b0_slic200_cibb_ebu_nand.dtb := dtb lgm_evm_b0_slic200_cibb_ebu_nand
  IMAGE/lgm_evm_b0_slic200_cibb_qspi_nand.dtb := dtb lgm_evm_b0_slic200_cibb_qspi_nand
  IMAGE/lgm_evm_b0_slic200_cifb_ebu_nand.dtb := dtb lgm_evm_b0_slic200_cifb_ebu_nand
  IMAGE/lgm_evm_b0_slic200_cifb_qspi_nand.dtb := dtb lgm_evm_b0_slic200_cifb_qspi_nand
  IMAGE/lgm_evm_b0_slic200_ifb_ebu_nand.dtb := dtb lgm_evm_b0_slic200_ifb_ebu_nand
  IMAGE/lgm_evm_b0_slic200_ifb_qspi_nand.dtb := dtb lgm_evm_b0_slic200_ifb_qspi_nand
  IMAGE/lgm_evm_b0_slic200_ib_ebu_nand.dtb := dtb lgm_evm_b0_slic200_ib_ebu_nand
  IMAGE/lgm_evm_b0_slic200_ib_qspi_nand.dtb := dtb lgm_evm_b0_slic200_ib_qspi_nand
  IMAGE/lgm_evm_b0_slic200_cib_ebu_nand.dtb := dtb lgm_evm_b0_slic200_cib_ebu_nand
  IMAGE/lgm_evm_b0_slic200_cib_qspi_nand.dtb := dtb lgm_evm_b0_slic200_cib_qspi_nand
  IMAGE/lgm_evm_b0_dxs_ebu_nand_fullimage.img := fullimage 16 squashfs lgm_evm_b0_dxs_ebu_nand.dtb
  IMAGE/lgm_evm_b0_dxs_qspi_nand_fullimage.img := fullimage 16 squashfs lgm_evm_b0_dxs_qspi_nand.dtb
  IMAGE/lgm_evm_b0_ebu_nand_fullimage.img := fullimage 16 squashfs lgm_evm_b0_ebu_nand.dtb
  IMAGES += kernel.bin \
        lgm_evm_b0_dxs_ebu_nand.dtb \
        lgm_evm_b0_dxs_qspi_nand.dtb \
        lgm_evm_b0_slic200_cibb_ebu_nand.dtb \
        lgm_evm_b0_slic200_cibb_qspi_nand.dtb \
        lgm_evm_b0_slic200_cifb_ebu_nand.dtb \
        lgm_evm_b0_slic200_cifb_qspi_nand.dtb \
        lgm_evm_b0_slic200_ifb_ebu_nand.dtb \
        lgm_evm_b0_slic200_ifb_qspi_nand.dtb \
        lgm_evm_b0_slic200_ib_ebu_nand.dtb \
        lgm_evm_b0_slic200_ib_qspi_nand.dtb \
        lgm_evm_b0_slic200_cib_ebu_nand.dtb \
        lgm_evm_b0_slic200_cib_qspi_nand.dtb
  ROOTFS := fs.rootfs
  ROOTFS_PREPARE := add-servicelayer-schema
  FULLIMAGES :=  lgm_evm_b0_dxs_ebu_nand_fullimage.img lgm_evm_b0_dxs_qspi_nand_fullimage.img lgm_evm_b0_ebu_nand_fullimage.img
  DEVICE_PACKAGES := $(UGW_PACKAGES) $(VOIP_PACKAGES_DXS_DEBUG)\
					 $(PM_DEBUG_PACKAGES)
endef
TARGET_DEVICES += URX851_UGW_DEBUG_DXS

endif
