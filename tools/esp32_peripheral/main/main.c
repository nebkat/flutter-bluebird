/*
 * Bluebird BLE peripheral test fixture (ESP32-S3, NimBLE).
 *
 * Adapted from esp-idf examples/bluetooth/nimble/bleprph (Apache-2.0).
 *
 * Advertises as "Bluebird-Test" and exposes a GATT database that exercises
 * every feature of the bluebird Flutter BLE library. See README.md.
 */

#include <string.h>

#include "esp_log.h"
#include "nvs_flash.h"

/* BLE */
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "host/ble_hs.h"
#include "host/ble_att.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"

#include "gatt_svr.h"
#include "l2cap_svr.h"

static const char *TAG = "bluebird_main";

#define DEVICE_NAME       "Bluebird-Test"
#define PREFERRED_ATT_MTU 517

/* Manufacturer specific data: company ID 0x02E5 (Espressif, little-endian)
 * followed by the payload de:ad:be:ef. */
static const uint8_t adv_mfg_data[] = { 0xe5, 0x02, 0xde, 0xad, 0xbe, 0xef };

/* 16-bit service UUID advertised for scan-filter tests. */
#define ADV_SVC_UUID16 0x181A

/* Service data: 16-bit UUID (little-endian) followed by 4 data bytes. */
static const uint8_t adv_svc_data[] = { 0x1a, 0x18, 0x11, 0x22, 0x33, 0x44 };

static uint8_t own_addr_type;

static void advertise(void);

void ble_store_config_init(void);

static void
print_addr(const uint8_t *addr)
{
    ESP_LOGI(TAG, "  addr=%02x:%02x:%02x:%02x:%02x:%02x",
             addr[5], addr[4], addr[3], addr[2], addr[1], addr[0]);
}

static void
print_conn_desc(const struct ble_gap_conn_desc *desc)
{
    ESP_LOGI(TAG, "  handle=%d our_addr_type=%d peer_addr_type=%d",
             desc->conn_handle, desc->our_id_addr.type, desc->peer_id_addr.type);
    print_addr(desc->peer_id_addr.val);
    ESP_LOGI(TAG, "  conn_itvl=%d conn_latency=%d supervision_timeout=%d",
             desc->conn_itvl, desc->conn_latency, desc->supervision_timeout);
    ESP_LOGI(TAG, "  encrypted=%d authenticated=%d bonded=%d",
             desc->sec_state.encrypted, desc->sec_state.authenticated,
             desc->sec_state.bonded);
}

/**
 * The NimBLE host executes this callback when a GAP event occurs.
 */
static int
gap_event(struct ble_gap_event *event, void *arg)
{
    struct ble_gap_conn_desc desc;
    int rc;

    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        ESP_LOGI(TAG, "GAP: connect %s; status=%d",
                 event->connect.status == 0 ? "established" : "failed",
                 event->connect.status);
        if (event->connect.status == 0) {
            rc = ble_gap_conn_find(event->connect.conn_handle, &desc);
            assert(rc == 0);
            print_conn_desc(&desc);
        } else {
            /* Connection attempt failed; resume advertising. */
            advertise();
        }
        return 0;

    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "GAP: disconnect; reason=%d (0x%02x)",
                 event->disconnect.reason, event->disconnect.reason);
        print_conn_desc(&event->disconnect.conn);

        gatt_svr_handle_disconnect();

        /* Resume advertising automatically. */
        advertise();
        return 0;

    case BLE_GAP_EVENT_CONN_UPDATE:
        ESP_LOGI(TAG, "GAP: connection updated; status=%d",
                 event->conn_update.status);
        rc = ble_gap_conn_find(event->conn_update.conn_handle, &desc);
        assert(rc == 0);
        print_conn_desc(&desc);
        return 0;

    case BLE_GAP_EVENT_ADV_COMPLETE:
        ESP_LOGI(TAG, "GAP: advertise complete; reason=%d",
                 event->adv_complete.reason);
        advertise();
        return 0;

    case BLE_GAP_EVENT_ENC_CHANGE:
        ESP_LOGI(TAG, "GAP: encryption change; status=%d",
                 event->enc_change.status);
        rc = ble_gap_conn_find(event->enc_change.conn_handle, &desc);
        assert(rc == 0);
        print_conn_desc(&desc);
        return 0;

    case BLE_GAP_EVENT_NOTIFY_TX:
        ESP_LOGI(TAG, "GAP: notify_tx; conn_handle=%d attr_handle=%d status=%d "
                 "is_indication=%d",
                 event->notify_tx.conn_handle,
                 event->notify_tx.attr_handle,
                 event->notify_tx.status,
                 event->notify_tx.indication);
        return 0;

    case BLE_GAP_EVENT_SUBSCRIBE:
        ESP_LOGI(TAG, "GAP: subscribe; conn_handle=%d attr_handle=%d reason=%d "
                 "prevn=%d curn=%d previ=%d curi=%d",
                 event->subscribe.conn_handle,
                 event->subscribe.attr_handle,
                 event->subscribe.reason,
                 event->subscribe.prev_notify,
                 event->subscribe.cur_notify,
                 event->subscribe.prev_indicate,
                 event->subscribe.cur_indicate);
        gatt_svr_handle_subscribe(event);
        return 0;

    case BLE_GAP_EVENT_MTU:
        ESP_LOGI(TAG, "GAP: mtu update; conn_handle=%d cid=%d mtu=%d",
                 event->mtu.conn_handle,
                 event->mtu.channel_id,
                 event->mtu.value);
        return 0;

    case BLE_GAP_EVENT_REPEAT_PAIRING:
        /* We already have a bond with the peer, but it is attempting to
         * establish a new secure link. Delete the old bond and accept. */
        ESP_LOGW(TAG, "GAP: repeat pairing; deleting old bond and retrying");
        rc = ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc);
        assert(rc == 0);
        ble_store_util_delete_peer(&desc.peer_id_addr);
        return BLE_GAP_REPEAT_PAIRING_RETRY;

    case BLE_GAP_EVENT_PASSKEY_ACTION:
        /* Should not happen with NO_INPUT_NO_OUTPUT (Just Works). */
        ESP_LOGW(TAG, "GAP: passkey action; action=%d (unexpected for Just Works)",
                 event->passkey.params.action);
        return 0;

    default:
        ESP_LOGI(TAG, "GAP: event type=%d", event->type);
        return 0;
    }
}

/**
 * Enables legacy advertising: connectable, general-discoverable.
 *
 * Advertising payload budget (31 bytes each):
 *   ADV:      flags (3) + complete name "Bluebird-Test" (15) + mfg data (8) = 26
 *   SCAN RSP: 16-bit service UUID list (4) + service data (8)              = 12
 */
static void
advertise(void)
{
    struct ble_gap_adv_params adv_params;
    struct ble_hs_adv_fields fields;
    struct ble_hs_adv_fields rsp_fields;
    int rc;

    if (ble_gap_adv_active()) {
        return;
    }

    /* Advertisement packet */
    memset(&fields, 0, sizeof(fields));

    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;

    fields.name = (uint8_t *)DEVICE_NAME;
    fields.name_len = strlen(DEVICE_NAME);
    fields.name_is_complete = 1;

    fields.mfg_data = adv_mfg_data;
    fields.mfg_data_len = sizeof(adv_mfg_data);

    rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "error setting advertisement data; rc=%d", rc);
        return;
    }

    /* Scan response packet */
    memset(&rsp_fields, 0, sizeof(rsp_fields));

    rsp_fields.uuids16 = (ble_uuid16_t[]) { BLE_UUID16_INIT(ADV_SVC_UUID16) };
    rsp_fields.num_uuids16 = 1;
    rsp_fields.uuids16_is_complete = 1;

    rsp_fields.svc_data_uuid16 = adv_svc_data;
    rsp_fields.svc_data_uuid16_len = sizeof(adv_svc_data);

    rc = ble_gap_adv_rsp_set_fields(&rsp_fields);
    if (rc != 0) {
        ESP_LOGE(TAG, "error setting scan response data; rc=%d", rc);
        return;
    }

    /* Begin advertising */
    memset(&adv_params, 0, sizeof(adv_params));
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(own_addr_type, NULL, BLE_HS_FOREVER,
                           &adv_params, gap_event, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "error enabling advertisement; rc=%d", rc);
        return;
    }

    ESP_LOGI(TAG, "advertising started as \"%s\"", DEVICE_NAME);
}

static void
on_reset(int reason)
{
    ESP_LOGE(TAG, "resetting state; reason=%d", reason);
}

static void
on_sync(void)
{
    uint8_t addr_val[6] = {0};
    int rc;

    /* Make sure we have a proper identity address (public preferred). */
    rc = ble_hs_util_ensure_addr(0);
    assert(rc == 0);

    rc = ble_hs_id_infer_auto(0, &own_addr_type);
    if (rc != 0) {
        ESP_LOGE(TAG, "error determining address type; rc=%d", rc);
        return;
    }

    rc = ble_hs_id_copy_addr(own_addr_type, addr_val, NULL);
    assert(rc == 0);
    ESP_LOGI(TAG, "device address:");
    print_addr(addr_val);

    advertise();
}

static void
host_task(void *param)
{
    ESP_LOGI(TAG, "BLE host task started");
    /* Returns only when nimble_port_stop() is executed. */
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void
app_main(void)
{
    int rc;

    /* NVS is used for PHY calibration data and bond storage. */
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    ret = nimble_port_init();
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "failed to init nimble; err=%d", ret);
        return;
    }

    /* NimBLE host configuration. */
    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    ble_hs_cfg.gatts_register_cb = gatt_svr_register_cb;
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;

    /* Security: Just Works pairing with bonding + LE Secure Connections. */
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_NO_IO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 0;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist |= BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist |= BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;

    rc = gatt_svr_init();
    assert(rc == 0);

    rc = l2cap_svr_init();
    assert(rc == 0);

    rc = ble_svc_gap_device_name_set(DEVICE_NAME);
    assert(rc == 0);

    rc = ble_att_set_preferred_mtu(PREFERRED_ATT_MTU);
    assert(rc == 0);

    /* Persist bonds/CCCDs in NVS. */
    ble_store_config_init();

    nimble_port_freertos_init(host_task);
}
