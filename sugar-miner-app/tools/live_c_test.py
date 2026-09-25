#!/usr/bin/env python3
"""
Live test of the EXACT C library that ships inside the Android app.

Uses yp_scan() (the batch entry point the Flutter app calls over FFI) to mine
against the real PooLab Stratum port, and shows the pool's answer.

Run:  python3 tools/live_c_test.py [minutes]
"""
import ctypes, hashlib, json, os, select, socket, struct, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(HERE, '..', 'native', 'yespower', 'libyespower.so')
POOL_HOST, POOL_PORT = 'stratum.poolab.org', 8451
ADDR = open(os.path.join(HERE, '..', 'tools', 'test_address.txt')).read().strip() \
    if os.path.exists(os.path.join(HERE, '..', 'tools', 'test_address.txt')) else None

# ---------------------------------------------------------------- cone math
DIFF1 = int('00000000FFFF0000000000000000000000000000000000000000000000000000', 16)  # bitcoin diff1 (~2^224)
POOL_DIFF1 = DIFF1 * 65536                        # NOMP's 2^16 scale for yespowerSUGAR
ACCEPT = 0.99

def share_target(diff):
    """largest hash value the pool accepts at this difficulty"""
    d = max(1, round(diff * ACCEPT * 1_000_000))
    return (POOL_DIFF1 * 1_000_000) // d

def value_of(digest_le):
    return int.from_bytes(digest_le, 'little')

def swap_words4(hexstr):
    b = bytes.fromhex(hexstr)
    out = bytearray()
    for i in range(0, len(b), 4):
        out += b[i:i + 4][::-1]
    return out.hex()

def sha256d(b):
    return hashlib.sha256(hashlib.sha256(b).digest()).digest()

# ---------------------------------------------------------------- C library
lib = ctypes.CDLL(LIB)
lib.yp_hash.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
lib.yp_hash.restype = ctypes.c_int
lib.yp_scan.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32,
                        ctypes.c_char_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_char_p]
lib.yp_scan.restype = ctypes.c_int
lib.yp_version.restype = ctypes.c_char_p

BUFS = 4096
hdr_buf = ctypes.create_string_buffer(80)
digest_buf = ctypes.create_string_buffer(32)
nonce_out = ctypes.c_uint32(0)

def mine_range(header_prefix, start_nonce, count, target_be):
    hdr_buf.raw = header_prefix + struct.pack('<I', 0)
    rc = lib.yp_scan(hdr_buf.raw, 80, start_nonce, count, target_be,
                     ctypes.byref(nonce_out), digest_buf)
    return rc, nonce_out.value, digest_buf.raw

# ---------------------------------------------------------------- stratum
class Pool:
    def __init__(self, host, port, user, worker):
        self.s = socket.create_connection((host, port), timeout=30)
        self.f = self.s.makefile('rwb', buffering=0)
        self.user, self.worker = user, worker
        self.id = 0
        self.en1 = None
        self.en2size = 4
        self.diff = 1.0
        self.job = None

    def send(self, method, params):
        self.id += 1
        self.f.write((json.dumps({'id': self.id, 'method': method, 'params': params}) + '\n').encode())

    def lines(self):
        """yield parsed JSON messages as they arrive"""
        buf = b''
        while True:
            chunk = self.s.recv(65536)
            if not chunk:
                return
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except Exception:
                        pass

    def subscribe(self):
        self.send('mining.subscribe', ['sugar-native-app/1.0'])
        self.send('mining.authorize', [f'{self.user}.{self.worker}', 'x'])

    def submit(self, job_id, en2, ntime, nonce):
        self.send('mining.submit', [f'{self.user}.{self.worker}', job_id, en2, ntime, f'{nonce:08x}'])


def main(minutes=8.0):
    assert ADDR, 'no test address'
    print(f'library : {lib.yp_version().decode()}')
    print(f'address : {ADDR}')
    print(f'pool    : {POOL_HOST}:{POOL_PORT}\n')

    pool = Pool(POOL_HOST, POOL_PORT, ADDR, 'nativeApp')
    pool.subscribe()

    deadline = time.time() + minutes * 60
    hashes = 0
    t_start = time.time()
    best = None
    found = 0
    en2 = 0

    def handle(msg):
        nonlocal best, found, hashes
        if msg.get('id') and msg.get('error'):
            print(f'   pool error: {json.dumps(msg["error"])}')
        if msg.get('method') == 'mining.set_difficulty':
            d = msg['params'][0]
            pool.diff = d
            per = (2 ** 256) // share_target(d)
            print(f'   difficulty {d} -> a share needs ~{per:,} hashes')
        if msg.get('method') == 'mining.notify':
            p = msg['params']
            job = {'id': p[0], 'prevhash': swap_words4(p[1]), 'coinb1': p[2], 'coinb2': p[3],
                   'branches': p[4] or [], 'version': p[5], 'nbits': p[6], 'ntime': p[7]}
            coinbase = bytes.fromhex(job['coinb1'] + pool.en1 + f'{en2:0{pool.en2size * 2}x}' + job['coinb2'])
            root = sha256d(coinbase)
            for br in job['branches']:
                root = sha256d(root + bytes.fromhex(br))
            prefix = (struct.pack('<I', int(job['version'], 16)) + bytes.fromhex(job['prevhash']) + root +
                      struct.pack('<I', int(job['ntime'], 16)) + struct.pack('<I', int(job['nbits'], 16)))
            target = share_target(pool.diff)
            target_be = target.to_bytes(32, 'big')
            rc, nonce, digest = mine_range(prefix, 0, BUFS, target_be)
            hashes += BUFS
            v = value_of(digest)
            if best is None or v < best[0]:
                best = (v, nonce)
            if rc == 1:
                found += 1
                sd = (POOL_DIFF1 * 10 ** 8) // v / 10 ** 8
                print(f'\n>>> SHARE (batch)  nonce={nonce} poolDiff={sd:.4f}  job={job["id"]}')
                pool.submit(job['id'], f'{en2:0{pool.en2size * 2}x}', job['ntime'], nonce)
        if msg.get('id') and isinstance(msg.get('result'), list):
            res = msg['result']
            for item in res:
                if isinstance(item, str) and len(item) <= 20:
                    pool.en1 = item
                if isinstance(item, int):
                    pool.en2size = item
            print(f'   subscribed: extranonce1={pool.en1} en2size={pool.en2size}')
        if msg.get('id') and msg.get('result') is True:
            print('   authorized ✓')

    last_report = time.time()
    buf = b''
    while time.time() < deadline:
        r, _, _ = select.select([pool.s], [], [], 1.0)
        if r:
            chunk = pool.s.recv(65536)
            if not chunk:
                print('pool closed the connection'); break
            buf += chunk
            while b'\n' in buf:
                line, buf = buf.split(b'\n', 1)
                line = line.strip()
                if line:
                    try:
                        handle(json.loads(line))
                    except Exception as e:
                        import traceback; traceback.print_exc()
        if time.time() - last_report >= 20:
            last_report = time.time()
            hps = hashes / max(0.001, time.time() - t_start)
            best_s = f'{best[0]:#x}'[:20] + '...' if best else '-'
            print(f'   [{time.time() - t_start:5.0f}s] {hashes:,} hashes  {hps:.0f} H/s  shares={found}  best={best_s}')
    print(f'\ntotals: {hashes:,} hashes in {time.time() - t_start:.0f}s, shares accepted={found}')


if __name__ == '__main__':
    main(float(sys.argv[1]) if len(sys.argv) > 1 else 8.0)
