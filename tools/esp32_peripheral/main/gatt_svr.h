/*
 * GATT server for the Bluebird BLE peripheral test fixture.
 * See README.md for the full UUID / feature matrix.
 */
#pragma once

#include <stdint.h>
#include "host/ble_hs.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Register all services/characteristics with the NimBLE host. */
int gatt_svr_init(void);

/* GATT registration debug callback (assigned to ble_hs_cfg.gatts_register_cb). */
void gatt_svr_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg);

/* Called from the GAP event handler in main.c on BLE_GAP_EVENT_SUBSCRIBE.
 * Starts/stops the periodic notify (1 s) and indicate (2 s) timers. */
void gatt_svr_handle_subscribe(const struct ble_gap_event *event);

/* Called on disconnect: clears subscription state and stops the timers. */
void gatt_svr_handle_disconnect(void);

#ifdef __cplusplus
}
#endif
