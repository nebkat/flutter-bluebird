/*
 * L2CAP CoC echo server for the Bluebird BLE peripheral test fixture.
 *
 * Listens on PSM 0x0080 and echoes back every SDU it receives, so the bluebird
 * `BluetoothL2CapChannel` API can be exercised end-to-end (open, write, read
 * back, close).
 *
 * Flow control: NimBLE's L2CAP CoC is credit-based. We hand the stack one
 * receive buffer at a time and only request the next after the current SDU has
 * been echoed, so a slow reader on our side naturally backpressures the peer.
 */

#include <string.h>

#include "esp_log.h"

#include "os/os_mbuf.h"
#include "os/os_mempool.h"
#include "host/ble_hs.h"
#include "host/ble_l2cap.h"

#include "l2cap_svr.h"

static const char *TAG = "bluebird_l2cap";

/* Maximum SDU we accept and echo. Matches the 512-byte GATT long buffer. */
#define L2CAP_COC_MTU        512

/* Size each pool block above the MTU so a whole SDU fits in one mbuf (no
 * chaining), plus room for the os_mbuf/packet headers. */
#define L2CAP_COC_BLOCK_SIZE (L2CAP_COC_MTU + 64)

/* Receive-buffer pool. A handful is ample for an echo under credit-based flow
 * control, where only one SDU is outstanding at a time. */
#define L2CAP_COC_BUF_COUNT  4

static os_membuf_t l2cap_coc_mem[OS_MEMPOOL_SIZE(L2CAP_COC_BUF_COUNT, L2CAP_COC_BLOCK_SIZE)];
static struct os_mempool l2cap_coc_mempool;
static struct os_mbuf_pool l2cap_coc_mbuf_pool;

/* Allocate a fresh receive SDU buffer from the pool. */
static struct os_mbuf *
l2cap_coc_rx_alloc(void)
{
    return os_mbuf_get_pkthdr(&l2cap_coc_mbuf_pool, 0);
}

/* Echo one received SDU straight back to the peer. Copies out of [sdu_rx] into
 * a fresh system-pool tx buffer, so the caller can recycle [sdu_rx] right away. */
static void
l2cap_coc_echo(struct ble_l2cap_chan *chan, struct os_mbuf *sdu_rx)
{
    uint16_t len = OS_MBUF_PKTLEN(sdu_rx);
    if (len == 0) {
        return;
    }

    struct os_mbuf *sdu_tx = os_msys_get_pkthdr(len, 0);
    if (sdu_tx == NULL) {
        ESP_LOGE(TAG, "echo: out of tx buffers (dropping %u bytes)", len);
        return;
    }

    int rc = os_mbuf_appendfrom(sdu_tx, sdu_rx, 0, len);
    if (rc != 0) {
        ESP_LOGE(TAG, "echo: appendfrom failed; rc=%d", rc);
        os_mbuf_free_chain(sdu_tx);
        return;
    }

    rc = ble_l2cap_send(chan, sdu_tx);
    if (rc == 0 || rc == BLE_HS_ESTALLED) {
        /* 0: accepted. ESTALLED: queued, completes on TX_UNSTALLED. Either way
         * the stack now owns sdu_tx. */
        ESP_LOGD(TAG, "echoed %u bytes%s", len, rc == BLE_HS_ESTALLED ? " (stalled)" : "");
    } else {
        ESP_LOGE(TAG, "echo: ble_l2cap_send failed; rc=%d", rc);
        os_mbuf_free_chain(sdu_tx);
    }
}

/* Hands the stack a fresh receive buffer so the next SDU can arrive. */
static void
l2cap_coc_arm_rx(struct ble_l2cap_chan *chan)
{
    struct os_mbuf *sdu_rx = l2cap_coc_rx_alloc();
    if (sdu_rx == NULL) {
        ESP_LOGE(TAG, "out of rx buffers; channel will stall");
        return;
    }
    int rc = ble_l2cap_recv_ready(chan, sdu_rx);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_l2cap_recv_ready failed; rc=%d", rc);
        os_mbuf_free_chain(sdu_rx);
    }
}

static int
l2cap_coc_event_cb(struct ble_l2cap_event *event, void *arg)
{
    struct ble_l2cap_chan_info info;

    switch (event->type) {
    case BLE_L2CAP_EVENT_COC_CONNECTED:
        if (event->connect.status != 0) {
            ESP_LOGE(TAG, "L2CAP: connect failed; status=%d", event->connect.status);
            return 0;
        }
        ble_l2cap_get_chan_info(event->connect.chan, &info);
        ESP_LOGI(TAG, "L2CAP: connected; conn_handle=%d psm=0x%04x our_mtu=%d peer_mtu=%d",
                 event->connect.conn_handle, info.psm, info.our_coc_mtu, info.peer_coc_mtu);
        return 0;

    case BLE_L2CAP_EVENT_COC_DISCONNECTED:
        ESP_LOGI(TAG, "L2CAP: disconnected; conn_handle=%d", event->disconnect.conn_handle);
        return 0;

    case BLE_L2CAP_EVENT_COC_ACCEPT:
        /* Peer is opening a channel: provide the first receive buffer. */
        ESP_LOGI(TAG, "L2CAP: accept; conn_handle=%d peer_sdu_size=%d",
                 event->accept.conn_handle, event->accept.peer_sdu_size);
        l2cap_coc_arm_rx(event->accept.chan);
        return 0;

    case BLE_L2CAP_EVENT_COC_DATA_RECEIVED:
        /* Echo the SDU, free it, then re-arm for the next one. */
        l2cap_coc_echo(event->receive.chan, event->receive.sdu_rx);
        os_mbuf_free_chain(event->receive.sdu_rx);
        l2cap_coc_arm_rx(event->receive.chan);
        return 0;

    case BLE_L2CAP_EVENT_COC_TX_UNSTALLED:
        ESP_LOGD(TAG, "L2CAP: tx unstalled; status=%d", event->tx_unstalled.status);
        return 0;

    default:
        ESP_LOGD(TAG, "L2CAP: event type=%d", event->type);
        return 0;
    }
}

int
l2cap_svr_init(void)
{
    int rc;

    rc = os_mempool_init(&l2cap_coc_mempool, L2CAP_COC_BUF_COUNT,
                         L2CAP_COC_BLOCK_SIZE, l2cap_coc_mem, "l2cap_coc_pool");
    if (rc != 0) {
        ESP_LOGE(TAG, "os_mempool_init failed; rc=%d", rc);
        return rc;
    }

    rc = os_mbuf_pool_init(&l2cap_coc_mbuf_pool, &l2cap_coc_mempool,
                           L2CAP_COC_BLOCK_SIZE, L2CAP_COC_BUF_COUNT);
    if (rc != 0) {
        ESP_LOGE(TAG, "os_mbuf_pool_init failed; rc=%d", rc);
        return rc;
    }

    rc = ble_l2cap_create_server(L2CAP_COC_PSM, L2CAP_COC_MTU, l2cap_coc_event_cb, NULL);
    if (rc != 0) {
        ESP_LOGE(TAG, "ble_l2cap_create_server failed; rc=%d", rc);
        return rc;
    }

    ESP_LOGI(TAG, "L2CAP CoC echo server listening on PSM 0x%04x (MTU %d)",
             L2CAP_COC_PSM, L2CAP_COC_MTU);
    return 0;
}
