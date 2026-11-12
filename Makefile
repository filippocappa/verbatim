# make           build (Debug)
# make run       build and launch the Debug app
# make install   Release build into /Applications, then relaunch
APP_NAME := Verbatim
DERIVED := build

.PHONY: project build run install clean

project:
	xcodegen generate --quiet

build: project
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Debug \
		-derivedDataPath $(DERIVED) -quiet build

run: build
	-pkill -x $(APP_NAME); sleep 0.3
	open $(DERIVED)/Build/Products/Debug/$(APP_NAME).app

install: project
	xcodebuild -project $(APP_NAME).xcodeproj -scheme $(APP_NAME) -configuration Release \
		-derivedDataPath $(DERIVED) -quiet build
	-pkill -x $(APP_NAME); sleep 0.3
	rm -rf /Applications/$(APP_NAME).app
	cp -R $(DERIVED)/Build/Products/Release/$(APP_NAME).app /Applications/
	open /Applications/$(APP_NAME).app

clean:
	rm -rf $(DERIVED)
