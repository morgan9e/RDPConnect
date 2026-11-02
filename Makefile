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

# Windows: the same Qt 6 front-end (Qt/main.cpp), built either natively in an MSYS2 UCRT64
# shell (uname -s is UCRT64_NT-...) or cross-compiled in the Qt/Containerfile image
# (`make windows` on Linux).
WIN_RES   := rdpconnect-res.o
WIN_IMAGE := rdpconnect-windows-build
DIST      := dist/$(APP_NAME)
QT_PLUGINS = $(MINGW_PREFIX)/share/qt6/plugins

ifneq ($(findstring _NT,$(UNAME)),)
WINDOWS      := 1
MINGW_PREFIX ?= /ucrt64
CXX          := g++
WINDRES      := windres
OBJDUMP      := objdump
WIN_APPDIR   ?= $(shell cygpath -u "$$LOCALAPPDATA")/Programs/$(APP_NAME)
WIN_SHORTCUT := $(shell cygpath -u "$$APPDATA")/Microsoft/Windows/Start Menu/Programs/$(APP_NAME).lnk
else ifeq ($(TARGET_OS),windows)
WINDOWS      := 1
CROSS        := x86_64-w64-mingw32ucrt-
MINGW_PREFIX ?= /sysroot/ucrt64
CXX          := $(CROSS)g++
WINDRES      := $(CROSS)windres
OBJDUMP      := $(CROSS)objdump
endif

ifdef WINDOWS
QT_BIN       := rdpconnect.exe
QT_PKGS      := Qt6Widgets
FREERDP_BINS := $(foreach n,sdl-freerdp sdl-freerdp3 wfreerdp,$(wildcard $(MINGW_PREFIX)/bin/$(n).exe))
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
else ifdef WINDOWS
all: qt
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

ifdef WINDOWS
$(QT_BIN): $(QT_DIR)/main.cpp $(WIN_RES)
	$(CXX) -std=c++17 -O2 -mwindows $(CXXFLAGS) $(shell pkg-config --cflags $(QT_PKGS)) \
		-o $(QT_BIN) $(QT_DIR)/main.cpp $(WIN_RES) $(LDFLAGS) $(shell pkg-config --libs $(QT_PKGS)) -ladvapi32

$(WIN_RES): $(QT_DIR)/rdpconnect.rc $(QT_DIR)/icon.ico
	$(WINDRES) -I $(QT_DIR) $< -O coff -o $@
else
$(QT_BIN): $(QT_DIR)/main.cpp
	$(CXX) -std=c++17 -O2 -fPIC $(CXXFLAGS) $(shell pkg-config --cflags $(QT_PKGS)) \
		-o $(QT_BIN) $(QT_DIR)/main.cpp $(LDFLAGS) $(shell pkg-config --libs $(QT_PKGS))
endif

# Self-contained Windows folder: exe + DLLs + FreeRDP client, with the Qt platform and style
# plugins in bin/platforms and bin/styles (Qt always looks next to the exe).
dist: $(QT_BIN)
	$(if $(FREERDP_BINS),,@echo "warning: no FreeRDP client in $(MINGW_PREFIX)/bin (pacman -S mingw-w64-ucrt-x86_64-freerdp)")
	rm -rf $(DIST)
	mkdir -p $(DIST)/bin/platforms $(DIST)/bin/styles
	cp $(QT_BIN) $(FREERDP_BINS) $(DIST)/bin/
	cp $(QT_PLUGINS)/platforms/qwindows.dll $(DIST)/bin/platforms/
	cp $(QT_PLUGINS)/styles/qmodernwindowsstyle.dll $(DIST)/bin/styles/
	$(QT_DIR)/bundle-dlls.sh $(OBJDUMP) $(MINGW_PREFIX)/bin $(DIST)/bin \
		$(DIST)/bin/*.exe $(DIST)/bin/*/*.dll
	@echo "Bundled $(DIST)"

ifdef WINDOWS
windows: dist
else
windows:
	podman build -t $(WIN_IMAGE) $(QT_DIR)
	podman run --rm -v "$(CURDIR)":/src:Z $(WIN_IMAGE) make dist

windows-run:
	$(DIST)/bin/rdpconnect.exe
endif

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

else ifdef WINDOWS

install: dist
	rm -rf "$(WIN_APPDIR)"
	mkdir -p "$(WIN_APPDIR)"
	cp -r $(DIST)/. "$(WIN_APPDIR)/"
	powershell.exe -NoProfile -Command '$$s = (New-Object -ComObject WScript.Shell).CreateShortcut("$(shell cygpath -w "$(WIN_SHORTCUT)")"); $$s.TargetPath = "$(shell cygpath -w "$(WIN_APPDIR)/bin/$(QT_BIN)")"; $$s.Save()'
	@echo "Installed $(WIN_APPDIR)"

uninstall:
	rm -rf "$(WIN_APPDIR)"
	rm -f "$(WIN_SHORTCUT)"

run: $(QT_BIN)
	./$(QT_BIN)

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
	rm -rf $(APP) $(APP_NAME) $(BIN) $(QT_BIN) $(WIN_RES) dist

.PHONY: all build macos linux windows windows-run vala qt swift package dist install uninstall run clean
