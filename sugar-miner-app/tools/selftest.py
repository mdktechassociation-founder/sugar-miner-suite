#!/usr/bin/env python3
"""
Offline proof that the C hashing core is consensus-correct.

Builds native/yespower into a shared library, then checks that it reproduces the
SugarChain genesis PoW hash — the value the coin's own chainparams.cpp asserts.
No network needed, so CI can run it on every push.

    python3 tools/selftest.py
"""
import ctypes, os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
YP = os.path.join(HERE, '..', 'native', 'yespower')
LIB = os.path.join(YP, 'libyespower.so')

GENESIS_HEADER = (
    '01000000' + '00' * 32 +
    'b050e156acdac2cada87b39ce5f137f5b872901e6b9e1c1d41b09c572ace7776' +
    '7073555d' + 'ffff3f1f' + 'f7000000'
)
EXPECTED_POW = '0031205acedcc69a9c18f79b84790179d68fb90588bedee6587ff701bdde04eb'


def build():
    cmd = ['gcc', '-O3', '-fPIC', '-shared', '-o', LIB,
           'yp_bridge.c', 'yespower-opt.c', 'sha256.c', '-I.']
    print('  $', ' '.join(cmd[:6]), '…')
    subprocess.run(cmd, cwd=YP, check=True)


def main():
    print('building the native library…')
    build()
    lib = ctypes.CDLL(LIB)
    lib.yp_hash.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p]
    lib.yp_hash.restype = ctypes.c_int
    lib.yp_version.restype = ctypes.c_char_p

    header = bytes.fromhex(GENESIS_HEADER)
    out = ctypes.create_string_buffer(32)
    rc = lib.yp_hash(header, len(header), out)
    got = out.raw[::-1].hex()

    print(f'  library : {lib.yp_version().decode()}')
    print(f'  header  : {len(header)} bytes')
    print(f'  yp_hash : rc={rc}')
    print(f'  hash    : {got}')
    print(f'  expected: {EXPECTED_POW}')
    ok = (rc == 0 and len(header) == 80 and got == EXPECTED_POW)
    print('\n  ' + ('✓ PASS — the native core is consensus-correct' if ok
                    else '✗ FAIL — the native core produces the wrong hash'))
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
