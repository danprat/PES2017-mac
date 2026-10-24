# Build, install and run on the connected phone (adb). See tools/deploy.sh.
#   make run             rebuild the native library, install, launch, show errors
#   make launch          just (re)start the installed app
#   make log             follow the game's log   (make log PATTERN=regex to filter)
#   make errors          the current run's warnings and errors
#   make stop            stop the app
#   make seed            copy the phone's shader cache into the APK seed
#   make test-macro      launch and replay the `play` macro into a match
#   make WATCH=40 run    seconds to watch the log after launch (default 25)
PKG   := com.pes2017.recomp
WATCH ?= 25
LOG   ?= logs-device.txt

.PHONY: run launch stop log errors seed test-macro

run:
	tools/deploy.sh $(WATCH) $(LOG)

launch:
	adb shell am force-stop $(PKG)
	adb shell am start -n $(PKG)/com.pes2017.recomp.MainActivity

stop:
	adb shell am force-stop $(PKG)

log:
	tools/logtail.sh follow $(PATTERN)

errors:
	tools/logtail.sh errors

seed:
	tools/update_shader_seed.sh

test-macro: launch
	@for i in $$(seq 40); do sleep 1; adb shell "grep -q PreStartup /sdcard/Android/data/$(PKG)/files/game.log" 2>/dev/null && break; done; sleep 3
	adb shell am broadcast -a com.pes2017.recomp.MACRO -p $(PKG) --es cmd play --es name play
