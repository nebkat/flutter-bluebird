/*
 * GATT server for the Bluebird BLE peripheral test fixture.
 *
 * Adapted from esp-idf examples/bluetooth/nimble/bleprph (Apache-2.0).
 *
 * UUID scheme: B1EBxxxx-CAFE-4E5D-A2B1-1BD5EE12B1EB
 * (see README.md for the full attribute table)
 */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "freertos/FreeRTOS.h"
#include "freertos/timers.h"

#include "esp_log.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

#include "gatt_svr.h"

static const char *TAG = "bluebird_gatt";

/* Build a 128-bit UUID of the form B1EBxxxx-CAFE-4E5D-A2B1-1BD5EE12B1EB.
 * BLE_UUID128_INIT takes the 16 bytes in little-endian order. */
#define BLUEBIRD_UUID128(val16)                                         \
    BLE_UUID128_INIT(0xeb, 0xb1, 0x12, 0xee, 0xd5, 0x1b, 0xb1, 0xa2,   \
                     0x5d, 0x4e, 0xfe, 0xca,                            \
                     (uint8_t)((val16) & 0xff), (uint8_t)((val16) >> 8),\
                     0xeb, 0xb1)

/*** Service A: B1EBA000-... ***/
static const ble_uuid128_t svc_a_uuid            = BLUEBIRD_UUID128(0xA000);
static const ble_uuid128_t chr_static_read_uuid  = BLUEBIRD_UUID128(0xA001);
static const ble_uuid128_t chr_write_echo_uuid   = BLUEBIRD_UUID128(0xA002);
static const ble_uuid128_t chr_notify_uuid       = BLUEBIRD_UUID128(0xA003);
static const ble_uuid128_t chr_indicate_uuid     = BLUEBIRD_UUID128(0xA004);
static const ble_uuid128_t chr_notify_ind_uuid   = BLUEBIRD_UUID128(0xA005);
static const ble_uuid128_t chr_long_uuid         = BLUEBIRD_UUID128(0xA006);
static const ble_uuid128_t chr_encrypted_uuid    = BLUEBIRD_UUID128(0xA007);
static const ble_uuid128_t chr_control_uuid      = BLUEBIRD_UUID128(0xA008);
static const ble_uuid128_t dsc_custom_uuid       = BLUEBIRD_UUID128(0xA0FF);
static const ble_uuid16_t  dsc_user_desc_uuid    = BLE_UUID16_INIT(0x2901);

/*** Service B: B1EBB000-... (duplicate-UUID characteristics) ***/
static const ble_uuid128_t svc_b_uuid            = BLUEBIRD_UUID128(0xB000);
static const ble_uuid128_t chr_dup_uuid          = BLUEBIRD_UUID128(0xB001);

/*** Characteristic value storage ***/

/* Static read value + descriptors */
static const char static_read_val[] = "bluebird";
static const char user_desc_val[]   = "Bluebird static read characteristic";
static uint8_t dsc_custom_buf[16]   = {0x00};
static uint16_t dsc_custom_len      = sizeof(dsc_custom_buf);

/* Write/echo buffer */
static uint8_t echo_buf[256];
static uint16_t echo_len;

/* 512-byte long read/write buffer */
static uint8_t long_buf[512];
static uint16_t long_len = sizeof(long_buf);

/* Encrypted characteristic value */
static const char encrypted_val[] = "top-secret";

/* Duplicate-UUID characteristic values (Service B) */
static const char dup_val_1[] = "instance-one";
static const char dup_val_2[] = "instance-two";

/* Value handles */
static uint16_t chr_static_read_val_handle;
static uint16_t chr_write_echo_val_handle;
static uint16_t chr_notify_val_handle;
static uint16_t chr_indicate_val_handle;
static uint16_t chr_notify_ind_val_handle;
static uint16_t chr_long_val_handle;
static uint16_t chr_encrypted_val_handle;
static uint16_t chr_control_val_handle;
static uint16_t chr_dup1_val_handle;
static uint16_t chr_dup2_val_handle;

/*** Subscription state + periodic timers ***/
static TimerHandle_t notify_timer;    /* 1 s */
static TimerHandle_t indicate_timer;  /* 2 s */
static uint16_t sub_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static bool notify_enabled;           /* NOTIFY char (0xA003) */
static bool indicate_enabled;         /* INDICATE char (0xA004) */
static bool combo_notify_enabled;     /* NOTIFY|INDICATE char (0xA005), CCCD notify bit */
static bool combo_indicate_enabled;   /* NOTIFY|INDICATE char (0xA005), CCCD indicate bit */
static uint32_t counter;

/*** Helpers ***/

static int
gatt_svr_write(struct os_mbuf *om, uint16_t min_len, uint16_t max_len,
               void *dst, uint16_t *len)
{
    uint16_t om_len;
    int rc;

    om_len = OS_MBUF_PKTLEN(om);
    if (om_len < min_len || om_len > max_len) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    rc = ble_hs_mbuf_to_flat(om, dst, max_len, len);
    if (rc != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    return 0;
}

/* Static value read; arg = struct static_val */
struct static_val {
    const void *data;
    uint16_t len;
};

static const struct static_val sv_static_read = { static_read_val, sizeof(static_read_val) - 1 };
static const struct static_val sv_user_desc   = { user_desc_val, sizeof(user_desc_val) - 1 };
static const struct static_val sv_encrypted   = { encrypted_val, sizeof(encrypted_val) - 1 };
static const struct static_val sv_dup_1       = { dup_val_1, sizeof(dup_val_1) - 1 };
static const struct static_val sv_dup_2       = { dup_val_2, sizeof(dup_val_2) - 1 };

static int
access_static_read(uint16_t conn_handle, uint16_t attr_handle,
                   struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    const struct static_val *val = arg;
    int rc;

    switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
    case BLE_GATT_ACCESS_OP_READ_DSC:
        ESP_LOGI(TAG, "static read; conn_handle=%d attr_handle=%d len=%d",
                 conn_handle, attr_handle, val->len);
        rc = os_mbuf_append(ctxt->om, val->data, val->len);
        return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

/* Custom writable descriptor on the static-read characteristic */
static int
access_custom_dsc(uint16_t conn_handle, uint16_t attr_handle,
                  struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    int rc;

    switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_DSC:
        ESP_LOGI(TAG, "custom descriptor read; conn_handle=%d attr_handle=%d",
                 conn_handle, attr_handle);
        rc = os_mbuf_append(ctxt->om, dsc_custom_buf, dsc_custom_len);
        return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;

    case BLE_GATT_ACCESS_OP_WRITE_DSC:
        ESP_LOGI(TAG, "custom descriptor write; conn_handle=%d attr_handle=%d len=%d",
                 conn_handle, attr_handle, OS_MBUF_PKTLEN(ctxt->om));
        return gatt_svr_write(ctxt->om, 1, sizeof(dsc_custom_buf),
                              dsc_custom_buf, &dsc_custom_len);

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

/* WRITE | WRITE_NO_RSP | READ echo characteristic */
static int
access_write_echo(uint16_t conn_handle, uint16_t attr_handle,
                  struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    int rc;

    switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
        ESP_LOGI(TAG, "echo read; conn_handle=%d len=%d", conn_handle, echo_len);
        rc = os_mbuf_append(ctxt->om, echo_buf, echo_len);
        return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;

    case BLE_GATT_ACCESS_OP_WRITE_CHR:
        ESP_LOGI(TAG, "echo write; conn_handle=%d len=%d",
                 conn_handle, OS_MBUF_PKTLEN(ctxt->om));
        return gatt_svr_write(ctxt->om, 0, sizeof(echo_buf), echo_buf, &echo_len);

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

/* 512-byte long read/write characteristic */
static int
access_long(uint16_t conn_handle, uint16_t attr_handle,
            struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    int rc;

    switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
        ESP_LOGI(TAG, "long read; conn_handle=%d len=%d", conn_handle, long_len);
        rc = os_mbuf_append(ctxt->om, long_buf, long_len);
        return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;

    case BLE_GATT_ACCESS_OP_WRITE_CHR:
        /* NimBLE reassembles prepared (long) writes into a single mbuf chain */
        ESP_LOGI(TAG, "long write; conn_handle=%d len=%d",
                 conn_handle, OS_MBUF_PKTLEN(ctxt->om));
        return gatt_svr_write(ctxt->om, 0, sizeof(long_buf), long_buf, &long_len);

    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

/* Counter value read; also used as (normally unreachable) access cb for the
 * notify-only characteristics. */
static int
access_counter(uint16_t conn_handle, uint16_t attr_handle,
               struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    int rc;

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        rc = os_mbuf_append(ctxt->om, &counter, sizeof(counter));
        return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

/* Control characteristic:
 *   0x01 -> ble_svc_gatt_changed() over the whole handle range
 *   0x02 -> terminate the connection from the peripheral side */
static int
access_control(uint16_t conn_handle, uint16_t attr_handle,
               struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    uint8_t cmd;
    int rc;

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    rc = gatt_svr_write(ctxt->om, 1, 1, &cmd, NULL);
    if (rc != 0) {
        return rc;
    }

    ESP_LOGI(TAG, "control write; conn_handle=%d cmd=0x%02x", conn_handle, cmd);

    switch (cmd) {
    case 0x01:
        ESP_LOGI(TAG, "control: sending Service Changed indication (0x0001-0xffff)");
        ble_svc_gatt_changed(0x0001, 0xffff);
        return 0;

    case 0x02:
        ESP_LOGI(TAG, "control: terminating connection from peripheral side");
        rc = ble_gap_terminate(conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        if (rc != 0) {
            ESP_LOGE(TAG, "ble_gap_terminate failed; rc=%d", rc);
        }
        return 0;

    default:
        ESP_LOGW(TAG, "control: unknown command 0x%02x", cmd);
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
}

/*** GATT service table ***/

static const struct ble_gatt_svc_def gatt_svr_svcs[] = {
    {
        /*** Service A ***/
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &svc_a_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) { {
            /* Static READ ("bluebird") + user-description + custom writable descriptor */
            .uuid = &chr_static_read_uuid.u,
            .access_cb = access_static_read,
            .arg = (void *)&sv_static_read,
            .flags = BLE_GATT_CHR_F_READ,
            .val_handle = &chr_static_read_val_handle,
            .descriptors = (struct ble_gatt_dsc_def[]) { {
                .uuid = &dsc_user_desc_uuid.u,        /* 0x2901 Characteristic User Description */
                .att_flags = BLE_ATT_F_READ,
                .access_cb = access_static_read,
                .arg = (void *)&sv_user_desc,
            }, {
                .uuid = &dsc_custom_uuid.u,           /* custom 128-bit writable descriptor */
                .att_flags = BLE_ATT_F_READ | BLE_ATT_F_WRITE,
                .access_cb = access_custom_dsc,
            }, {
                0, /* No more descriptors */
            } },
        }, {
            /* WRITE | WRITE_NO_RSP (+READ so writes can be verified) */
            .uuid = &chr_write_echo_uuid.u,
            .access_cb = access_write_echo,
            .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE |
                     BLE_GATT_CHR_F_WRITE_NO_RSP,
            .val_handle = &chr_write_echo_val_handle,
        }, {
            /* NOTIFY: incrementing counter every 1 s while subscribed */
            .uuid = &chr_notify_uuid.u,
            .access_cb = access_counter,
            .flags = BLE_GATT_CHR_F_NOTIFY,
            .val_handle = &chr_notify_val_handle,
        }, {
            /* INDICATE: incrementing counter every 2 s while subscribed */
            .uuid = &chr_indicate_uuid.u,
            .access_cb = access_counter,
            .flags = BLE_GATT_CHR_F_INDICATE,
            .val_handle = &chr_indicate_val_handle,
        }, {
            /* NOTIFY | INDICATE: exercises the forceIndications path */
            .uuid = &chr_notify_ind_uuid.u,
            .access_cb = access_counter,
            .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_INDICATE,
            .val_handle = &chr_notify_ind_val_handle,
        }, {
            /* READ | WRITE with 512-byte value (long read / long write) */
            .uuid = &chr_long_uuid.u,
            .access_cb = access_long,
            .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE,
            .val_handle = &chr_long_val_handle,
        }, {
            /* READ requiring encryption: triggers Just Works pairing/bonding */
            .uuid = &chr_encrypted_uuid.u,
            .access_cb = access_static_read,
            .arg = (void *)&sv_encrypted,
            .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_READ_ENC,
            .val_handle = &chr_encrypted_val_handle,
        }, {
            /* Control: 0x01 = service changed, 0x02 = disconnect */
            .uuid = &chr_control_uuid.u,
            .access_cb = access_control,
            .flags = BLE_GATT_CHR_F_WRITE,
            .val_handle = &chr_control_val_handle,
        }, {
            0, /* No more characteristics */
        } },
    },
    {
        /*** Service B: two characteristics with the SAME UUID ***/
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &svc_b_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) { {
            .uuid = &chr_dup_uuid.u,
            .access_cb = access_static_read,
            .arg = (void *)&sv_dup_1,
            .flags = BLE_GATT_CHR_F_READ,
            .val_handle = &chr_dup1_val_handle,
        }, {
            .uuid = &chr_dup_uuid.u,
            .access_cb = access_static_read,
            .arg = (void *)&sv_dup_2,
            .flags = BLE_GATT_CHR_F_READ,
            .val_handle = &chr_dup2_val_handle,
        }, {
            0, /* No more characteristics */
        } },
    },
    {
        0, /* No more services */
    },
};

/*** Periodic notify / indicate timers ***/

static void
send_counter(uint16_t val_handle, bool indicate)
{
    struct os_mbuf *om;
    int rc;

    om = ble_hs_mbuf_from_flat(&counter, sizeof(counter));
    if (om == NULL) {
        ESP_LOGE(TAG, "failed to allocate mbuf for counter");
        return;
    }

    if (indicate) {
        rc = ble_gatts_indicate_custom(sub_conn_handle, val_handle, om);
    } else {
        rc = ble_gatts_notify_custom(sub_conn_handle, val_handle, om);
    }

    ESP_LOGI(TAG, "%s counter=%" PRIu32 " val_handle=%d rc=%d",
             indicate ? "indicate" : "notify", counter, val_handle, rc);
}

static void
notify_timer_cb(TimerHandle_t timer)
{
    counter++;

    if (notify_enabled) {
        send_counter(chr_notify_val_handle, false);
    }

    /* Combo characteristic: prefer notifications; fall back to indications
     * when the client subscribed with the indicate bit only
     * (e.g. bluebird's forceIndications). */
    if (combo_notify_enabled) {
        send_counter(chr_notify_ind_val_handle, false);
    } else if (combo_indicate_enabled) {
        send_counter(chr_notify_ind_val_handle, true);
    }
}

static void
indicate_timer_cb(TimerHandle_t timer)
{
    counter++;

    if (indicate_enabled) {
        send_counter(chr_indicate_val_handle, true);
    }
}

static void
update_timers(void)
{
    if (notify_enabled || combo_notify_enabled || combo_indicate_enabled) {
        xTimerStart(notify_timer, 0);
    } else {
        xTimerStop(notify_timer, 0);
    }

    if (indicate_enabled) {
        xTimerStart(indicate_timer, 0);
    } else {
        xTimerStop(indicate_timer, 0);
    }
}

void
gatt_svr_handle_subscribe(const struct ble_gap_event *event)
{
    uint16_t attr = event->subscribe.attr_handle;

    sub_conn_handle = event->subscribe.conn_handle;

    if (attr == chr_notify_val_handle) {
        notify_enabled = event->subscribe.cur_notify;
        ESP_LOGI(TAG, "NOTIFY char subscription: %d", notify_enabled);
    } else if (attr == chr_indicate_val_handle) {
        indicate_enabled = event->subscribe.cur_indicate;
        ESP_LOGI(TAG, "INDICATE char subscription: %d", indicate_enabled);
    } else if (attr == chr_notify_ind_val_handle) {
        combo_notify_enabled = event->subscribe.cur_notify;
        combo_indicate_enabled = event->subscribe.cur_indicate;
        ESP_LOGI(TAG, "NOTIFY|INDICATE char subscription: notify=%d indicate=%d",
                 combo_notify_enabled, combo_indicate_enabled);
    } else {
        return;
    }

    update_timers();
}

void
gatt_svr_handle_disconnect(void)
{
    notify_enabled = false;
    indicate_enabled = false;
    combo_notify_enabled = false;
    combo_indicate_enabled = false;
    sub_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    update_timers();
}

/*** Registration ***/

void
gatt_svr_register_cb(struct ble_gatt_register_ctxt *ctxt, void *arg)
{
    char buf[BLE_UUID_STR_LEN];

    switch (ctxt->op) {
    case BLE_GATT_REGISTER_OP_SVC:
        ESP_LOGI(TAG, "registered service %s with handle=%d",
                 ble_uuid_to_str(ctxt->svc.svc_def->uuid, buf),
                 ctxt->svc.handle);
        break;

    case BLE_GATT_REGISTER_OP_CHR:
        ESP_LOGI(TAG, "registered characteristic %s with def_handle=%d val_handle=%d",
                 ble_uuid_to_str(ctxt->chr.chr_def->uuid, buf),
                 ctxt->chr.def_handle,
                 ctxt->chr.val_handle);
        break;

    case BLE_GATT_REGISTER_OP_DSC:
        ESP_LOGI(TAG, "registered descriptor %s with handle=%d",
                 ble_uuid_to_str(ctxt->dsc.dsc_def->uuid, buf),
                 ctxt->dsc.handle);
        break;

    default:
        assert(0);
        break;
    }
}

int
gatt_svr_init(void)
{
    int rc;

    ble_svc_gap_init();
    ble_svc_gatt_init();

    rc = ble_gatts_count_cfg(gatt_svr_svcs);
    if (rc != 0) {
        return rc;
    }

    rc = ble_gatts_add_svcs(gatt_svr_svcs);
    if (rc != 0) {
        return rc;
    }

    /* Fill the 512-byte buffer with a recognisable pattern for long reads. */
    for (size_t i = 0; i < sizeof(long_buf); i++) {
        long_buf[i] = (uint8_t)i;
    }

    notify_timer = xTimerCreate("bb_notify", pdMS_TO_TICKS(1000), pdTRUE,
                                NULL, notify_timer_cb);
    indicate_timer = xTimerCreate("bb_indicate", pdMS_TO_TICKS(2000), pdTRUE,
                                  NULL, indicate_timer_cb);
    assert(notify_timer != NULL && indicate_timer != NULL);

    return 0;
}
