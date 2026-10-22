#!/usr/bin/env python3
"""Near-real-time watch of the running game.   tools/live.py [--no-record]

 - follows game.log on the phone: prints the once-a-second `tele:` line (fps, worst frame, draw counts),
   the game's procedure changes, and `spin:` lines;
 - keeps a rolling 60 s screen recording on the phone (tools/live.sh);
 - when something happens it saves the last seconds of video plus the frame ring:
     * the in-game CAPTURE button was tapped,
     * a freeze: during a match the draw count has been identical for 3 s (the simulation stopped),
     * a stutter: a frame over 100 ms during a match;
   into /tmp/live/<time>/ and prints a summary (flicker.py on the video, frame-time histogram).
Ctrl-C to stop."""
import os, re, subprocess, sys, threading, time
EXT = '/sdcard/Android/data/com.pes2017.recomp/files'
HERE = os.path.dirname(os.path.abspath(__file__))
def adb(*a, **k): return subprocess.run(['adb', *a], capture_output=True, text=True, **k).stdout
if '--no-record' not in sys.argv:
    subprocess.run(['adb', 'push', os.path.join(HERE, 'live.sh'), '/sdcard/live.sh'], capture_output=True)
    # [l] keeps pkill from matching the shell that runs it.
    subprocess.run(['adb', 'shell', "pkill -f '[l]ive.sh'; pkill screenrecord; rm -f /sdcard/live_*.mp4"])
    subprocess.run(['adb', 'shell', 'nohup sh /sdcard/live.sh >/dev/null 2>&1 &'])
    print('recording: 4 x 15 s rolling segments on the phone')
state = {'match': False, 'last_save': 0, 'frozen_since': None}
def save(reason):
    if time.time() - state['last_save'] < 25: return
    state['last_save'] = time.time()
    if 'frozen' in reason: adb('shell', 'echo 1 > %s/capture_request' % EXT)   # once per freeze, not once per second
    out = '/tmp/live/' + time.strftime('%H%M%S'); os.makedirs(out, exist_ok=True)
    print('\n*** %s -> %s (waiting 16 s for the current segment to close)' % (reason, out), flush=True)
    def work():
        time.sleep(16)
        names = adb('shell', 'ls -t /sdcard/live_*.mp4').split()[:3]
        for n in names: subprocess.run(['adb', 'pull', n, out], capture_output=True)
        files = sorted(os.listdir(out))
        print('*** saved', files, flush=True)
        if names and os.path.exists(os.path.join(out, os.path.basename(names[0]))):
            r = subprocess.run([sys.executable, os.path.join(HERE, 'flicker.py'), os.path.join(out, os.path.basename(names[0])), out + '/flk'],
                               capture_output=True, text=True)
            print('*** flicker.py:', (r.stdout.strip().splitlines() or ['no output'])[-1], flush=True)
    if 'frozen' in reason:
        def profile():
            # Root: where each guest thread burns its CPU (simpleperf), and the job scheduler's state.
            pid = adb('shell', 'pidof com.pes2017.recomp:game').strip()
            open('/tmp/live_rec.sh', 'w').write('cd /data/local/tmp\nsimpleperf record -p %s -g --duration 4 -o fz.data >/dev/null 2>&1\n'
                                                'simpleperf report -i fz.data --sort comm,symbol --children 2>/dev/null | head -140\n' % pid)
            subprocess.run(['adb', 'push', '/tmp/live_rec.sh', '/data/local/tmp/live_rec.sh'], capture_output=True)
            open(out + '/profile.txt', 'w').write(adb('shell', 'su -c "sh /data/local/tmp/live_rec.sh"'))
            adb('shell', 'echo "2014F7C0 240" > %s/dump_guest' % EXT); time.sleep(3)
            subprocess.run(['adb', 'pull', EXT + '/guest_dump.bin', out + '/scheduler_2014F7C0.bin'], capture_output=True)
            print('*** freeze profile saved in', out + '/profile.txt', flush=True)
        threading.Thread(target=profile, daemon=True).start()
    threading.Thread(target=work, daemon=True).start()
def snapshots():
    # The job scheduler object (2014F7C0) every few seconds: a freeze can be diffed against the healthy states before it.
    os.makedirs('/tmp/live/snap', exist_ok=True); n = 0
    while True:
        time.sleep(3)
        if state['frozen_since'] or not state['match']: continue
        adb('shell', 'echo "2014F7C0 240" > %s/dump_guest' % EXT); time.sleep(1.2)
        subprocess.run(['adb', 'pull', EXT + '/guest_dump.bin', '/tmp/live/snap/s%02d.bin' % (n % 8)], capture_output=True); n += 1
threading.Thread(target=snapshots, daemon=True).start()
p = subprocess.Popen(['adb', 'exec-out', 'tail -n 0 -F %s/game.log' % EXT], stdout=subprocess.PIPE, text=True, errors='replace')
print('following game.log (tele: lines once a second)')
try:
    for line in p.stdout:
        if 'procedure:' in line:
            name = re.search(r'procedure: (\S+)', line).group(1)
            state['match'] = name.startswith('Match/')
            print('  proc', name, flush=True)
        elif 'tele:' in line:
            m = re.search(r'fps (\d+) worst (\d+) draws (\d+)-(\d+) same (\d+) swap (\d+)', line)
            if not m: continue
            fps, worst, lo, hi, same, swap = map(int, m.groups())
            flag = ''
            if state['match'] and same >= 300 and fps > 20: flag = ' <-- FROZEN SCENE'
            elif state['match'] and worst > 100: flag = ' <-- stutter'
            print('  %3d fps  worst %3d ms  draws %d-%d  same %d%s' % (fps, worst, lo, hi, same, flag), flush=True)
            if 'FROZEN' in flag: state['frozen_since'] = state['frozen_since'] or time.time()
            else: state['frozen_since'] = None
            if 'FROZEN' in flag:
                save('frozen scene')
            elif 'stutter' in flag: save('stutter %d ms' % worst)
        elif 'capture: requested' in line: save('CAPTURE button')
        elif 'spin:' in line: print(' ', line.strip()[:200], flush=True)
except KeyboardInterrupt:
    pass
finally:
    p.terminate()
    if '--no-record' not in sys.argv: subprocess.run(['adb', 'shell', "pkill -f '[l]ive.sh'; pkill screenrecord"])
