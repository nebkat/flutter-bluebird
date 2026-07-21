/*
 * L2CAP connection-oriented channel (CoC) echo server for the Bluebird BLE
 * peripheral test fixture. See README.md.
 */
#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* PSM the echo server listens on. LE dynamic PSM range is 0x0080-0x00FF. */
#define L2CAP_COC_PSM 0x0080

/* Register the L2CAP CoC echo server with the NimBLE host. */
int l2cap_svr_init(void);

#ifdef __cplusplus
}
#endif
