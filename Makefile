UNAME     := $(shell uname -s)

APP_NAME  := RDPConnect
VERSION   := 1.0
SWIFT_DIR := Swift
VALA_DIR  := Vala

BIN        := rdpconnect
PREFIX    ?= $(HOME)/.local
BINDIR    ?= $(PREFIX)/bin
DATADIR   ?= $(PREFIX)/share
ICON_SIZE := 256x256
LINUX_ID  := com.example.RDPConnect
DESKTOP   := $(VALA_DIR)/$(LINUX_ID).desktop
ICON      := $(VALA_DIR)/icon.png
VALA_PKGS := --pkg gtk4 --pkg libadwaita-1 --pkg libsecret-1 --pkg json-glib-1.0 --pkg posix
QT_DIR    := Qt
QT_BIN    := rdpconnect-qt
QT_PKGS   := Qt6Widgets libsecret-1

ifeq ($(UNAME),Darwin)
VALAFLAGS += $(if $(wildcard /opt/homebrew/share/vala/vapi),--vapidir /opt/homebrew/share/vala/vapi,)
endif

APP        := $(APP_NAME).app
APPDIR     ?= $(HOME)/Applications

ifeq ($(UNAME),Darwin)
MAC_BUNDLE_ID := com.example.RDPConnect

# Sign with an Apple Development identity (free Apple ID works): its Team ID keeps keychain
# and Accessibility grants stable across rebuilds. Falls back to ad-hoc signing.
APPLE_DEV_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | awk '/"Apple Development/ {print $$2; exit}')
CODESIGN_ID ?= $(or $(APPLE_DEV_ID),-)

DEPLOY ?= $(shell sw_vers -productVersion | cut -d. -f1).0
TARGET  = $(shell uname -m)-apple-macos$(DEPLOY)
endif

ifeq ($(UNAME),Darwin)
all: swift
else
all: vala
endif

build: all

macos: swift
linux: vala

vala: $(BIN)

$(BIN): $(VALA_DIR)/main.vala
	valac $(VALAFLAGS) $(VALA_PKGS) -X -O2 -X -w -o $(BIN) $(VALA_DIR)/main.vala

qt: $(QT_BIN)

$(QT_BIN): $(QT_DIR)/main.cpp
	$(CXX) -std=c++17 -O2 -fPIC $(CXXFLAGS) $(shell pkg-config --cflags $(QT_PKGS)) \
		-o $(QT_BIN) $(QT_DIR)/main.cpp $(LDFLAGS) $(shell pkg-config --libs $(QT_PKGS))

swift: $(APP)

package: $(APP)

$(APP): $(SWIFT_DIR)/main.swift $(SWIFT_DIR)/Info.plist $(SWIFT_DIR)/AppIcon.icns $(SWIFT_DIR)/menuzap.m
	swiftc -O -parse-as-library -target $(TARGET) -o $(APP_NAME) $(SWIFT_DIR)/main.swift
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	mv $(APP_NAME) $(APP)/Contents/MacOS/$(APP_NAME)
	cp $(SWIFT_DIR)/Info.plist $(APP)/Contents/Info.plist
	cp $(SWIFT_DIR)/AppIcon.icns $(APP)/Contents/Resources/AppIcon.icns
	clang -O2 -dynamiclib -target $(TARGET) -framework Cocoa $(SWIFT_DIR)/menuzap.m -o $(APP)/Contents/Resources/menuzap.dylib
	codesign --force --sign "$(CODESIGN_ID)" $(APP)/Contents/Resources/menuzap.dylib
	codesign --force --identifier $(MAC_BUNDLE_ID) --sign "$(CODESIGN_ID)" $(APP)

ifeq ($(UNAME),Darwin)

install: $(APP)
	mkdir -p "$(APPDIR)"
	rm -rf "$(APPDIR)/$(APP)"
	cp -R $(APP) "$(APPDIR)/$(APP)"
	@echo "Installed $(APPDIR)/$(APP)"

uninstall:
	rm -rf "$(APPDIR)/$(APP)"

run: $(APP)
	open $(APP)

else

install: $(BIN)
	install -Dm755 $(BIN) "$(BINDIR)/$(BIN)"
	install -Dm644 $(DESKTOP) "$(DATADIR)/applications/$(LINUX_ID).desktop"
	install -Dm644 $(ICON) "$(DATADIR)/icons/hicolor/$(ICON_SIZE)/apps/$(BIN).png"
	update-desktop-database "$(DATADIR)/applications" 2>/dev/null || true
	gtk-update-icon-cache -f -t "$(DATADIR)/icons/hicolor" 2>/dev/null || true

uninstall:
	rm -f "$(BINDIR)/$(BIN)"
	rm -f "$(DATADIR)/applications/$(LINUX_ID).desktop"
	rm -f "$(DATADIR)/icons/hicolor/$(ICON_SIZE)/apps/$(BIN).png"
	update-desktop-database "$(DATADIR)/applications" 2>/dev/null || true

run: $(BIN)
	./$(BIN)

endif

clean:
	rm -rf $(APP) $(APP_NAME) $(BIN) $(QT_BIN)

.PHONY: all build macos linux vala qt swift package install uninstall run clean
