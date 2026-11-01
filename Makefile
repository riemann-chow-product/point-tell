.PHONY: all app run preview clean

all: app

app:
	./build.sh

run: app
	open build/PointTell.app

preview:
	./scripts/render-preview.sh

clean:
	rm -rf build
