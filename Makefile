.PHONY: build install uninstall clean

ARCH ?= $(shell uname -m)
BUILD_DIR := .build
DYLIB := $(BUILD_DIR)/OrbitBar.dylib

build:
	@mkdir -p $(BUILD_DIR)
	clang -arch $(ARCH) -mmacosx-version-min=14.0 -O2 -c Sources/orbitbar_init.c -o $(BUILD_DIR)/orbitbar_init.o
	swiftc -emit-library -O \
		-target $(ARCH)-apple-macosx14.0 \
		-Xlinker -install_name -Xlinker @rpath/OrbitBar.dylib \
		Sources/OrbitBar.swift $(BUILD_DIR)/orbitbar_init.o \
		-o $(DYLIB)
	@rm -f $(BUILD_DIR)/orbitbar_init.o
	@ls -lh $(DYLIB)

install:
	@chmod +x Scripts/install.sh Scripts/uninstall.sh Scripts/patch_macho.py
	@./Scripts/install.sh

uninstall:
	@chmod +x Scripts/uninstall.sh
	@./Scripts/uninstall.sh

clean:
	@rm -rf $(BUILD_DIR)
