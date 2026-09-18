PROJECT := AetherChat
SCHEME  := AetherChat
DEST    := platform=iOS Simulator,name=iPhone 15 Pro

.PHONY: project open build test core-test core-build clean help

help:
	@echo "make core-test   —— 只跑内核测试（Mac / Windows / Linux 都能跑，不需要 Xcode）"
	@echo "make core-build  —— 只编译内核包"
	@echo "make project     —— 用 XcodeGen 生成 .xcodeproj（需要 Mac）"
	@echo "make open        —— 生成并打开 Xcode 工程"
	@echo "make build       —— 编译 iOS app（需要 Mac + Xcode）"

# ---- 内核：跨平台，不需要 Xcode ----
## Windows 上装了 Swift 工具链之后，这两条命令直接可用
core-test:
	swift test --package-path AetherCore

core-build:
	swift build --package-path AetherCore

# ---- 苹果侧 ----
project:
	xcodegen generate

open: project
	open $(PROJECT).xcodeproj

build: project
	xcodebuild -scheme $(SCHEME) -destination '$(DEST)' build

## 在 Mac 上跑内核测试（和 core-test 等价，保留旧名字做兼容）
test: core-test

clean:
	rm -rf $(PROJECT).xcodeproj build DerivedData AetherCore/.build
