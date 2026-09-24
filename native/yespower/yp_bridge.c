/*
 * yp_bridge.c — small C API around SugarChain's yespower 1.0.1 for Flutter FFI.
 *
 * The consensus parameters are hard-coded from the coin itself
 * (sugarchain/src/primitives/block.cpp: YESPOWER_1_0, N=2048, r=32, 74-byte
 * personalisation). Changing any of them changes the hash and the pool will
 * reject every share, so they are not configurable here on purpose.
 *
 * Threading: yespower_tls() keeps a thread-local arena of a few MiB and reuses
 * it, so each Dart isolate / native thread gets its own. Call yp_free_local()
 * before a thread exits if you want the memory back immediately.
 */
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "yespower.h"

#define SUGAR_PERS    "Satoshi Nakamoto 31/Oct/2008 Proof-of-work is essentially one-CPU-one-vote"
#define SUGAR_PERSLEN 74u

static const yespower_params_t sugar_params = {
    YESPOWER_1_0,
    2048,
    32,
    (const uint8_t *)SUGAR_PERS,
    SUGAR_PERSLEN,
};

/* Hash one 80-byte header. Returns 0 on success.
 * `out32` receives the raw little-endian digest (digest[0] = least significant). */
int yp_hash(const uint8_t *header, size_t header_len, uint8_t *out32) {
    yespower_binary_t out;
    int rc;
    if (!header || !out32) return -1;
    rc = yespower_tls(header, header_len, &sugar_params, &out);
    if (rc) return rc;
    memcpy(out32, out.uc, 32);
    return 0;
}

/* Free this thread's yespower arena. Safe to call more than once. */
void yp_free_local(void) {
    yespower_local_t local;
    if (yespower_init_local(&local) == 0) yespower_free_local(&local);
}

/* Batch scan: hashes `count` headers (nonce range [start, start+count)) and
 * returns the *best* (numerically smallest) digest found.
 *
 * Why the loop lives here instead of Dart: it keeps one copy of the header in
 * cache and removes 32 000-odd FFI round trips per share. The comparison is done
 * on the 32-byte little-endian digest against a big-endian target — the same
 * convention the pool uses (`value <= target`).
 *
 * Returns 1 if a digest <= target was found, 0 if none, -1 on error.
 * found_nonce / best_hash are only written when returning 1. */
int yp_scan(const uint8_t *header, size_t header_len,
            uint32_t start_nonce, uint32_t count,
            const uint8_t target_be[32],
            uint32_t *found_nonce, uint8_t *found_hash) {
    uint8_t hdr[128];
    uint8_t digest[32];
    uint8_t best[32];
    uint32_t i;
    int have_best = 0;

    if (!header || header_len > sizeof(hdr) || !target_be) return -1;
    memcpy(hdr, header, header_len);

    for (i = 0; i < count; i++) {
        uint32_t nonce = start_nonce + i;
        /* nonce is little-endian at offset header_len - 4 (the last field) */
        hdr[header_len - 4] = (uint8_t)(nonce & 0xff);
        hdr[header_len - 3] = (uint8_t)((nonce >> 8) & 0xff);
        hdr[header_len - 2] = (uint8_t)((nonce >> 16) & 0xff);
        hdr[header_len - 1] = (uint8_t)((nonce >> 24) & 0xff);

        if (yespower_tls(hdr, header_len, &sugar_params, (yespower_binary_t *)digest)) return -1;

        if (!have_best || memcmp(digest, best, 32) < 0) {
            memcpy(best, digest, 32);
            have_best = 1;
        }
        /* little-endian digest <= big-endian target  <=>  reverse(digest) <= target */
        {
            int j, le = 0;
            for (j = 31; j >= 0; j--) {
                if (digest[j] < target_be[31 - j]) { le = 1; break; }
                if (digest[j] > target_be[31 - j]) { le = 0; break; }
                if (j == 0) le = 1;             /* equal -> accepted (pool uses >= 0.99) */
            }
            if (le) {
                if (found_nonce) *found_nonce = nonce;
                if (found_hash) memcpy(found_hash, digest, 32);
                return 1;
            }
        }
    }
    if (found_hash) memcpy(found_hash, best, 32);   /* "no hit, but here's the best" */
    return 0;
}

/* Small helper so the app can show what it is actually running. */
const char *yp_version(void) {
    return "yespower 1.0.1 (yespowerSUGAR N=2048 r=32 pers74)";
}

/* Bytes of arena yespower will allocate per thread (for the UI's memory warning). */
size_t yp_arena_bytes(void) {
    /* yespower_init_local reserves V + B + V*... : measured ~8 MiB at N=2048/r=32 */
    return (size_t)2048 * 32 * 4 * 32;
}
