# Bluebird BLE peripheral test fixture (ESP32-S3, NimBLE)
cmake_minimum_required(VERSION 3.22)

# Use the Bluetooth-optimised mbedTLS preset, same as the upstream NimBLE examples.
cmake_path(CONVERT "$ENV{IDF_PATH}" TO_CMAKE_PATH_LIST ESP_IDF_PATH)
list(APPEND sdkconfig_defaults "${ESP_IDF_PATH}/components/mbedtls/config/mbedtls_preset_bt.conf")

include($ENV{IDF_PATH}/tools/cmake/project.cmake)

# This fixture targets ESP-IDF 6.0.x (the mbedTLS preset path above and the
# sdkconfig options assume that layout).
if(NOT (IDF_VERSION_MAJOR EQUAL 6 AND IDF_VERSION_MINOR EQUAL 0))
    message(FATAL_ERROR
        "ESP-IDF 6.0.x is required, but found ${IDF_VERSION_MAJOR}.${IDF_VERSION_MINOR}.${IDF_VERSION_PATCH}.")
endif()

idf_build_set_property(MINIMAL_BUILD ON)
project(bluebird_peripheral)
