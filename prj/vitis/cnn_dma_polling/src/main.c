#include "xaxidma.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include "xil_types.h"
#include "xparameters.h"
#include "xstatus.h"
#include "xtime_l.h"

#include <string.h>

#include "mnist_image.h"

#if defined(XPAR_AXIDMA_0_DEVICE_ID)
#define CNN_DMA_DEVICE_ID XPAR_AXIDMA_0_DEVICE_ID
#elif defined(XPAR_AXI_DMA_0_DEVICE_ID)
#define CNN_DMA_DEVICE_ID XPAR_AXI_DMA_0_DEVICE_ID
#else
#error "AXI DMA device ID was not found in xparameters.h"
#endif

#define CNN_INPUT_BYTES          MNIST_1000_IMAGE_BYTES
#define CNN_OUTPUT_BYTES         1U
#define CACHE_ALIGNED_BYTES      64U
#define DMA_TIMEOUT_POLLS        100000000U
#define MAX_MISMATCHES_TO_PRINT  20U
#define DETAILED_IMAGE_COUNT     10U

#define CNN_TEST_MODE_10_IMAGES    1U
#define CNN_TEST_MODE_1000_IMAGES  2U
#define CNN_TEST_MODE_BOTH         3U

/* Change this default, or pass -DCNN_TEST_MODE=... in compiler options. */
#ifndef CNN_TEST_MODE
#define CNN_TEST_MODE CNN_TEST_MODE_BOTH
#endif

static XAxiDma AxiDma;
static UINTPTR DmaBaseAddress;

static u8 TxBuffer[CNN_INPUT_BYTES]
    __attribute__((aligned(CACHE_ALIGNED_BYTES)));
static u8 RxBuffer[CACHE_ALIGNED_BYTES]
    __attribute__((aligned(CACHE_ALIGNED_BYTES)));
static u8 OnBoardDecisions[MNIST_1000_IMAGE_COUNT];

static void print_dma_status(void)
{
    u32 mm2s_status = XAxiDma_ReadReg(
        DmaBaseAddress, XAXIDMA_TX_OFFSET + XAXIDMA_SR_OFFSET);
    u32 s2mm_status = XAxiDma_ReadReg(
        DmaBaseAddress, XAXIDMA_RX_OFFSET + XAXIDMA_SR_OFFSET);

    xil_printf("DMA status: MM2S_DMASR=0x%08x, S2MM_DMASR=0x%08x\r\n",
               mm2s_status, s2mm_status);
}

static int initialize_dma(void)
{
    XAxiDma_Config *config;
    int status;

    config = XAxiDma_LookupConfig(CNN_DMA_DEVICE_ID);
    if (config == NULL) {
        xil_printf("ERROR: no AXI DMA configuration for device ID %d\r\n",
                   CNN_DMA_DEVICE_ID);
        return XST_FAILURE;
    }

    DmaBaseAddress = config->BaseAddr;
    status = XAxiDma_CfgInitialize(&AxiDma, config);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: XAxiDma_CfgInitialize returned %d\r\n", status);
        return XST_FAILURE;
    }

    if (XAxiDma_HasSg(&AxiDma)) {
        xil_printf("ERROR: AXI DMA must be configured in simple mode\r\n");
        return XST_FAILURE;
    }

    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DMA_TO_DEVICE);
    XAxiDma_IntrDisable(&AxiDma, XAXIDMA_IRQ_ALL_MASK,
                        XAXIDMA_DEVICE_TO_DMA);
    return XST_SUCCESS;
}

static int wait_for_dma(int direction, const char *channel_name)
{
    u32 polls = DMA_TIMEOUT_POLLS;

    while (XAxiDma_Busy(&AxiDma, direction)) {
        if (--polls == 0U) {
            xil_printf("ERROR: %s DMA timeout\r\n", channel_name);
            print_dma_status();
            return XST_FAILURE;
        }
    }
    return XST_SUCCESS;
}

static int run_one_inference(u8 *decision, XTime *active_ticks)
{
    XTime start_time;
    XTime end_time;
    int status;

    memset(RxBuffer, 0xA5, sizeof(RxBuffer));
    Xil_DCacheFlushRange((UINTPTR)TxBuffer, CNN_INPUT_BYTES);
    Xil_DCacheFlushRange((UINTPTR)RxBuffer, sizeof(RxBuffer));

    XTime_GetTime(&start_time);

    status = XAxiDma_SimpleTransfer(&AxiDma,
                                    (UINTPTR)RxBuffer,
                                    CNN_OUTPUT_BYTES,
                                    XAXIDMA_DEVICE_TO_DMA);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: could not start S2MM, status=%d\r\n", status);
        print_dma_status();
        return XST_FAILURE;
    }

    status = XAxiDma_SimpleTransfer(&AxiDma,
                                    (UINTPTR)TxBuffer,
                                    CNN_INPUT_BYTES,
                                    XAXIDMA_DMA_TO_DEVICE);
    if (status != XST_SUCCESS) {
        xil_printf("ERROR: could not start MM2S, status=%d\r\n", status);
        print_dma_status();
        return XST_FAILURE;
    }

    if (wait_for_dma(XAXIDMA_DMA_TO_DEVICE, "MM2S") != XST_SUCCESS) {
        return XST_FAILURE;
    }
    if (wait_for_dma(XAXIDMA_DEVICE_TO_DMA, "S2MM") != XST_SUCCESS) {
        return XST_FAILURE;
    }

    XTime_GetTime(&end_time);
    Xil_DCacheInvalidateRange((UINTPTR)RxBuffer, sizeof(RxBuffer));

    *decision = RxBuffer[0];
    *active_ticks = end_time - start_time;
    return XST_SUCCESS;
}

static u32 ticks_to_ns(XTime ticks)
{
    return (u32)((ticks * 1000000000ULL) / (XTime)COUNTS_PER_SECOND);
}

static void print_us_3dp(XTime ticks)
{
    u32 nanoseconds = ticks_to_ns(ticks);
    xil_printf("%u.%03u", nanoseconds / 1000U, nanoseconds % 1000U);
}

static void print_ms_3dp(XTime ticks)
{
    u32 microseconds = (u32)((ticks * 1000000ULL) /
                             (XTime)COUNTS_PER_SECOND);
    xil_printf("%u.%03u", microseconds / 1000U, microseconds % 1000U);
}

static void print_mismatches(u32 completed)
{
    u32 image;
    u32 printed = 0U;

    for (image = 0U; image < completed; ++image) {
        if (OnBoardDecisions[image] != MnistExpectedDecision1000[image]) {
            if (printed == 0U) {
                xil_printf("Hardware/model mismatches:\r\n");
            }
            if (printed < MAX_MISMATCHES_TO_PRINT) {
                xil_printf("  image=%u hardware=%u model=%u label=%u\r\n",
                           image,
                           (u32)OnBoardDecisions[image],
                           (u32)MnistExpectedDecision1000[image],
                           (u32)MnistLabels1000[image]);
            }
            printed++;
        }
    }

    if (printed > MAX_MISMATCHES_TO_PRINT) {
        xil_printf("  ... %u additional hardware/model mismatches\r\n",
                   printed - MAX_MISMATCHES_TO_PRINT);
    }

    printed = 0U;
    for (image = 0U; image < completed; ++image) {
        if (OnBoardDecisions[image] != MnistLabels1000[image]) {
            if (printed == 0U) {
                xil_printf("Model label errors (expected for this model):\r\n");
            }
            if (printed < MAX_MISMATCHES_TO_PRINT) {
                xil_printf("  image=%u decision=%u label=%u model=%u\r\n",
                           image,
                           (u32)OnBoardDecisions[image],
                           (u32)MnistLabels1000[image],
                           (u32)MnistExpectedDecision1000[image]);
            }
            printed++;
        }
    }
}

int cnn_run_10_image_test(void)
{
    XTime image_ticks[DETAILED_IMAGE_COUNT];
    XTime batch_start;
    XTime batch_end;
    XTime active_total_ticks = 0U;
    XTime min_active_ticks = ~(XTime)0U;
    XTime max_active_ticks = 0U;
    u8 decisions[DETAILED_IMAGE_COUNT];
    u32 completed = 0U;
    u32 model_matches = 0U;
    u32 image;
    int fatal_error = 0;

    xil_printf("\r\n==================================================\r\n");
    xil_printf("TEST 1: detailed 10-image regression\r\n");
    xil_printf("==================================================\r\n");

    XTime_GetTime(&batch_start);

    for (image = 0U; image < DETAILED_IMAGE_COUNT; ++image) {
        XTime elapsed_ticks;
        u8 decision;

        memcpy(TxBuffer, MnistImages1000[image], CNN_INPUT_BYTES);
        if (run_one_inference(&decision, &elapsed_ticks) != XST_SUCCESS) {
            fatal_error = 1;
            break;
        }

        decisions[image] = decision;
        image_ticks[image] = elapsed_ticks;
        completed++;

        if (decision == MnistExpectedDecision1000[image]) {
            model_matches++;
        }

        active_total_ticks += elapsed_ticks;
        if (elapsed_ticks < min_active_ticks) {
            min_active_ticks = elapsed_ticks;
        }
        if (elapsed_ticks > max_active_ticks) {
            max_active_ticks = elapsed_ticks;
        }
    }

    XTime_GetTime(&batch_end);

    for (image = 0U; image < completed; ++image) {
        int matched =
            (decisions[image] == MnistExpectedDecision1000[image]);

        xil_printf("image=%u decision=%u expected=%u time=",
                   image,
                   (u32)decisions[image],
                   (u32)MnistExpectedDecision1000[image]);
        print_us_3dp(image_ticks[image]);
        xil_printf(" us ticks=%u [%s]\r\n",
                   (u32)image_ticks[image],
                   matched ? "PASS" : "FAIL");
    }

    xil_printf("--------------------------------------------------\r\n");
    xil_printf("Images completed       : %u/%u\r\n",
               completed, (u32)DETAILED_IMAGE_COUNT);
    xil_printf("Hardware/model matches : %u/%u\r\n",
               model_matches, completed);

    if (completed != 0U) {
        XTime batch_ticks = batch_end - batch_start;
        XTime active_average_ticks = active_total_ticks / (XTime)completed;
        XTime application_average_ticks = batch_ticks / (XTime)completed;
        u32 active_throughput = (u32)(((XTime)completed *
                                       (XTime)COUNTS_PER_SECOND) /
                                      active_total_ticks);
        u32 application_throughput = (u32)(((XTime)completed *
                                            (XTime)COUNTS_PER_SECOND) /
                                           batch_ticks);

        xil_printf("Active latency          : min=");
        print_us_3dp(min_active_ticks);
        xil_printf(" us avg=");
        print_us_3dp(active_average_ticks);
        xil_printf(" us max=");
        print_us_3dp(max_active_ticks);
        xil_printf(" us\r\n");
        xil_printf("Application avg latency : ");
        print_us_3dp(application_average_ticks);
        xil_printf(" us\r\n");
        xil_printf("Active throughput       : %u images/s\r\n",
                   active_throughput);
        xil_printf("Application throughput  : %u images/s\r\n",
                   application_throughput);
    }

    if ((!fatal_error) &&
        (completed == DETAILED_IMAGE_COUNT) &&
        (model_matches == DETAILED_IMAGE_COUNT)) {
        xil_printf("[PASS] Detailed 10-image regression passed.\r\n");
        return XST_SUCCESS;
    }

    xil_printf("[FAIL] Detailed 10-image regression failed.\r\n");
    return XST_FAILURE;
}

int cnn_run_1000_image_test(void)
{
    XTime batch_start;
    XTime batch_end;
    XTime active_total_ticks = 0U;
    XTime min_active_ticks = ~(XTime)0U;
    XTime max_active_ticks = 0U;
    XTime warmup_ticks;
    u32 decision_histogram[10] = {0U};
    u32 completed = 0U;
    u32 model_matches = 0U;
    u32 label_correct = 0U;
    u32 invalid_decisions = 0U;
    u32 image;
    u8 warmup_decision;
    int fatal_error = 0;

    xil_printf("\r\n==================================================\r\n");
    xil_printf("TEST 2: 1000-image accuracy and performance\r\n");
    xil_printf("No UART output is generated inside the timed loop.\r\n");
    xil_printf("==================================================\r\n");

    /* Warm up the code/data paths; this result is not included in statistics. */
    memcpy(TxBuffer, MnistImages1000[0], CNN_INPUT_BYTES);
    if ((run_one_inference(&warmup_decision, &warmup_ticks) != XST_SUCCESS) ||
        (warmup_decision != MnistExpectedDecision1000[0])) {
        xil_printf("[FAIL] Warm-up inference failed\r\n");
        return XST_FAILURE;
    }

    xil_printf("Warm-up: decision=%u time=", (u32)warmup_decision);
    print_us_3dp(warmup_ticks);
    xil_printf(" us\r\n");

    memset(OnBoardDecisions, 0xFF, sizeof(OnBoardDecisions));
    XTime_GetTime(&batch_start);

    for (image = 0U; image < MNIST_1000_IMAGE_COUNT; ++image) {
        XTime elapsed_ticks;
        u8 decision;

        memcpy(TxBuffer, MnistImages1000[image], CNN_INPUT_BYTES);
        if (run_one_inference(&decision, &elapsed_ticks) != XST_SUCCESS) {
            fatal_error = 1;
            break;
        }

        OnBoardDecisions[image] = decision;
        completed++;

        if (decision == MnistExpectedDecision1000[image]) {
            model_matches++;
        }
        if (decision == MnistLabels1000[image]) {
            label_correct++;
        }
        if (decision < 10U) {
            decision_histogram[decision]++;
        } else {
            invalid_decisions++;
        }

        active_total_ticks += elapsed_ticks;
        if (elapsed_ticks < min_active_ticks) {
            min_active_ticks = elapsed_ticks;
        }
        if (elapsed_ticks > max_active_ticks) {
            max_active_ticks = elapsed_ticks;
        }
    }

    XTime_GetTime(&batch_end);

    xil_printf("--------------------------------------------------\r\n");
    xil_printf("Images completed       : %u/%u\r\n",
               completed, (u32)MNIST_1000_IMAGE_COUNT);
    xil_printf("Hardware/model matches : %u/%u\r\n",
               model_matches, completed);
    xil_printf("Label correct          : %u/%u\r\n",
               label_correct, completed);

    if (completed != 0U) {
        XTime batch_ticks = batch_end - batch_start;
        XTime active_average_ticks = active_total_ticks / (XTime)completed;
        XTime application_average_ticks = batch_ticks / (XTime)completed;
        u32 accuracy_x100 = (label_correct * 10000U) / completed;
        u32 active_throughput = (u32)(((XTime)completed *
                                       (XTime)COUNTS_PER_SECOND) /
                                      active_total_ticks);
        u32 application_throughput = (u32)(((XTime)completed *
                                            (XTime)COUNTS_PER_SECOND) /
                                           batch_ticks);

        xil_printf("Classification accuracy: %u.%02u%%\r\n",
                   accuracy_x100 / 100U, accuracy_x100 % 100U);
        xil_printf("Active latency          : min=");
        print_us_3dp(min_active_ticks);
        xil_printf(" us avg=");
        print_us_3dp(active_average_ticks);
        xil_printf(" us max=");
        print_us_3dp(max_active_ticks);
        xil_printf(" us\r\n");
        xil_printf("Application avg latency : ");
        print_us_3dp(application_average_ticks);
        xil_printf(" us\r\n");
        xil_printf("Active throughput       : %u images/s\r\n",
                   active_throughput);
        xil_printf("Application throughput  : %u images/s\r\n",
                   application_throughput);
        xil_printf("1000-image wall time    : ");
        print_ms_3dp(batch_ticks);
        xil_printf(" ms\r\n");
    }

    xil_printf("Decision histogram      : 0=%u 1=%u 2=%u 3=%u 4=%u\r\n",
               decision_histogram[0], decision_histogram[1],
               decision_histogram[2], decision_histogram[3],
               decision_histogram[4]);
    xil_printf("                          5=%u 6=%u 7=%u 8=%u 9=%u invalid=%u\r\n",
               decision_histogram[5], decision_histogram[6],
               decision_histogram[7], decision_histogram[8],
               decision_histogram[9], invalid_decisions);

    print_mismatches(completed);

    if ((!fatal_error) &&
        (completed == MNIST_1000_IMAGE_COUNT) &&
        (model_matches == MNIST_1000_IMAGE_COUNT) &&
        (label_correct == MNIST_1000_EXPECTED_LABEL_CORRECT)) {
        xil_printf("[PASS] Hardware matched all 1000 model decisions; accuracy is 99.00%%.\r\n");
    } else {
        xil_printf("[FAIL] 1000-image on-board regression failed.\r\n");
    }

    return ((!fatal_error) &&
            (completed == MNIST_1000_IMAGE_COUNT) &&
            (model_matches == MNIST_1000_IMAGE_COUNT) &&
            (label_correct == MNIST_1000_EXPECTED_LABEL_CORRECT))
               ? XST_SUCCESS
               : XST_FAILURE;
}

int main(void)
{
    int status = XST_FAILURE;

    Xil_ICacheEnable();
    Xil_DCacheEnable();

    xil_printf("\r\n==================================================\r\n");
    xil_printf("CNN AXI DMA unified test application\r\n");
    xil_printf("Selected mode: %u (1=10 images, 2=1000 images, 3=both)\r\n",
               (u32)CNN_TEST_MODE);
    xil_printf("Global timer : %u counts/s\r\n", (u32)COUNTS_PER_SECOND);
    xil_printf("==================================================\r\n");

    if (initialize_dma() != XST_SUCCESS) {
        xil_printf("[FAIL] AXI DMA initialization failed.\r\n");
    } else if (CNN_TEST_MODE == CNN_TEST_MODE_10_IMAGES) {
        status = cnn_run_10_image_test();
    } else if (CNN_TEST_MODE == CNN_TEST_MODE_1000_IMAGES) {
        status = cnn_run_1000_image_test();
    } else if (CNN_TEST_MODE == CNN_TEST_MODE_BOTH) {
        status = cnn_run_10_image_test();
        if (status == XST_SUCCESS) {
            status = cnn_run_1000_image_test();
        } else {
            xil_printf("[SKIP] 1000-image test skipped because the 10-image test failed.\r\n");
        }
    } else {
        xil_printf("[FAIL] Invalid CNN_TEST_MODE=%u\r\n",
                   (u32)CNN_TEST_MODE);
    }

    if (status == XST_SUCCESS) {
        xil_printf("\r\n[PASS] Selected unified test mode completed successfully.\r\n");
    } else {
        xil_printf("\r\n[FAIL] Selected unified test mode failed.\r\n");
    }

    Xil_DCacheDisable();
    Xil_ICacheDisable();
    return status;
}
