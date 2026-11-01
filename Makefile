.PHONY: all app run preview dist release clean

VERSION ?=

all: app

app:
	./build.sh

run: app
	open build/PointTell.app

preview:
	./scripts/render-preview.sh

# 只打包，不发版：产物在 dist/
dist:
	./build.sh
	./scripts/package.sh

# 发版：改版本号 → 构建 → 打包 → commit → tag → push
# 用法：make release VERSION=0.2.0
release:
	@test -n "$(VERSION)" || (echo "用法：make release VERSION=0.2.0" && exit 1)
	./scripts/release.sh $(VERSION)

clean:
	rm -rf build dist
